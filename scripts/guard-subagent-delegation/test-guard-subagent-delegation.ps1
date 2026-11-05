#requires -Version 7
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
<#
    Out-of-process test battery for guard-subagent-delegation.ps1. Each case
    builds the hook stdin JSON the Copilot SDK harness delivers for the
    PascalCase PreToolUse event, pipes it to the hook script, and compares
    the hook's flat permissionDecision against the expected verdict.

    Must run under pwsh 7, the interpreter version the hook itself pins.
    Run with:
      pwsh -NoProfile -File test-guard-subagent-delegation.ps1
    Exits with code 1 if any case fails and prints a per-case PASS/FAIL line.

    Unlike the shell guard battery, no verdict flips per platform: the
    enforcement logic here is platform independent, and the model and
    reasoning effort fields mean the same thing on every platform.
#>

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$HookTemplatePath = Join-Path $ScriptDir 'guard-subagent-delegation.ps1'

# The repo template carries placeholders and an installed copy carries real
# values. Fill any remaining placeholders with test values, then read the
# effective values from the rendered text so the cases below work in both
# places.
$RenderedHookText = [System.IO.File]::ReadAllText($HookTemplatePath)
$RenderedHookText = $RenderedHookText.Replace('__OWL_MODEL__', 'test/Owl-Model')
$RenderedHookText = $RenderedHookText.Replace('__CAT_MODEL__', 'test/Cat-Model')
$RenderedHookText = $RenderedHookText.Replace('__OWL_REASONING_EFFORT__', 'high')
$RenderedHookText = $RenderedHookText.Replace('__CAT_REASONING_EFFORT__', 'low')
$RenderedHookText = $RenderedHookText.Replace('__DEFAULT_SUBAGENT_MODEL__', 'test/Default-Model')
$RenderedHookText = $RenderedHookText.Replace('__DEFAULT_SUBAGENT_REASONING_EFFORT__', 'max')
# An installed copy may hold an empty default pair, which turns that rule off.
# Rendering test values into this battery's copy keeps every case meaningful
# wherever the battery runs.
$RenderedHookText = $RenderedHookText.Replace("`$DefaultSubagentModel = ''", "`$DefaultSubagentModel = 'test/Default-Model'")
$RenderedHookText = $RenderedHookText.Replace("`$DefaultSubagentReasoningEffort = ''", "`$DefaultSubagentReasoningEffort = 'max'")

$valuePatterns = @{
    OwlModel                      = '(?m)^\$OwlModel = ''([^'']*)''\r?$'
    CatModel                      = '(?m)^\$CatModel = ''([^'']*)''\r?$'
    OwlReasoningEffort            = '(?m)^\$OwlReasoningEffort = ''([^'']*)''\r?$'
    CatReasoningEffort            = '(?m)^\$CatReasoningEffort = ''([^'']*)''\r?$'
    DefaultSubagentModel          = '(?m)^\$DefaultSubagentModel = ''([^'']*)''\r?$'
    DefaultSubagentReasoningEffort = '(?m)^\$DefaultSubagentReasoningEffort = ''([^'']*)''\r?$'
}
$renderedValues = @{}
foreach ($valueName in $valuePatterns.Keys) {
    if ($RenderedHookText -notmatch $valuePatterns[$valueName]) {
        throw "The guard script does not define $valueName."
    }
    $renderedValues[$valueName] = $Matches[1]
}
$OwlModel = $renderedValues.OwlModel
$CatModel = $renderedValues.CatModel
$OwlEffort = $renderedValues.OwlReasoningEffort
$CatEffort = $renderedValues.CatReasoningEffort
$DefaultSubagentModel = $renderedValues.DefaultSubagentModel
$DefaultSubagentEffort = $renderedValues.DefaultSubagentReasoningEffort
$OwlMatchingModel = 'prefix/' + $OwlModel
$CatMatchingModel = 'prefix/' + $CatModel
$DefaultMatchingModel = 'prefix/' + $DefaultSubagentModel

function Get-DifferentEffort {
    param([Parameter(Mandatory)][string]$ConfiguredEffort)
    foreach ($candidate in @('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max')) {
        if ($candidate -ne $ConfiguredEffort) { return $candidate }
    }
    throw "No alternative effort exists for '$ConfiguredEffort'."
}

# Returns a single printable character that cannot appear inside the configured
# model, so the resulting value is guaranteed not to contain it.
function New-NonMatchingModel {
    param([Parameter(Mandatory)][string]$ConfiguredModel)
    if ([string]::IsNullOrWhiteSpace($ConfiguredModel)) {
        throw 'The configured model value is empty.'
    }
    for ($code = 33; $code -le 126; $code++) {
        $candidate = [string][char]$code
        if ($ConfiguredModel.IndexOf($candidate, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
            return $candidate
        }
    }
    throw 'No printable character is absent from the configured model.'
}

$OtherOwlEffort = Get-DifferentEffort -ConfiguredEffort $OwlEffort
$OtherCatEffort = Get-DifferentEffort -ConfiguredEffort $CatEffort
$OtherDefaultEffort = Get-DifferentEffort -ConfiguredEffort $DefaultSubagentEffort
$OverrideModel = New-NonMatchingModel -ConfiguredModel $OwlModel
$CatOverrideModel = New-NonMatchingModel -ConfiguredModel $CatModel
$DefaultOverrideModel = New-NonMatchingModel -ConfiguredModel $DefaultSubagentModel
$FailureTextLength = 80

$HookScript = Join-Path ([System.IO.Path]::GetTempPath()) ('guard-subagent-delegation-' + [System.Guid]::NewGuid().ToString('N') + '.ps1')
[System.IO.File]::WriteAllText($HookScript, $RenderedHookText)

function Invoke-Hook {
    param(
        [Parameter(Mandatory)][string]$StdinJson,
        [Parameter(Mandatory)][string]$ScriptPath
    )
    $stdout = $StdinJson | & pwsh -NoProfile -ExecutionPolicy Bypass -File $ScriptPath
    [pscustomobject]@{
        Stdout   = ($stdout | Out-String).Trim()
        ExitCode = $LASTEXITCODE
    }
}

function New-HookInput {
    param(
        [Parameter(Mandatory)][string]$ToolName,
        [AllowNull()][object]$ToolInput,
        [string]$EventName = 'PreToolUse'
    )
    [ordered]@{
        hook_event_name = $EventName
        session_id      = 'test-session'
        timestamp       = '2026-10-14T01:00:00Z'
        cwd             = 'C:\repo'
        tool_name       = $ToolName
        tool_input      = $ToolInput
    }
}

$failures = 0

# Runs one case: expected is 'allow' (empty stdout, exit 0) or 'deny' (flat
# decision JSON, exit 0). The fragment lists apply only when the decision is
# deny.
function Invoke-ExpectedCase {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('allow', 'deny')][string]$Expected,
        [Parameter(Mandatory)][string]$StdinJson,
        [string[]]$ReasonMustContains = @(),
        [string[]]$ReasonMustNotContain = @(),
        [string]$ScriptPath = $HookScript
    )
    $result = Invoke-Hook -StdinJson $StdinJson -ScriptPath $ScriptPath
    if ($result.ExitCode -ne 0) {
        Write-Output "FAIL [$Name]: hook exited with $($result.ExitCode)"
        $script:failures++
        return
    }
    # Strict mode turns a malformed payload or a missing property into a
    # terminating error, so the payload is read defensively and any defect
    # becomes a FAIL line for this case instead of ending the battery.
    $parsed = $null
    if (-not [string]::IsNullOrWhiteSpace($result.Stdout)) {
        try {
            # -NoEnumerate keeps a top-level array as an array, so a payload
            # whose root is not an object cannot pass as its first element.
            $parsed = ConvertFrom-Json -InputObject $result.Stdout -NoEnumerate
        }
        catch {
            Write-Output "FAIL [$Name]: unreadable output: $(Get-ShortText -Text $result.Stdout)"
            $script:failures++
            return
        }
        if ($parsed -isnot [System.Management.Automation.PSCustomObject]) {
            Write-Output "FAIL [$Name]: output root is not an object: $(Get-ShortText -Text $result.Stdout)"
            $script:failures++
            return
        }
    }
    # The harness reads these fields by exact name and only as strings, so
    # a differently cased key or a non-string value is a broken decision.
    $decision = 'allow'
    $reason = $null
    if ($null -ne $parsed) {
        $decision = Get-OptionalProperty -Object $parsed -Name 'permissionDecision'
        $reason = Get-OptionalProperty -Object $parsed -Name 'permissionDecisionReason'
    }
    if ($decision -isnot [string]) {
        Write-Output "FAIL [$Name]: permissionDecision is missing or not a string: $(Get-ShortText -Text $result.Stdout)"
        $script:failures++
        return
    }
    if ($null -ne $reason -and $reason -isnot [string]) {
        Write-Output "FAIL [$Name]: permissionDecisionReason is not a string: $(Get-ShortText -Text $result.Stdout)"
        $script:failures++
        return
    }

    $expectedDecision = $Expected
    if ($decision -cne $expectedDecision) {
        Write-Output "FAIL [$Name]: expected $expectedDecision, got $decision"
        $script:failures++
        return
    }
    if ($decision -eq 'deny' -and [string]::IsNullOrWhiteSpace($reason)) {
        Write-Output "FAIL [$Name]: deny without permissionDecisionReason"
        $script:failures++
        return
    }
    if ($Expected -eq 'allow' -and -not [string]::IsNullOrWhiteSpace($result.Stdout)) {
        Write-Output "FAIL [$Name]: allow emitted stdout"
        $script:failures++
        return
    }
    if ($Expected -eq 'deny') {
        foreach ($fragment in $ReasonMustContains) {
            if (-not $reason.Contains($fragment)) {
                Write-Output "FAIL [$Name]: deny reason lacks '$fragment'"
                $script:failures++
                return
            }
        }
        foreach ($fragment in $ReasonMustNotContain) {
            if ($reason.Contains($fragment)) {
                Write-Output "FAIL [$Name]: deny reason contains '$fragment'"
                $script:failures++
                return
            }
        }
    }
    Write-Output "PASS [$Name]: $Expected"
}

# Returns the named property of a decoded object, matched by exact name, or
# $null when the object is $null or has no such property, without tripping
# strict mode. The leading comma stops the pipeline from unrolling an array
# value into its first element.
function Get-OptionalProperty {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $property.Name -cne $Name) { return $null }
    return , $property.Value
}

# Keeps each FAIL line on one line and short, whatever the hook printed.
function Get-ShortText {
    param([AllowEmptyString()][string]$Text)
    $singleLine = $Text -replace '\r?\n', ' '
    if ($singleLine.Length -le $FailureTextLength) { return $singleLine }
    return $singleLine.Substring(0, $FailureTextLength) + '...'
}

# Writes a copy of the rendered hook with some installed values replaced, so a
# case can exercise a copy whose constants differ from this one, such as a
# broken install or an opted-out one. Returns the temp path.
function New-VariantScript {
    param([Parameter(Mandatory)][hashtable]$Values)
    $text = $RenderedHookText
    foreach ($name in $Values.Keys) {
        $pattern = '(?m)^\$' + $name + ' = ''[^'']*''(?=\r?$)'
        $match = [regex]::Match($text, $pattern)
        if (-not $match.Success) { throw "The rendered guard script does not define $name." }
        $text = $text.Replace($match.Value, ('$' + $name + " = '" + $Values[$name] + "'"))
    }
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('guard-variant-' + [System.Guid]::NewGuid().ToString('N') + '.ps1')
    [System.IO.File]::WriteAllText($path, $text)
    return $path
}

# Builds the harness event JSON with a raw tool_input object, so a case can
# send text a hashtable cannot express, such as duplicate keys with different
# spellings, a trailing comma, or JSON escape sequences.
function New-RawHookInputJson {
    param([Parameter(Mandatory)][string]$ToolInputJson)
    return '{"hook_event_name":"PreToolUse","session_id":"test-session","timestamp":"2026-11-04T01:00:00Z","cwd":"C:\\repo","tool_name":"Task","tool_input":' + $ToolInputJson + '}'
}

function ConvertTo-CaseJson {
    param([Parameter(Mandatory)][string]$ToolName, [AllowNull()][object]$ToolInput)
    return (New-HookInput -ToolName $ToolName -ToolInput $ToolInput) |
        ConvertTo-Json -Depth 8 -Compress
}

try {
    # Fragments of the note the guard adds when a required field appears only
    # under another spelling.
    $lookAlikeHintFragments = @('matched exactly', 'out of date', 'tell the user')
    # The repo template ships placeholders. A copy that reaches use without
    # the installer must deny rather than silently skip the effort check.
    $rawTemplateText = [System.IO.File]::ReadAllText($HookTemplatePath)
    if ($rawTemplateText.Contains('__OWL_MODEL__')) {
        Invoke-ExpectedCase -Name 'unfilled guard template denies reviewer calls' -Expected 'deny' `
            -ScriptPath $HookTemplatePath `
            -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Owl'; model = 'm'; reasoning_effort = 'high' }) `
            -ReasonMustContains @('not configured', 'Surface this to the user', 're-run the installer')

        # An unfilled default placeholder is the same broken install, and it
        # must deny with its own advice rather than let the literal through.
        Invoke-ExpectedCase -Name 'unfilled guard template denies non-reviewer calls' -Expected 'deny' `
            -ScriptPath $HookTemplatePath `
            -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'explore'; prompt = 'x' }) `
            -ReasonMustContains @('not configured', 'Surface this to the user', 're-run the installer')
    }

    # Deny cases: a reviewer call missing model or reasoning_effort must be
    # denied with an instructive reason that names the expected values and
    # sends the caller to its own instructions, regardless of the model value.
    $denyReasonFragments = @(
        'model', 'reasoning_effort', 'Retry', 'Owl',
        $OwlModel, $OwlEffort, 'Subagent Delegation Rules', 'agent instructions'
    )
    Invoke-ExpectedCase -Name 'Owl without model or effort' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Agent' @{ agent_type = 'Owl'; prompt = 'just say OK' }) `
        -ReasonMustContains $denyReasonFragments `
        -ReasonMustNotContain (@('guard script') + $lookAlikeHintFragments)

    Invoke-ExpectedCase -Name 'Task tool name fallback still judged' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Owl'; prompt = 'x' })

    Invoke-ExpectedCase -Name 'Owl without model only' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Owl'; prompt = 'x'; reasoning_effort = $OwlEffort }) `
        -ReasonMustContains @('the model field', 'Owl', $OwlModel, $OwlEffort, 'Subagent Delegation Rules')

    Invoke-ExpectedCase -Name 'Owl without effort only' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Owl'; prompt = 'x'; model = $OwlMatchingModel }) `
        -ReasonMustContains @(
            'the reasoning_effort field', 'Owl', $OwlModel, $OwlEffort,
            'Subagent Delegation Rules', 'agent instructions'
        )

    Invoke-ExpectedCase -Name 'Cat without model or effort' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Cat'; prompt = 'x' }) `
        -ReasonMustContains @('Cat', 'model', 'reasoning_effort', $CatModel, $CatEffort, 'Subagent Delegation Rules') `
        -ReasonMustNotContain @('guard script')

    Invoke-ExpectedCase -Name 'lowercase agent name owl' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'task' @{ agent_type = 'owl'; prompt = 'x' })

    Invoke-ExpectedCase -Name 'camelCase agentType still guarded' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agentType = 'Owl'; prompt = 'x' })

    Invoke-ExpectedCase -Name 'empty string model counts as missing' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Owl'; model = ''; reasoning_effort = $OwlEffort })

    Invoke-ExpectedCase -Name 'whitespace model counts as missing' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Owl'; model = '   '; reasoning_effort = $OwlEffort })

    Invoke-ExpectedCase -Name 'null model counts as missing' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Owl'; model = $null; reasoning_effort = $OwlEffort })

    # Deny cases: the call uses the configured model, so the effort must
    # match the installed value.
    Invoke-ExpectedCase -Name 'matching Owl model with wrong effort' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Agent' @{ agent_type = 'Owl'; prompt = 'x'; model = $OwlMatchingModel; reasoning_effort = $OtherOwlEffort }) `
        -ReasonMustContains @('reasoning_effort', $OwlModel, $OwlEffort, 'Owl', 'Subagent Delegation Rules', 'agent instructions') `
        -ReasonMustNotContain (@('guard script') + $lookAlikeHintFragments)

    Invoke-ExpectedCase -Name 'matching Owl model with out-of-set effort' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Agent' @{ agent_type = 'Owl'; prompt = 'x'; model = $OwlMatchingModel; reasoning_effort = 'ultra' })

    Invoke-ExpectedCase -Name 'matching Cat model with wrong effort' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Agent' @{ agent_type = 'Cat'; prompt = 'x'; model = $CatMatchingModel; reasoning_effort = $OtherCatEffort }) `
        -ReasonMustContains @(
            'reasoning_effort', $CatModel, $CatEffort, 'Cat',
            'Subagent Delegation Rules', 'agent instructions'
        ) `
        -ReasonMustNotContain @('guard script')

    Invoke-ExpectedCase -Name 'matching model case-insensitive with wrong effort' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Agent' @{ agent_type = 'Owl'; prompt = 'x'; model = $OwlMatchingModel.ToUpperInvariant(); reasoning_effort = $OtherOwlEffort })

    Invoke-ExpectedCase -Name 'configured model inside a longer model with wrong effort' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Agent' @{ agent_type = 'Owl'; prompt = 'x'; model = ('vendor/' + $OwlModel + '/preview'); reasoning_effort = $OtherOwlEffort })

    Invoke-ExpectedCase -Name 'lowercase agent type still compares effort' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Agent' @{ agent_type = 'owl'; prompt = 'x'; model = $OwlMatchingModel; reasoning_effort = $OtherOwlEffort }) `
        -ReasonMustContains @('reasoning_effort', $OwlEffort)

    # Presence is unconditional, so a model override cannot omit the effort
    # field even though its value is not compared.
    Invoke-ExpectedCase -Name 'model override without effort still denied' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Owl'; prompt = 'x'; model = $OverrideModel }) `
        -ReasonMustContains @('the reasoning_effort field', 'Owl', $OwlModel, $OwlEffort, 'Subagent Delegation Rules')

    # Allow cases: presence and the conditional value check pass for the
    # reviewer calls that carry both fields.
    Invoke-ExpectedCase -Name 'Owl with matching model and exact effort' -Expected 'allow' `
        -StdinJson (ConvertTo-CaseJson 'Agent' @{ agent_type = 'Owl'; prompt = 'x'; model = $OwlMatchingModel; reasoning_effort = $OwlEffort })

    Invoke-ExpectedCase -Name 'Owl matching effort is case-insensitive' -Expected 'allow' `
        -StdinJson (ConvertTo-CaseJson 'Agent' @{ agent_type = 'Owl'; prompt = 'x'; model = $OwlMatchingModel; reasoning_effort = $OwlEffort.ToUpperInvariant() })

    Invoke-ExpectedCase -Name 'effort surrounding whitespace is trimmed' -Expected 'allow' `
        -StdinJson (ConvertTo-CaseJson 'Agent' @{ agent_type = 'Owl'; prompt = 'x'; model = $OwlMatchingModel; reasoning_effort = ('  ' + $OwlEffort + '  ') })

    Invoke-ExpectedCase -Name 'a model the user names with another effort is allowed' -Expected 'allow' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Owl'; prompt = 'x'; model = $OverrideModel; reasoning_effort = $OtherOwlEffort })

    Invoke-ExpectedCase -Name 'a model the user names with an out-of-set effort is allowed' -Expected 'allow' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Owl'; prompt = 'x'; model = $OverrideModel; reasoning_effort = 'ultra' })

    Invoke-ExpectedCase -Name 'Cat with matching model and exact effort' -Expected 'allow' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Cat'; prompt = 'x'; model = $CatMatchingModel; reasoning_effort = $CatEffort })

    Invoke-ExpectedCase -Name 'Cat with a model override and another effort' -Expected 'allow' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Cat'; prompt = 'x'; model = $CatOverrideModel; reasoning_effort = $OtherCatEffort })

    # A required field counts only under its exact spelling, the name the
    # harness reads. A differently spelled key is reported as a missing field,
    # with a note naming the exact spelling and a possibly stale guard.
    Invoke-ExpectedCase -Name 'camelCase reasoningEffort does not satisfy the field' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agentType = 'owl'; model = $OwlMatchingModel; reasoningEffort = $OwlEffort }) `
        -ReasonMustContains (@('the reasoning_effort field') + $lookAlikeHintFragments)

    Invoke-ExpectedCase -Name 'mixed case required keys satisfy nothing' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Agent' @{ agentType = 'owl'; Model = $OwlMatchingModel; reasoningEffort = $OwlEffort }) `
        -ReasonMustContains (@('the model and reasoning_effort fields') + $lookAlikeHintFragments)

    Invoke-ExpectedCase -Name 'camelCase Model alone is a look-alike, not a model' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Agent' @{ agent_type = 'Owl'; Model = $OwlMatchingModel; reasoning_effort = $OwlEffort }) `
        -ReasonMustContains (@('the model field', 'Owl') + $lookAlikeHintFragments)

    # Non-reviewer calls are judged against the installed default pair exactly
    # like reviewer calls, so a call that names no model is denied with the
    # values to retry with instead of running on a harness default that the
    # configured provider may not serve. The reason stands alone, because the
    # hook is user-level and the caller may be an agent with no squad
    # instructions.
    $defaultDenyFragments = @(
        'model', 'reasoning_effort', $DefaultSubagentModel, $DefaultSubagentEffort,
        'Retry', 'does not inherit'
    )
    Invoke-ExpectedCase -Name 'explore without model or effort is denied' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'explore'; prompt = 'x'; mode = 'sync'; name = 'probe' }) `
        -ReasonMustContains $defaultDenyFragments `
        -ReasonMustNotContain @('Subagent Delegation Rules', 'agent instructions', 'explore')

    Invoke-ExpectedCase -Name 'custom agent without model is denied' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Agent' @{ agent_type = 'custom-agent'; description = 'd'; prompt = 'x' }) `
        -ReasonMustContains $defaultDenyFragments

    Invoke-ExpectedCase -Name 'entry point agent without model is denied' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Capybara'; prompt = 'x' }) `
        -ReasonMustContains $defaultDenyFragments

    Invoke-ExpectedCase -Name 'Duo agent without model is denied' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Capybara Duo'; prompt = 'x' }) `
        -ReasonMustContains $defaultDenyFragments

    Invoke-ExpectedCase -Name 'built-in agent without model is denied' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'general-purpose'; prompt = 'x' }) `
        -ReasonMustContains $defaultDenyFragments

    Invoke-ExpectedCase -Name 'camelCase agentType without model is denied' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agentType = 'explore'; prompt = 'x' }) `
        -ReasonMustContains $defaultDenyFragments

    Invoke-ExpectedCase -Name 'non-reviewer call without model only is denied' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'explore'; reasoning_effort = $DefaultSubagentEffort }) `
        -ReasonMustContains @('the model field', $DefaultSubagentModel, $DefaultSubagentEffort) `
        -ReasonMustNotContain @('Subagent Delegation Rules')

    Invoke-ExpectedCase -Name 'non-reviewer call without effort only is denied' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'explore'; model = $DefaultMatchingModel }) `
        -ReasonMustContains @('the reasoning_effort field', $DefaultSubagentEffort) `
        -ReasonMustNotContain @('Subagent Delegation Rules')

    Invoke-ExpectedCase -Name 'empty model on a non-reviewer call counts as missing' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'explore'; model = ''; reasoning_effort = $DefaultSubagentEffort }) `
        -ReasonMustContains @('the model field', $DefaultSubagentModel)

    Invoke-ExpectedCase -Name 'whitespace model on a non-reviewer call counts as missing' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'explore'; model = '   '; reasoning_effort = $DefaultSubagentEffort }) `
        -ReasonMustContains @('the model field', $DefaultSubagentModel)

    Invoke-ExpectedCase -Name 'null model on a non-reviewer call counts as missing' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'explore'; model = $null; reasoning_effort = $DefaultSubagentEffort }) `
        -ReasonMustContains @('the model field', $DefaultSubagentModel)

    Invoke-ExpectedCase -Name 'non-reviewer call with the default model and another effort is denied' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'explore'; model = $DefaultMatchingModel; reasoning_effort = $OtherDefaultEffort }) `
        -ReasonMustContains @('does not match', $DefaultSubagentEffort) `
        -ReasonMustNotContain @('Subagent Delegation Rules', 'explore')

    Invoke-ExpectedCase -Name 'non-reviewer default model match is case-insensitive' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'explore'; model = $DefaultMatchingModel.ToUpperInvariant(); reasoning_effort = $OtherDefaultEffort }) `
        -ReasonMustContains @('does not match', $DefaultSubagentEffort)

    Invoke-ExpectedCase -Name 'non-reviewer call with another model and no effort is denied' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'explore'; model = $DefaultOverrideModel }) `
        -ReasonMustContains @('the reasoning_effort field', $DefaultSubagentEffort)

    Invoke-ExpectedCase -Name 'non-reviewer call with the default model and exact effort' -Expected 'allow' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'explore'; model = $DefaultMatchingModel; reasoning_effort = $DefaultSubagentEffort })

    Invoke-ExpectedCase -Name 'non-reviewer effort is case-insensitive' -Expected 'allow' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'explore'; model = $DefaultMatchingModel; reasoning_effort = $DefaultSubagentEffort.ToUpperInvariant() })

    Invoke-ExpectedCase -Name 'non-reviewer call with another model and another effort' -Expected 'allow' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'explore'; prompt = 'x'; model = $DefaultOverrideModel; reasoning_effort = $OtherDefaultEffort })

    Invoke-ExpectedCase -Name 'non-reviewer call with another model and an out-of-set effort' -Expected 'allow' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'explore'; prompt = 'x'; model = $DefaultOverrideModel; reasoning_effort = 'ultra' })

    Invoke-ExpectedCase -Name 'non-reviewer camelCase reasoningEffort is a look-alike' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agentType = 'explore'; model = $DefaultMatchingModel; reasoningEffort = $DefaultSubagentEffort }) `
        -ReasonMustContains (@('the reasoning_effort field') + $lookAlikeHintFragments) `
        -ReasonMustNotContain @('Subagent Delegation Rules', 'agent instructions')

    # A tool_input delivered as a raw JSON string is parsed before the fields
    # are read, so the default rule applies to both forms.
    $stringDefaultInput = (@{ agent_type = 'explore'; model = $DefaultMatchingModel; reasoning_effort = $DefaultSubagentEffort } | ConvertTo-Json -Compress)
    Invoke-ExpectedCase -Name 'string tool_input satisfies the default rule' -Expected 'allow' `
        -StdinJson ((New-HookInput -ToolName 'Task' -ToolInput $stringDefaultInput) |
            ConvertTo-Json -Depth 8 -Compress)

    # A tool_input nested past the parser ceiling cannot be read, so it fails
    # open with no stdout at all.
    $deepValue = '"x"'
    for ($depth = 0; $depth -lt 1100; $depth++) { $deepValue = '{"n":' + $deepValue + '}' }
    $deepToolInput = '{"agent_type":"explore","prompt":"x","extra":' + $deepValue + '}'
    Invoke-ExpectedCase -Name 'deeply nested tool_input fails open without stdout' -Expected 'allow' `
        -StdinJson ((New-HookInput -ToolName 'Task' -ToolInput $deepToolInput) |
            ConvertTo-Json -Depth 8 -Compress)

    # A copy rendered with empty defaults is the user opting out of checking
    # ordinary subagent calls, and reviewer enforcement must survive that
    # opt-out.
    $blankDefaultPath = New-VariantScript -Values @{
        DefaultSubagentModel = ''
        DefaultSubagentReasoningEffort = ''
    }
    try {
        Invoke-ExpectedCase -Name 'empty default pair leaves model-less calls alone' -Expected 'allow' `
            -ScriptPath $blankDefaultPath `
            -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'explore'; prompt = 'x' })
        Invoke-ExpectedCase -Name 'empty default pair still enforces reviewers' -Expected 'deny' `
            -ScriptPath $blankDefaultPath `
            -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Owl'; prompt = 'x' }) `
            -ReasonMustContains @('Owl', 'Subagent Delegation Rules')
    }
    finally {
        if (Test-Path -LiteralPath $blankDefaultPath) { Remove-Item -LiteralPath $blankDefaultPath -Force -ErrorAction SilentlyContinue }
    }

    # Half a default pair is what the installer refuses to write, and it cannot
    # be enforced, so each half is a broken install rather than a judgement.
    foreach ($halfPair in @(
            @{ Name = 'blank default model with a set effort'; Values = @{ DefaultSubagentModel = '' } },
            @{ Name = 'set default model with a blank effort'; Values = @{ DefaultSubagentReasoningEffort = '' } },
            @{ Name = 'default effort left as a placeholder'; Values = @{ DefaultSubagentReasoningEffort = '__DEFAULT_SUBAGENT_REASONING_EFFORT__' } })) {
        $halfPairPath = New-VariantScript -Values $halfPair.Values
        try {
            Invoke-ExpectedCase -Name $halfPair.Name -Expected 'deny' `
                -ScriptPath $halfPairPath `
                -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'explore'; prompt = 'x' }) `
                -ReasonMustContains @('not configured', 're-run the installer')
        }
        finally {
            if (Test-Path -LiteralPath $halfPairPath) { Remove-Item -LiteralPath $halfPairPath -Force -ErrorAction SilentlyContinue }
        }
    }

    # A blank reviewer value cannot be judged against, so a copy that holds one
    # is a broken install rather than silently unenforced. A whitespace-only
    # value counts as blank, because it names no model or effort to compare
    # against.
    foreach ($blankReviewerValue in @(
            @{ Name = 'blank Owl model'; Values = @{ OwlModel = '' } },
            @{ Name = 'blank Owl effort'; Values = @{ OwlReasoningEffort = '' } },
            @{ Name = 'whitespace Owl model'; Values = @{ OwlModel = '   ' } },
            @{ Name = 'whitespace Owl effort'; Values = @{ OwlReasoningEffort = '  ' } })) {
        $blankReviewerPath = New-VariantScript -Values $blankReviewerValue.Values
        try {
            Invoke-ExpectedCase -Name $blankReviewerValue.Name -Expected 'deny' `
                -ScriptPath $blankReviewerPath `
                -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Owl'; prompt = 'x' }) `
                -ReasonMustContains @('not configured', 'Owl', 're-run the installer')
        }
        finally {
            if (Test-Path -LiteralPath $blankReviewerPath) { Remove-Item -LiteralPath $blankReviewerPath -Force -ErrorAction SilentlyContinue }
        }
    }

    # The depth ceiling exists so a deeply nested call is still judged instead
    # of failing open on a parse error. Both parse sites need the case, because
    # object and string tool_input are parsed separately.
    $nested100 = '"x"'
    for ($depth = 0; $depth -lt 100; $depth++) { $nested100 = '{"n":' + $nested100 + '}' }
    $nestedReviewerToolInput = '{"agent_type":"Owl","prompt":"x","extra":' + $nested100 + '}'
    Invoke-ExpectedCase -Name 'reviewer call nested 100 levels is denied' -Expected 'deny' `
        -StdinJson (New-RawHookInputJson -ToolInputJson $nestedReviewerToolInput) `
        -ReasonMustContains @('Owl', 'Subagent Delegation Rules')
    Invoke-ExpectedCase -Name 'reviewer call nested 100 levels in a string tool_input is denied' -Expected 'deny' `
        -StdinJson ((New-HookInput -ToolName 'Task' -ToolInput $nestedReviewerToolInput) |
            ConvertTo-Json -Depth 8 -Compress) `
        -ReasonMustContains @('Owl', 'Subagent Delegation Rules')
    $nestedDefaultToolInput = '{"agent_type":"explore","prompt":"x","extra":' + $nested100 + '}'
    Invoke-ExpectedCase -Name 'ordinary call nested 100 levels takes the default rule' -Expected 'deny' `
        -StdinJson (New-RawHookInputJson -ToolInputJson $nestedDefaultToolInput) `
        -ReasonMustContains @('does not inherit')

    # A reader looks keys up by exact spelling, so a later key that differs
    # only in case must not override the exact one, and a reviewer named under
    # either agent_type spelling must keep the call a reviewer call. Raw JSON
    # is needed because a hashtable cannot hold two spellings of one key.
    Invoke-ExpectedCase -Name 'a later differently cased agent_type cannot hide a reviewer' -Expected 'deny' `
        -StdinJson (New-RawHookInputJson -ToolInputJson '{"agent_type":"Owl","Agent_Type":"explore","prompt":"x"}') `
        -ReasonMustContains @('Owl', 'Subagent Delegation Rules')
    Invoke-ExpectedCase -Name 'a reviewer named under a differently cased agent_type is a reviewer call' -Expected 'deny' `
        -StdinJson (New-RawHookInputJson -ToolInputJson '{"Agent_Type":"Owl","prompt":"x"}') `
        -ReasonMustContains @('Owl', 'Subagent Delegation Rules')

    # Invisible characters do not disguise a reviewer name, because a reader
    # that strips them would still run the reviewer. The JSON escapes keep
    # this file ASCII.
    # The tag character U+E0001 lies outside the Basic Multilingual Plane and
    # arrives as a surrogate pair, and the zero-width space before a space
    # checks that stripping happens before trimming.
    foreach ($disguisedName in @('\uFEFFOwl', 'O\u200Bwl', 'Ow\u00ADl', 'Owl\u0000', 'Owl\uDB40\uDC01', '\u200B Owl')) {
        Invoke-ExpectedCase -Name "reviewer name with an invisible character is a reviewer call: $disguisedName" -Expected 'deny' `
            -StdinJson (New-RawHookInputJson -ToolInputJson ('{"agent_type":"' + $disguisedName + '","prompt":"x"}')) `
            -ReasonMustContains @('Owl', 'Subagent Delegation Rules')
    }

    # The reviewer match is exact after stripping, so a name that only
    # contains a reviewer name is an ordinary agent and takes the default rule.
    Invoke-ExpectedCase -Name 'a name that only contains a reviewer name takes the default rule' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Owl 2'; prompt = 'x' }) `
        -ReasonMustContains @('does not inherit') `
        -ReasonMustNotContain @('Owl', 'Subagent Delegation Rules')

    Invoke-ExpectedCase -Name 'a reviewer named under agentType keeps the call a reviewer call' -Expected 'deny' `
        -StdinJson (New-RawHookInputJson -ToolInputJson '{"agent_type":"explore","agentType":"Owl","prompt":"x"}') `
        -ReasonMustContains @('Owl', 'Subagent Delegation Rules')
    Invoke-ExpectedCase -Name 'the exact reasoning_effort spelling wins over a cased duplicate' -Expected 'deny' `
        -StdinJson (New-RawHookInputJson -ToolInputJson ('{"agent_type":"Owl","prompt":"x","model":"' + $OwlMatchingModel + '","reasoning_effort":"' + $OtherOwlEffort + '","Reasoning_Effort":"' + $OwlEffort + '"}')) `
        -ReasonMustContains @('does not match', $OwlEffort)
    Invoke-ExpectedCase -Name 'the exact model spelling wins over a cased duplicate' -Expected 'deny' `
        -StdinJson (New-RawHookInputJson -ToolInputJson ('{"agent_type":"Owl","prompt":"x","model":"","Model":"' + $OwlMatchingModel + '","reasoning_effort":"' + $OwlEffort + '"}')) `
        -ReasonMustContains @('the model field', $OwlModel)

    # A repeated key is judged on its last occurrence, the one a downstream
    # JSON reader keeps. Reading the first would accept a usable model that the
    # reader then replaces with an empty one, running the reviewer on the
    # harness default.
    Invoke-ExpectedCase -Name 'a repeated model is judged on its last occurrence' -Expected 'deny' `
        -StdinJson (New-RawHookInputJson -ToolInputJson ('{"agent_type":"Owl","prompt":"x","model":"' + $OwlMatchingModel + '","model":"","reasoning_effort":"' + $OwlEffort + '"}')) `
        -ReasonMustContains @('the model field', $OwlModel)

    # A reviewer named in any occurrence of agent_type keeps the call a
    # reviewer call, so an earlier decoy cannot turn it into a default-model
    # call.
    Invoke-ExpectedCase -Name 'a reviewer in a repeated agent_type keeps the call a reviewer call' -Expected 'deny' `
        -StdinJson ((New-HookInput -ToolName 'Task' -ToolInput '{"agent_type":"explore","agent_type":"Owl","prompt":"x"}') |
            ConvertTo-Json -Depth 8 -Compress) `
        -ReasonMustContains @('Owl', 'Subagent Delegation Rules')

    # A trailing comma keeps the reviewer call enforceable.
    Invoke-ExpectedCase -Name 'reviewer call with a trailing comma is denied' -Expected 'deny' `
        -StdinJson (New-RawHookInputJson -ToolInputJson '{"agent_type":"Owl","prompt":"x",}') `
        -ReasonMustContains @('Owl', 'Subagent Delegation Rules')

    # A blank exact field is missing, but its own key is not a look-alike, so
    # the reason carries no note about field names.
    Invoke-ExpectedCase -Name 'a blank exact field alone gets no look-alike note' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'explore'; model = $DefaultMatchingModel; reasoning_effort = '' }) `
        -ReasonMustContains @('the reasoning_effort field') `
        -ReasonMustNotContain @($lookAlikeHintFragments)

    # A look-alike beside a blank exact field does add the note, because the
    # field is missing and another spelling of it is present.
    Invoke-ExpectedCase -Name 'blank reasoning_effort beside reasoningEffort gets the note' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Owl'; prompt = 'x'; model = $OwlMatchingModel; reasoning_effort = ''; reasoningEffort = $OwlEffort }) `
        -ReasonMustContains (@('the reasoning_effort field') + $lookAlikeHintFragments)

    # A look-alike for a field that is present adds nothing, because only the
    # missing fields are searched for one.
    Invoke-ExpectedCase -Name 'a look-alike for a present field adds no note' -Expected 'deny' `
        -StdinJson (New-RawHookInputJson -ToolInputJson ('{"agent_type":"explore","prompt":"x","reasoning_effort":"' + $DefaultSubagentEffort + '","reasoningEffort":"' + $OtherDefaultEffort + '"}')) `
        -ReasonMustContains @('the model field') `
        -ReasonMustNotContain @($lookAlikeHintFragments)

    # A look-alike beside a usable exact field changes nothing, because the
    # rule only reads the exact spelling.
    Invoke-ExpectedCase -Name 'a look-alike beside a valid exact field is ignored' -Expected 'allow' `
        -StdinJson (New-RawHookInputJson -ToolInputJson ('{"agent_type":"Owl","prompt":"x","model":"' + $OwlMatchingModel + '","reasoning_effort":"' + $OwlEffort + '","Reasoning_Effort":"' + $OtherOwlEffort + '"}'))

    # A key that normalizes to nothing cannot name a field, so it is compared
    # as an ordinary key and the call is judged rather than failing open.
    Invoke-ExpectedCase -Name 'an empty key does not break the look-alike check' -Expected 'deny' `
        -StdinJson (New-RawHookInputJson -ToolInputJson '{"":"x","agent_type":"explore","prompt":"x"}') `
        -ReasonMustContains @('the model and reasoning_effort fields') `
        -ReasonMustNotContain @($lookAlikeHintFragments)

    # An empty key does not stop the search, so a look-alike after it is still
    # reported.
    Invoke-ExpectedCase -Name 'a look-alike after an empty key is still reported' -Expected 'deny' `
        -StdinJson (New-RawHookInputJson -ToolInputJson '{"":"x","agent_type":"explore","prompt":"x","Model":"m"}') `
        -ReasonMustContains (@('the model and reasoning_effort fields') + $lookAlikeHintFragments)

    # Every spelling of a required field is recognized, so the caller is told
    # what to do instead of being left to guess.
    foreach ($lookAlikeName in 'Model', 'mod\u200Bel', 'reasoningEffort', 'Reasoning-Effort', 'reasoning effort') {
        $lookAlikeToolInput = '{"agent_type":"explore","prompt":"x","' + $lookAlikeName + '":"' + $DefaultMatchingModel + '"}'
        Invoke-ExpectedCase -Name "look-alike key is reported, not accepted: $lookAlikeName" -Expected 'deny' `
            -StdinJson (New-RawHookInputJson -ToolInputJson $lookAlikeToolInput) `
            -ReasonMustContains $lookAlikeHintFragments `
            -ReasonMustNotContain @('Subagent Delegation Rules', 'agent instructions')
    }

    # mode is a real task argument that differs from model by one letter, so it
    # must not be mistaken for a look-alike of it.
    Invoke-ExpectedCase -Name 'mode is not a look-alike of model' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'explore'; prompt = 'x'; mode = 'sync' }) `
        -ReasonMustContains @('the model and reasoning_effort fields') `
        -ReasonMustNotContain @($lookAlikeHintFragments)

    # A missing field with no look-alike gets the plain reason, without the
    # note about field names.
    Invoke-ExpectedCase -Name 'a plain missing field gets no look-alike note' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'explore'; prompt = 'x' }) `
        -ReasonMustNotContain @($lookAlikeHintFragments)

    # An effort mismatch means the field was present, so no note applies.
    Invoke-ExpectedCase -Name 'an effort mismatch carries no look-alike note' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'explore'; model = $DefaultMatchingModel; reasoning_effort = $OtherDefaultEffort }) `
        -ReasonMustContains @('does not match') `
        -ReasonMustNotContain @($lookAlikeHintFragments)

    # The harness payload fields keep the lenient read, where the exact
    # spelling still wins so a decoy cannot reroute the call.
    Invoke-ExpectedCase -Name 'exact tool_name wins over a cased duplicate' -Expected 'allow' `
        -StdinJson '{"hook_event_name":"PreToolUse","tool_name":"Bash","Tool_Name":"task","tool_input":{"agent_type":"explore","prompt":"x"}}'

    # A padded reviewer name is still a reviewer call, so it must be denied
    # rather than judged as an ordinary agent.
    Invoke-ExpectedCase -Name 'padded Owl name still takes the reviewer deny' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = ' Owl '; prompt = 'x' }) `
        -ReasonMustContains @('Owl', 'Subagent Delegation Rules')

    Invoke-ExpectedCase -Name 'missing agent_type fails open' -Expected 'allow' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ prompt = 'x' })

    Invoke-ExpectedCase -Name 'null agent_type fails open' -Expected 'allow' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = $null; prompt = 'x' })

    # A non-subagent tool must early-exit without judging the payload, whatever
    # the payload carries.
    Invoke-ExpectedCase -Name 'other tool not guarded' -Expected 'allow' `
        -StdinJson (ConvertTo-CaseJson 'Bash' @{ agent_type = 'Owl'; prompt = 'x' })

    Invoke-ExpectedCase -Name 'wrong event name not guarded' -Expected 'allow' `
        -StdinJson ((New-HookInput -ToolName 'Task' -ToolInput @{ agent_type = 'Owl' } -EventName 'PostToolUse') |
            ConvertTo-Json -Depth 8 -Compress)

    Invoke-ExpectedCase -Name 'null tool_input fails open' -Expected 'allow' `
        -StdinJson (ConvertTo-CaseJson 'Task' $null)

    Invoke-ExpectedCase -Name 'empty stdin fails open' -Expected 'allow' `
        -StdinJson '  '

    Invoke-ExpectedCase -Name 'malformed stdin fails open' -Expected 'allow' `
        -StdinJson 'not json at all'

    # A tool_input delivered as a raw JSON string is normalized before the
    # field checks, in both directions.
    $stringDenyInput = (@{ agent_type = 'Owl'; prompt = 'x' } | ConvertTo-Json -Compress)
    Invoke-ExpectedCase -Name 'string tool_input judged' -Expected 'deny' `
        -StdinJson ((New-HookInput -ToolName 'Task' -ToolInput $stringDenyInput) |
            ConvertTo-Json -Depth 8 -Compress)

    $stringAllowInput = (@{ agent_type = 'Owl'; model = $OwlMatchingModel; reasoning_effort = $OwlEffort } | ConvertTo-Json -Compress)
    Invoke-ExpectedCase -Name 'string tool_input with fields allowed' -Expected 'allow' `
        -StdinJson ((New-HookInput -ToolName 'Task' -ToolInput $stringAllowInput) |
            ConvertTo-Json -Depth 8 -Compress)

    if ($failures -gt 0) {
        Write-Output "$failures case(s) failed."
    }
    else {
        Write-Output 'All cases passed.'
    }
}
finally {
    if (Test-Path -LiteralPath $HookScript) {
        Remove-Item -LiteralPath $HookScript -Force -ErrorAction SilentlyContinue
    }
}

if ($failures -gt 0) {
    exit 1
}
exit 0
