#requires -Version 7
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

$valuePatterns = @{
    OwlModel           = '(?m)^\$OwlModel = ''([^'']*)''\r?$'
    CatModel           = '(?m)^\$CatModel = ''([^'']*)''\r?$'
    OwlReasoningEffort = '(?m)^\$OwlReasoningEffort = ''([^'']*)''\r?$'
    CatReasoningEffort = '(?m)^\$CatReasoningEffort = ''([^'']*)''\r?$'
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
$OwlMatchingModel = 'prefix/' + $OwlModel
$CatMatchingModel = 'prefix/' + $CatModel

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
$OverrideModel = New-NonMatchingModel -ConfiguredModel $OwlModel
$CatOverrideModel = New-NonMatchingModel -ConfiguredModel $CatModel

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

# Runs one case: expected is 'allow' (empty stdout, exit 0) or 'deny'
# (flat decision JSON, exit 0). ReasonMustContains, when set, must appear
# in the deny reason.
function Invoke-ExpectedCase {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('allow', 'deny')][string]$Expected,
        [Parameter(Mandatory)][string]$StdinJson,
        [string[]]$ReasonMustContains = @(),
        [string]$ScriptPath = $HookScript
    )
    $result = Invoke-Hook -StdinJson $StdinJson -ScriptPath $ScriptPath
    if ($result.ExitCode -ne 0) {
        Write-Output "FAIL [$Name]: hook exited with $($result.ExitCode)"
        $script:failures++
        return
    }
    $parsed = if ([string]::IsNullOrWhiteSpace($result.Stdout)) { $null }
        else { $result.Stdout | ConvertFrom-Json }
    $decision = if ($parsed) { $parsed.permissionDecision } else { 'allow' }

    if ($decision -ne $Expected) {
        Write-Output "FAIL [$Name]: expected $Expected, got $decision"
        $script:failures++
        return
    }
    if ($decision -eq 'deny' -and [string]::IsNullOrWhiteSpace($parsed.permissionDecisionReason)) {
        Write-Output "FAIL [$Name]: deny without permissionDecisionReason"
        $script:failures++
        return
    }
    if ($decision -eq 'allow' -and -not [string]::IsNullOrWhiteSpace($result.Stdout)) {
        Write-Output "FAIL [$Name]: allow emitted stdout"
        $script:failures++
        return
    }
    if ($Expected -eq 'deny') {
        foreach ($fragment in $ReasonMustContains) {
            if (-not $parsed.permissionDecisionReason.Contains($fragment)) {
                Write-Output "FAIL [$Name]: deny reason lacks '$fragment'"
                $script:failures++
                return
            }
        }
    }
    Write-Output "PASS [$Name]: $decision"
}

function ConvertTo-CaseJson {
    param([Parameter(Mandatory)][string]$ToolName, [AllowNull()][object]$ToolInput)
    return (New-HookInput -ToolName $ToolName -ToolInput $ToolInput) |
        ConvertTo-Json -Depth 8 -Compress
}

try {
    # The repo template ships placeholders. A copy that reaches use without
    # the installer must deny rather than silently skip the effort check.
    $rawTemplateText = [System.IO.File]::ReadAllText($HookTemplatePath)
    if ($rawTemplateText.Contains('__OWL_MODEL__')) {
        Invoke-ExpectedCase -Name 'unfilled guard template denies reviewer calls' -Expected 'deny' `
            -ScriptPath $HookTemplatePath `
            -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Owl'; model = 'm'; reasoning_effort = 'high' }) `
            -ReasonMustContains @('not configured')
    }

    # Deny cases: a reviewer call missing model or reasoning_effort must be
    # denied with an instructive reason, whatever the model.
    $denyReasonFragments = @('model', 'reasoning_effort', 'Retry', 'Owl')
    Invoke-ExpectedCase -Name 'Owl without model or effort' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Agent' @{ agent_type = 'Owl'; prompt = 'just say OK' }) `
        -ReasonMustContains $denyReasonFragments

    Invoke-ExpectedCase -Name 'Task tool name fallback still judged' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Owl'; prompt = 'x' })

    Invoke-ExpectedCase -Name 'Owl without model only' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Owl'; prompt = 'x'; reasoning_effort = $OwlEffort }) `
        -ReasonMustContains @('the model field', 'Owl')

    Invoke-ExpectedCase -Name 'Owl without effort only' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Owl'; prompt = 'x'; model = $OwlMatchingModel }) `
        -ReasonMustContains @('the reasoning_effort field', 'Owl')

    Invoke-ExpectedCase -Name 'Cat without model or effort' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Cat'; prompt = 'x' }) `
        -ReasonMustContains @('Cat', 'model', 'reasoning_effort')

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
        -ReasonMustContains @('reasoning_effort', $OwlEffort, 'Owl')

    Invoke-ExpectedCase -Name 'matching Owl model with out-of-set effort' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Agent' @{ agent_type = 'Owl'; prompt = 'x'; model = $OwlMatchingModel; reasoning_effort = 'ultra' })

    Invoke-ExpectedCase -Name 'matching Cat model with wrong effort' -Expected 'deny' `
        -StdinJson (ConvertTo-CaseJson 'Agent' @{ agent_type = 'Cat'; prompt = 'x'; model = $CatMatchingModel; reasoning_effort = $OtherCatEffort }) `
        -ReasonMustContains @('reasoning_effort', $CatEffort, 'Cat')

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
        -ReasonMustContains @('the reasoning_effort field', 'Owl')

    # Allow cases: presence and the conditional value check pass, and
    # non-reviewer or non-subagent calls pass through untouched.
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

    Invoke-ExpectedCase -Name 'camelCase reasoningEffort accepted' -Expected 'allow' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agentType = 'owl'; model = $OwlMatchingModel; reasoningEffort = $OwlEffort })

    Invoke-ExpectedCase -Name 'mixed case keys recognized' -Expected 'allow' `
        -StdinJson (ConvertTo-CaseJson 'Agent' @{ agentType = 'owl'; Model = $OwlMatchingModel; reasoningEffort = $OwlEffort })

    Invoke-ExpectedCase -Name 'entry point agent not guarded' -Expected 'allow' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Capybara'; prompt = 'x' })

    Invoke-ExpectedCase -Name 'Duo agent not guarded' -Expected 'allow' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Capybara Duo'; prompt = 'x' })

    Invoke-ExpectedCase -Name 'built-in agent not guarded' -Expected 'allow' `
        -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'general-purpose'; prompt = 'x' })

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
