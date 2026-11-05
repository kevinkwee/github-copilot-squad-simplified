#requires -Version 7
<#
    Companion script for guard-subagent-delegation.json (PreToolUse hook),
    following the guard-pwsh-continuation.ps1 contract on the Copilot SDK
    harness.

    Denies a subagent tool call that omits the model or reasoning_effort
    field this guard requires on every judgeable call, because instructions
    alone do not enforce them. An omitted model does not inherit the caller's
    model: the harness runs that subagent on its own default, which may not be
    served by the configured provider, and the failure reaches the caller as a
    provider error it cannot act on. Failing loudly before the subagent starts
    keeps the cause visible, and one retry with the named values resolves it.

    Two rules share that shape. A reviewer call (Owl, Cat) is judged against
    the values installed for that reviewer, and its reason points the caller
    at the Subagent Delegation Rules in its own agent instructions, which hold
    the same values. Every other subagent call with an identifiable agent_type
    is judged against the installed default pair when that pair is set, and
    passes when it is empty. Its reason stands alone because the hook is
    user-level and the caller may be any agent. The script needs its own copy
    of all six values to enforce the rules itself.

    Also denies a reasoning_effort that differs from the installed effort for
    that call, but only when the call's model contains the installed model. A
    user-named model that does not contain the installed model is allowed to
    use a different effort, because the configured effort belongs to the
    configured model.

    Contract notes shared with the shell guard:
    - The hook file is configured with the PascalCase PreToolUse event, so
      the harness delivers the VS Code compatible payload (hook_event_name,
      session_id, timestamp, cwd, tool_name, tool_input) and reports the
      subagent tool as Agent, with Task and the runtime name task kept as
      fallbacks for other SDK versions. The matcher in the hook JSON cannot
      be relied on to gate invocation: the Copilot SDK harness invokes the
      entry even when the matcher does not match the reported tool name, so
      the script's own tool-name filter is the real gate.
    - The deny decision uses the flat preToolUse output documented for the
      Copilot SDK harness (permissionDecision plus
      permissionDecisionReason, which is required for a deny). The nested
      hookSpecificOutput shape belongs to the VS Code Local harness and
      Claude Code; it is not emitted, so those harnesses stay unaffected
      if they ever load the same hook file.
    - Command preToolUse hooks fail closed on the Copilot SDK harness: a
      non-zero exit denies the tool call even when stdout reports allow.
      The script therefore exits 0 on every path, including internal
      failure, so a runtime error fails open to allow. A harness-side
      timeout also fails open. The hook JSON therefore budgets 60 seconds,
      far above the read-and-parse work this script does, so a timeout
      stays a pathological event rather than a way to bypass enforcement.
    - Enforcement is presence plus a conditional value check: every judged
      call must carry non-empty model and reasoning_effort values. The effort
      value must equal the installed value only when the model value contains
      the installed model, compared as a case-insensitive substring. The model
      values may be full ids or distinctive parts of the model names, so
      containment matches the delegation rule's first-available-match
      behavior. A model that does not contain the installed value may carry
      any non-empty effort.
    - The constants below are placeholders in the repo copy and are filled by
      the installer. The script never reads configuration from outside itself.
      An installed copy with a placeholder or a blank reviewer value left in
      place is a broken install, and the deny says so. So is a default pair
      with only one value set. An empty default pair means the user chose not
      to check ordinary subagent calls, so those calls pass.

    Scope: a call is a reviewer call when any agent_type or agentType key, under
    either name, in any letter case and any occurrence, names a reviewer,
    ignoring invisible format and control characters around or inside the
    name. The fields this guard requires, model and reasoning_effort, count
    only under their exact spelling and their last occurrence, because those
    are the names and occurrences the harness reads. A lenient read would let
    a call through with a field the harness never sees, so it falls back to
    its own defaults. A call carrying one of those fields only in another
    spelling is denied as missing that field, and the deny adds a note about
    the exact names and a possibly stale guard. Fields that classify a call
    rather than satisfy it, the agent_type keys and the harness payload
    fields, keep a case-insensitive fallback, because a lenient read there can
    only route a call to a rule and can never let it pass unchecked. A call
    without an identifiable agent_type passes through, because failing open on
    an unclassifiable call is safer than blocking the harness's own work.

    Reads the hook event JSON from stdin as UTF-8 and emits the PreToolUse
    permission decision JSON on stdout as UTF-8, always exiting 0. Empty
    stdout is an allow with unchanged arguments. The deny is communicated via
    JSON, never via a non-zero exit code.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'

# Every path below exits 0 because the Copilot SDK harness treats any
# non-zero exit as a deny, and a script defect must never block the
# implementer's work.
$SubagentToolNames = @('Agent', 'Task', 'task')
$GuardedAgentNames = @('Owl', 'Cat')
$OwlModel = '__OWL_MODEL__'
$CatModel = '__CAT_MODEL__'
$OwlReasoningEffort = '__OWL_REASONING_EFFORT__'
$CatReasoningEffort = '__CAT_REASONING_EFFORT__'
$DefaultSubagentModel = '__DEFAULT_SUBAGENT_MODEL__'
$DefaultSubagentReasoningEffort = '__DEFAULT_SUBAGENT_REASONING_EFFORT__'
$ExpectedModelByAgent = @{
    'Owl' = $OwlModel
    'Cat' = $CatModel
}
$ExpectedEffortByAgent = @{
    'Owl' = $OwlReasoningEffort
    'Cat' = $CatReasoningEffort
}
$AgentTypeFieldNames = @('agent_type', 'agentType')
$ModelFieldName = 'model'
$EffortFieldName = 'reasoning_effort'
# A ceiling well above any real payload keeps a deeply nested call judged
# instead of failing open on a parse error.
$JsonParseMaxDepth = 1024
# Appended when a required field is missing and the call carries a differently
# spelled key. It is fixed text, never the caller's key, because a key name is
# unvetted input. It covers both explanations because the guard cannot tell
# them apart: a caller that used the wrong spelling retries with the exact
# names, and a caller whose tool schema differs tells the user the guard may be
# stale instead of looping.
$LookAlikeFieldHint = ' Field names are matched exactly, so use ' +
    "$ModelFieldName and $EffortFieldName. If the calling tool's schema spells a field " +
    'differently, the installed delegation guard may be out of date with the harness, so tell ' +
    'the user instead of retrying.'

function Write-Allow {
    exit 0
}

# Emits the flat PreToolUse deny decision documented for the Copilot SDK
# harness. The payload is buffered and written to stdout in one call, so a
# serialization failure leaves stdout empty instead of a truncated object. The
# bytes are UTF-8 with the default encoder, which escapes non-ASCII text, so
# the payload is pure ASCII whatever code page the hook inherited.
function Write-Deny {
    param([Parameter(Mandatory)][string]$Reason)
    try {
        $options = [System.Text.Json.JsonWriterOptions]::new()
        $options.Indented = $false
        $buffer = [System.IO.MemoryStream]::new()
        $writer = [System.Text.Json.Utf8JsonWriter]::new($buffer, $options)
        $writer.WriteStartObject()
        $writer.WriteString('permissionDecision', 'deny')
        $writer.WriteString('permissionDecisionReason', $Reason)
        $writer.WriteEndObject()
        $writer.Dispose()
        $bytes = $buffer.ToArray()
        $standardOutput = [Console]::OpenStandardOutput()
        $standardOutput.Write($bytes, 0, $bytes.Length)
        $standardOutput.Flush()
    }
    catch {
        # A broken payload must not turn a decision into a hook crash. The
        # harness denies any non-zero exit, so fall through to exit 0.
    }
    exit 0
}

# A placeholder or a blank value means this copy is a broken install, and the
# check cannot judge a call without an expected value, so the call is denied
# rather than judged against nothing.
function Test-UnusableInstalledValue {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
    return $Value -match '^__.*__$'
}

# One definition of the parse options keeps the object and string parse sites
# in step, so a call is judged the same whichever form its arguments arrive in.
function New-HookJsonDocumentOptions {
    $options = [System.Text.Json.JsonDocumentOptions]::new()
    $options.MaxDepth = $JsonParseMaxDepth
    $options.AllowTrailingCommas = $true
    return $options
}

# Reads the hook event as UTF-8 bytes. Reading through [Console]::In would
# decode with the inherited console code page and corrupt every non-ASCII value
# the guard has to compare.
function Read-HookJson {
    try {
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        $reader = [System.IO.StreamReader]::new([Console]::OpenStandardInput(), $utf8NoBom, $true)
        $text = $reader.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return [System.Text.Json.JsonDocument]::Parse($text, (New-HookJsonDocumentOptions))
    }
    catch {
        return $null
    }
}

# Returns the value of the last property whose name matches the given name
# exactly, or $null when the element is not an object or names no such
# property. A repeated key is read the way a JSON reader reads it, which keeps
# the last occurrence. The JsonElement keeps each value in its JSON form, so
# no argument value is re-interpreted.
function Get-LastExactJsonProperty {
    param(
        [Parameter(Mandatory)][System.Text.Json.JsonElement]$Element,
        [Parameter(Mandatory)][string]$Name
    )
    if ($Element.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { return $null }
    $exactMatch = $null
    foreach ($property in $Element.EnumerateObject()) {
        if ([string]::Equals($property.Name, $Name, [System.StringComparison]::Ordinal)) {
            $exactMatch = [System.Text.Json.JsonElement]$property.Value
        }
    }
    return $exactMatch
}

# Returns the property for the given name, preferring the exact spelling and
# otherwise taking the last case-insensitive match. Only fields that classify a
# call are read this way, because a lenient read there can route a call to a
# rule but can never let it pass unchecked. The exact spelling outranks the
# fallback, so a decoy key cannot override the key the harness reads.
function Get-LastJsonProperty {
    param(
        [Parameter(Mandatory)][System.Text.Json.JsonElement]$Element,
        [Parameter(Mandatory)][string]$Name
    )
    if ($Element.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { return $null }
    $exactMatch = Get-LastExactJsonProperty -Element $Element -Name $Name
    if ($null -ne $exactMatch) { return $exactMatch }
    $caseInsensitiveMatch = $null
    foreach ($property in $Element.EnumerateObject()) {
        if ([string]::Equals($property.Name, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            $caseInsensitiveMatch = [System.Text.Json.JsonElement]$property.Value
        }
    }
    return $caseInsensitiveMatch
}

# Returns the value of a field this guard requires, which counts only under
# its exact spelling because that is the name the harness reads. A value that
# is not a string, or is blank, counts as missing. A differently spelled key
# also leaves this field missing, and the deny then reports it as a look-alike.
function Get-RequiredFieldValue {
    param(
        [Parameter(Mandatory)][System.Text.Json.JsonElement]$Element,
        [Parameter(Mandatory)][string]$Name
    )
    $valueElement = Get-LastExactJsonProperty -Element $Element -Name $Name
    if ($null -eq $valueElement) { return $null }
    if ($valueElement.ValueKind -ne [System.Text.Json.JsonValueKind]::String) { return $null }
    $value = $valueElement.GetString()
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    return $value
}

# Reduces a field name to its letters and digits in lowercase, so every
# spelling of one field has the same key. It is how a look-alike is
# recognized, never how a field is read.
function ConvertTo-FieldKey {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    $builder = [System.Text.StringBuilder]::new()
    foreach ($character in $Name.ToLowerInvariant().ToCharArray()) {
        if ([char]::IsLetterOrDigit($character)) {
            $null = $builder.Append($character)
        }
    }
    return $builder.ToString()
}

# Returns $true when the element carries a key that names the given field in
# another spelling, such as Model or reasoningEffort. Such a key does not
# satisfy the field, but its presence means the caller may be following a
# tool schema this guard does not know, so the deny says so instead of leaving
# the caller to retry blindly.
function Test-HasLookAlikeField {
    param(
        [Parameter(Mandatory)][System.Text.Json.JsonElement]$Element,
        [Parameter(Mandatory)][string]$Name
    )
    if ($Element.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { return $false }
    $fieldKey = ConvertTo-FieldKey -Name $Name
    foreach ($property in $Element.EnumerateObject()) {
        if ([string]::Equals($property.Name, $Name, [System.StringComparison]::Ordinal)) { continue }
        if ([string]::Equals((ConvertTo-FieldKey -Name $property.Name), $fieldKey, [System.StringComparison]::Ordinal)) {
            return $true
        }
    }
    return $false
}

# Returns the text with invisible format and control characters removed and
# surrounding whitespace trimmed. A byte order mark, a zero-width character,
# a tag character, or a trailing NUL leaves a name looking like a reviewer to
# a reader that strips them, so the reviewer check compares names without
# them. The text is walked by Unicode scalar rather than by UTF-16 unit, so a
# format character outside the Basic Multilingual Plane is recognized too.
function ConvertTo-VisibleText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $builder = [System.Text.StringBuilder]::new()
    foreach ($rune in $Text.EnumerateRunes()) {
        $category = [System.Text.Rune]::GetUnicodeCategory($rune)
        if ($category -eq [System.Globalization.UnicodeCategory]::Format) { continue }
        if ($category -eq [System.Globalization.UnicodeCategory]::Control) { continue }
        $null = $builder.Append($rune.ToString())
    }
    return $builder.ToString().Trim()
}

# Returns the reviewer's canonical name when any agent_type or agentType key,
# under either name, in any letter case and any occurrence, names a squad
# reviewer, otherwise $null. Readers differ on which spelling and which
# occurrence they honor, so a call that names a reviewer anywhere is held to
# the reviewer rules rather than risk being judged as an ordinary agent and
# then run as that reviewer.
function Get-ReviewerAgentName {
    param([Parameter(Mandatory)][System.Text.Json.JsonElement]$Element)
    if ($Element.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { return $null }
    foreach ($property in $Element.EnumerateObject()) {
        $isAgentTypeKey = $false
        foreach ($fieldName in $AgentTypeFieldNames) {
            if ([string]::Equals($property.Name, $fieldName, [System.StringComparison]::OrdinalIgnoreCase)) { $isAgentTypeKey = $true }
        }
        if (-not $isAgentTypeKey) { continue }
        if ($property.Value.ValueKind -ne [System.Text.Json.JsonValueKind]::String) { continue }
        $candidate = ConvertTo-VisibleText -Text $property.Value.GetString()
        foreach ($reviewerName in $GuardedAgentNames) {
            if ([string]::Equals($candidate, $reviewerName, [System.StringComparison]::OrdinalIgnoreCase)) { return $reviewerName }
        }
    }
    return $null
}

# Returns the property element for the first candidate name the element
# carries, or $null when it carries none of them.
function Get-JsonProperty {
    param(
        [Parameter(Mandatory)][System.Text.Json.JsonElement]$Element,
        [Parameter(Mandatory)][string[]]$Names
    )
    foreach ($name in $Names) {
        $valueElement = Get-LastJsonProperty -Element $Element -Name $name
        if ($null -ne $valueElement) { return $valueElement }
    }
    return $null
}

# Returns the string value for the first candidate name that holds one that
# is not empty or whitespace, otherwise $null, which the caller treats as a
# missing field. This is the lenient read, used for classification fields such
# as agent_type and agentType, where accepting either spelling only makes the
# call more likely to be judged.
function Get-JsonStringValue {
    param(
        [Parameter(Mandatory)][System.Text.Json.JsonElement]$Element,
        [Parameter(Mandatory)][string[]]$Names
    )
    foreach ($name in $Names) {
        $valueElement = Get-LastJsonProperty -Element $Element -Name $name
        if ($null -eq $valueElement) { continue }
        if ($valueElement.ValueKind -ne [System.Text.Json.JsonValueKind]::String) { continue }
        $value = $valueElement.GetString()
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }
    return $null
}

# tool_input normally arrives as an object. A raw JSON string is parsed with
# the same options so its fields can be read the same way.
function Get-ToolInputElement {
    param([Parameter(Mandatory)][System.Text.Json.JsonElement]$HookRoot)
    $toolInputElement = Get-JsonProperty -Element $HookRoot -Names @('tool_input', 'toolInput')
    if ($null -eq $toolInputElement) { return $null }
    if ($toolInputElement.ValueKind -eq [System.Text.Json.JsonValueKind]::String) {
        try {
            $document = [System.Text.Json.JsonDocument]::Parse($toolInputElement.GetString(), (New-HookJsonDocumentOptions))
            return $document.RootElement
        }
        catch {
            return $null
        }
    }
    return $toolInputElement
}

# Describes the fields a call omitted, in the order the rule lists them.
function Get-MissingFieldDescription {
    param([Parameter(Mandatory)][string[]]$MissingFields)
    if ($MissingFields.Count -eq 1) {
        return 'the {0} field' -f $MissingFields[0]
    }
    return 'the {0} and {1} fields' -f $MissingFields[0], $MissingFields[1]
}

# Compares a subagent call against the model and effort pair installed for
# it. Returns $null when the call satisfies the rule, or a hashtable whose
# Kind names the check that failed, so the reviewer rule and the rule for
# ordinary subagent calls cannot drift apart.
function Get-DelegationFailure {
    param(
        [Parameter(Mandatory)][System.Text.Json.JsonElement]$ToolInput,
        [Parameter(Mandatory)][string]$ExpectedModel,
        [Parameter(Mandatory)][string]$ExpectedEffort
    )
    $model = Get-RequiredFieldValue -Element $ToolInput -Name $ModelFieldName
    $effort = Get-RequiredFieldValue -Element $ToolInput -Name $EffortFieldName
    $missingFields = @()
    if ($null -eq $model) { $missingFields += $ModelFieldName }
    if ($null -eq $effort) { $missingFields += $EffortFieldName }
    if ($missingFields.Count -gt 0) {
        $hasLookAlikeField = $false
        foreach ($missingField in $missingFields) {
            if (Test-HasLookAlikeField -Element $ToolInput -Name $missingField) { $hasLookAlikeField = $true }
        }
        return @{
            Kind              = 'MissingFields'
            MissingFields     = $missingFields
            FieldDescription  = Get-MissingFieldDescription -MissingFields $missingFields
            HasLookAlikeField = $hasLookAlikeField
        }
    }

    # IndexOf treats wildcard characters literally, unlike -like, and the
    # comparison is case-insensitive like the reviewer-name check.
    $modelContainsExpectedModel = $model.IndexOf($ExpectedModel, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
    if ($modelContainsExpectedModel -and ($effort.Trim() -ne $ExpectedEffort)) {
        return @{ Kind = 'EffortMismatch' }
    }
    return $null
}

# A reviewer reason points at the caller's own instructions, because the
# installed reviewer values live there as well.
function New-ReviewerDenialReason {
    param(
        [Parameter(Mandatory)][string]$AgentName,
        [Parameter(Mandatory)][hashtable]$Failure,
        [Parameter(Mandatory)][string]$ExpectedModel,
        [Parameter(Mandatory)][string]$ExpectedEffort
    )
    if ($Failure.Kind -eq 'MissingFields') {
        $reason = "The subagent call to $AgentName was denied because it omits $($Failure.FieldDescription) that the " +
            'delegation rule requires on every reviewer call. Retry the call with ' +
            "model set to the first available model that matches '$ExpectedModel' and " +
            "reasoning_effort set to '$ExpectedEffort'. Both values are in the " +
            'Subagent Delegation Rules of your agent instructions. ' +
            'If the calling tool cannot set both fields, surface the limitation ' +
            'to the user instead of retrying without them or skipping the review.'
        if ($Failure.HasLookAlikeField) { $reason += $LookAlikeFieldHint }
        return $reason
    }
    return "The subagent call to $AgentName was denied because its reasoning_effort does not match " +
        'the installed effort for that reviewer. Retry the call with ' +
        "model set to the first available model that matches '$ExpectedModel' and " +
        "reasoning_effort set to '$ExpectedEffort'. Both values are in the " +
        'Subagent Delegation Rules of your agent instructions. ' +
        'If the calling tool cannot set that value, surface the limitation ' +
        'to the user instead of retrying with another value or skipping the review.'
}

# The default pair applies to any agent, including agents that never read the
# squad instructions, so this reason stands alone and cites no document. It
# also omits the caller's own agent_type, which is unvetted text.
function New-DefaultDenialReason {
    param(
        [Parameter(Mandatory)][hashtable]$Failure,
        [Parameter(Mandatory)][string]$ExpectedModel,
        [Parameter(Mandatory)][string]$ExpectedEffort
    )
    if ($Failure.Kind -eq 'MissingFields') {
        $reason = "The subagent call was denied because it omits $($Failure.FieldDescription) that this " +
            'delegation guard requires on every subagent call.'
        if ($Failure.MissingFields -contains $ModelFieldName) {
            $reason += " A subagent does not inherit the caller's model, so every subagent call must " +
                'name the model it should run on.'
        }
        $reason += " Retry the call with model set to the first available model that matches " +
            "'$ExpectedModel' and reasoning_effort set to '$ExpectedEffort'. To use a model that " +
            "does not contain '$ExpectedModel', name it and pass any reasoning_effort value. If " +
            'nothing available matches, ask the user how to proceed. If the calling tool cannot ' +
            'set both fields, surface that limitation to the user.'
        if ($Failure.HasLookAlikeField) { $reason += $LookAlikeFieldHint }
        return $reason
    }
    return 'The subagent call was denied because its reasoning_effort does not match the effort ' +
        'installed for the model it names. Retry the call with ' +
        "reasoning_effort set to '$ExpectedEffort', or name a model that does not contain " +
        "'$ExpectedModel' and pass any reasoning_effort value. If the calling tool cannot set that " +
        'field, surface that limitation to the user.'
}

# A broken install must never skip enforcement silently, and both rules need
# the same advice, so the wording lives in one place.
function Write-BrokenInstallDeny {
    param([Parameter(Mandatory)][string]$Coverage)
    $reason = 'The subagent call was denied because the installed delegation guard is not ' +
        "configured for $Coverage. Surface this to the user and ask them to re-run the installer."
    Write-Deny -Reason $reason
}

$hookDocument = Read-HookJson
if ($null -eq $hookDocument) { Write-Allow }
$hookRoot = $hookDocument.RootElement

if ((Get-JsonStringValue -Element $hookRoot -Names @('hook_event_name', 'hookEventName')) -ne 'PreToolUse') { Write-Allow }

if ($SubagentToolNames -notcontains (Get-JsonStringValue -Element $hookRoot -Names @('tool_name', 'toolName'))) { Write-Allow }

$toolInputElement = Get-ToolInputElement -HookRoot $hookRoot
if ($null -eq $toolInputElement) { Write-Allow }

$agentType = Get-ReviewerAgentName -Element $toolInputElement
if ($null -eq $agentType) {
    # A call with no readable agent_type cannot be classified, so it passes
    # through.
    if ($null -eq (Get-JsonStringValue -Element $toolInputElement -Names $AgentTypeFieldNames)) { Write-Allow }

    $defaultIsBlank = [string]::IsNullOrWhiteSpace($DefaultSubagentModel) -and
        [string]::IsNullOrWhiteSpace($DefaultSubagentReasoningEffort)
    # A blank pair is the user opting out of checking these calls, which the
    # installed copy records as two empty strings.
    if ($defaultIsBlank) { Write-Allow }
    # Anything else unusable is a broken install, including the half pair the
    # installer refuses to write, because half a rule cannot be enforced.
    if ((Test-UnusableInstalledValue -Value $DefaultSubagentModel) -or
        (Test-UnusableInstalledValue -Value $DefaultSubagentReasoningEffort)) {
        Write-BrokenInstallDeny -Coverage 'the default subagent pair'
    }

    $failure = Get-DelegationFailure -ToolInput $toolInputElement `
        -ExpectedModel $DefaultSubagentModel -ExpectedEffort $DefaultSubagentReasoningEffort
    if ($null -ne $failure) {
        $reason = New-DefaultDenialReason -Failure $failure `
            -ExpectedModel $DefaultSubagentModel -ExpectedEffort $DefaultSubagentReasoningEffort
        Write-Deny -Reason $reason
    }

    Write-Allow
}

$expectedModel = $ExpectedModelByAgent[$agentType]
$expectedEffort = $ExpectedEffortByAgent[$agentType]
# An unusable reviewer value means this copy is a broken install, and a call
# cannot be judged against nothing.
if ((Test-UnusableInstalledValue -Value $expectedModel) -or (Test-UnusableInstalledValue -Value $expectedEffort)) {
    Write-BrokenInstallDeny -Coverage "subagent calls to $agentType"
}

$failure = Get-DelegationFailure -ToolInput $toolInputElement -ExpectedModel $expectedModel -ExpectedEffort $expectedEffort
if ($null -ne $failure) {
    $reason = New-ReviewerDenialReason -AgentName $agentType -Failure $failure `
        -ExpectedModel $expectedModel -ExpectedEffort $expectedEffort
    Write-Deny -Reason $reason
}

Write-Allow