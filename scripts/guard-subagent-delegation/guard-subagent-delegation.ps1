#requires -Version 7
<#
    Companion script for guard-subagent-delegation.json (PreToolUse hook),
    following the guard-pwsh-continuation.ps1 contract on the Copilot SDK
    harness.

    Denies a subagent tool call that starts a squad reviewer (Owl, Cat)
    without the fields the delegation rule requires on every reviewer call:
    model and reasoning_effort. Instructions alone do not enforce those
    fields, and an omitted model silently runs the reviewer on a fallback
    model, so the deny fails loudly. The missing-fields and effort-mismatch
    reasons name the expected model and effort and point the caller at the
    Subagent Delegation Rules in its own agent instructions, which hold the
    installed values. They tell the caller to retry with both fields set, or
    to surface the limitation to the user when its tool cannot set those
    values. The script needs its own copy of those values to enforce the
    rules itself.

    Also denies a reasoning_effort that differs from the effort installed
    for that reviewer, but only when the call's model contains the installed
    reviewer model. A user-named model that does not contain the installed
    model is allowed to use a different effort, because the configured
    effort belongs to the configured model.

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
    - Enforcement is presence plus a conditional value check: every reviewer
      call must carry non-empty model and reasoning_effort values. The effort
      value must equal the installed value only when the model value contains
      the installed reviewer model, compared as a case-insensitive substring.
      The model values may be full ids or distinctive parts of the model
      names, so containment matches the delegation rule's
      first-available-match behavior. A model that does not contain the
      installed value may carry any non-empty effort.
    - The constants below are placeholders in the repo copy and are filled by
      the installer. The script never reads configuration from outside itself.
      An installed copy with a placeholder left in place is a broken install.

    Scope: only calls whose agent_type names a squad reviewer are judged.
    Calls to the entry point agents, the built-in agents, or any other
    agent pass through untouched, and a call without an identifiable
    agent_type passes through too, because failing open on an
    unclassifiable call is safer than denying the harness's own work.

    Reads the hook event JSON from stdin and emits the PreToolUse permission
    decision JSON on stdout, always exiting 0. Empty stdout is an allow; the
    deny is communicated via JSON, never via a non-zero exit code.
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
$ExpectedModelByAgent = @{
    'Owl' = $OwlModel
    'Cat' = $CatModel
}
$ExpectedEffortByAgent = @{
    'Owl' = $OwlReasoningEffort
    'Cat' = $CatReasoningEffort
}
$RequiredFieldNamesByName = [ordered]@{
    'model'            = @('model')
    'reasoning_effort' = @('reasoning_effort', 'reasoningEffort')
}

function Write-Allow {
    exit 0
}

function Write-Deny {
    param([Parameter(Mandatory)][string]$Reason)
    # Flat preToolUse decision documented for the Copilot SDK harness.
    # permissionDecisionReason is required when the decision is deny.
    $payload = [ordered]@{
        permissionDecision       = 'deny'
        permissionDecisionReason = $Reason
    }
    $payload | ConvertTo-Json -Depth 5 -Compress | Write-Output
    exit 0
}

function Read-StdinJson {
    try {
        $raw = [Console]::In.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

# Returns the first matching field whose value exists and is not null,
# empty, or whitespace; otherwise $null, which the caller treats as a
# missing field.
function Get-ToolInputValue {
    param(
        [Parameter(Mandatory)]$ToolInput,
        [Parameter(Mandatory)][string[]]$Names
    )
    foreach ($name in $Names) {
        $property = $ToolInput.PSObject.Properties[$name]
        if (-not $property) { continue }
        $value = $property.Value
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
            return [string]$value
        }
    }
    return $null
}

$hookEvent = Read-StdinJson
if (-not $hookEvent) { Write-Allow }

if ($hookEvent.hook_event_name -ne 'PreToolUse') { Write-Allow }

if ($SubagentToolNames -notcontains $hookEvent.tool_name) { Write-Allow }

$toolInput = $hookEvent.tool_input
# tool_input normally arrives as a parsed object on the Copilot SDK harness;
# a raw JSON string is normalized before reading its fields.
if ($toolInput -is [string]) {
    try { $toolInput = $toolInput | ConvertFrom-Json } catch { $toolInput = $null }
}
if (-not $toolInput) { Write-Allow }

$agentType = Get-ToolInputValue -ToolInput $toolInput -Names @('agent_type', 'agentType')
if (-not $agentType) { Write-Allow }

# -notcontains compares strings case-insensitively, so owl and cat variants
# are guarded the same as the exact names.
if ($GuardedAgentNames -notcontains $agentType) { Write-Allow }

$expectedModel = $ExpectedModelByAgent[$agentType]
$expectedEffort = $ExpectedEffortByAgent[$agentType]
# A placeholder means the installer never filled this copy. Deny loudly
# instead of letting the containment check silently skip the effort check.
if ($expectedModel -match '^__.*__$' -or $expectedEffort -match '^__.*__$') {
    $reason = "The subagent call to $agentType was denied because the installed delegation guard is not " +
        'configured for that reviewer. Surface this to the user and ask them to re-run the installer.'
    Write-Deny -Reason $reason
}

$missingFields = @()
foreach ($requiredFieldName in $RequiredFieldNamesByName.Keys) {
    $candidateNames = @($RequiredFieldNamesByName[$requiredFieldName])
    if (-not (Get-ToolInputValue -ToolInput $toolInput -Names $candidateNames)) {
        $missingFields += $requiredFieldName
    }
}
if ($missingFields.Count -gt 0) {
    if ($missingFields.Count -eq 1) {
        $fieldDescription = 'the {0} field' -f $missingFields[0]
    }
    else {
        $fieldDescription = 'the {0} and {1} fields' -f $missingFields[0], $missingFields[1]
    }

    $reason = "The subagent call to $agentType was denied because it omits $fieldDescription that the " +
        'delegation rule requires on every reviewer call. Retry the call with ' +
        "model set to the first available model that matches '$expectedModel' and " +
        "reasoning_effort set to '$expectedEffort'. Both values are in the " +
        'Subagent Delegation Rules of your agent instructions. ' +
        'If the calling tool cannot set both fields, surface the limitation ' +
        'to the user instead of retrying without them or skipping the review.'

    Write-Deny -Reason $reason
}

$model = Get-ToolInputValue -ToolInput $toolInput -Names $RequiredFieldNamesByName['model']
$effort = Get-ToolInputValue -ToolInput $toolInput -Names $RequiredFieldNamesByName['reasoning_effort']

# IndexOf treats wildcard characters literally, unlike -like, and the
# comparison is case-insensitive like the reviewer-name check above.
$modelContainsExpectedModel = $model.Trim().IndexOf($expectedModel, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
if ($modelContainsExpectedModel -and ($effort.Trim() -ne $expectedEffort)) {
    $reason = "The subagent call to $agentType was denied because its reasoning_effort does not match " +
        'the installed effort for that reviewer. Retry the call with ' +
        "model set to the first available model that matches '$expectedModel' and " +
        "reasoning_effort set to '$expectedEffort'. Both values are in the " +
        'Subagent Delegation Rules of your agent instructions. ' +
        'If the calling tool cannot set that value, surface the limitation ' +
        'to the user instead of retrying with another value or skipping the review.'
    Write-Deny -Reason $reason
}

Write-Allow