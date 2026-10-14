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
$HookScript = Join-Path $ScriptDir 'guard-subagent-delegation.ps1'

function Invoke-Hook {
    param([Parameter(Mandatory)][string]$StdinJson)
    $stdout = $StdinJson | & pwsh -NoProfile -ExecutionPolicy Bypass -File $HookScript
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
        [string[]]$ReasonMustContains = @()
    )
    $result = Invoke-Hook -StdinJson $StdinJson
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

# Deny cases: a reviewer call missing model or reasoning_effort must be
# denied with an instructive reason.
$denyReasonFragments = @('model', 'reasoning_effort', 'Retry', 'Owl')
Invoke-ExpectedCase -Name 'Owl without model or effort' -Expected 'deny' `
    -StdinJson (ConvertTo-CaseJson 'Agent' @{ agent_type = 'Owl'; prompt = 'just say OK' }) `
    -ReasonMustContains $denyReasonFragments

Invoke-ExpectedCase -Name 'Task tool name fallback still judged' -Expected 'deny' `
    -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Owl'; prompt = 'x' })

Invoke-ExpectedCase -Name 'Owl without model only' -Expected 'deny' `
    -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Owl'; prompt = 'x'; reasoning_effort = 'max' }) `
    -ReasonMustContains @('the model field', 'Owl')

Invoke-ExpectedCase -Name 'Owl without effort only' -Expected 'deny' `
    -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Owl'; prompt = 'x'; model = 'GLM-5.3' }) `
    -ReasonMustContains @('the reasoning_effort field', 'Owl')

Invoke-ExpectedCase -Name 'Cat without model or effort' -Expected 'deny' `
    -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Cat'; prompt = 'x' }) `
    -ReasonMustContains @('Cat', 'model', 'reasoning_effort')

Invoke-ExpectedCase -Name 'lowercase agent name owl' -Expected 'deny' `
    -StdinJson (ConvertTo-CaseJson 'task' @{ agent_type = 'owl'; prompt = 'x' })

Invoke-ExpectedCase -Name 'camelCase agentType still guarded' -Expected 'deny' `
    -StdinJson (ConvertTo-CaseJson 'Task' @{ agentType = 'Owl'; prompt = 'x' })

Invoke-ExpectedCase -Name 'empty string model counts as missing' -Expected 'deny' `
    -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Owl'; model = ''; reasoning_effort = 'max' })

Invoke-ExpectedCase -Name 'whitespace model counts as missing' -Expected 'deny' `
    -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Owl'; model = '   '; reasoning_effort = 'max' })

Invoke-ExpectedCase -Name 'null model counts as missing' -Expected 'deny' `
    -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Owl'; model = $null; reasoning_effort = 'max' })

# Allow cases: presence only enforcement, and non-reviewer or non-subagent
# calls pass through untouched.
Invoke-ExpectedCase -Name 'Owl with both fields' -Expected 'allow' `
    -StdinJson (ConvertTo-CaseJson 'Agent' @{ agent_type = 'Owl'; prompt = 'x'; model = 'GLM-5.3'; reasoning_effort = 'max' })

Invoke-ExpectedCase -Name 'a model the user names still allowed' -Expected 'allow' `
    -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Owl'; prompt = 'x'; model = 'user-named-opus'; reasoning_effort = 'low' })

Invoke-ExpectedCase -Name 'Cat with both fields' -Expected 'allow' `
    -StdinJson (ConvertTo-CaseJson 'Task' @{ agent_type = 'Cat'; prompt = 'x'; model = 'flash'; reasoning_effort = 'low' })

Invoke-ExpectedCase -Name 'camelCase reasoningEffort accepted' -Expected 'allow' `
    -StdinJson (ConvertTo-CaseJson 'Task' @{ agentType = 'owl'; model = 'm'; reasoningEffort = 'max' })

Invoke-ExpectedCase -Name 'mixed case keys recognized' -Expected 'allow' `
    -StdinJson (ConvertTo-CaseJson 'Agent' @{ agentType = 'owl'; Model = 'm'; reasoningEffort = 'max' })

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
$stringDenoInput = '{"agent_type":"Owl","prompt":"x"}'
Invoke-ExpectedCase -Name 'string tool_input judged' -Expected 'deny' `
    -StdinJson ((New-HookInput -ToolName 'Task' -ToolInput $stringDenoInput) |
        ConvertTo-Json -Depth 8 -Compress)

$stringAllowInput = '{"agent_type":"Owl","model":"GLM-5.3","reasoning_effort":"max"}'
Invoke-ExpectedCase -Name 'string tool_input with fields allowed' -Expected 'allow' `
    -StdinJson ((New-HookInput -ToolName 'Task' -ToolInput $stringAllowInput) |
        ConvertTo-Json -Depth 8 -Compress)

if ($failures -gt 0) {
    Write-Output "$failures case(s) failed."
    exit 1
}
Write-Output 'All cases passed.'
exit 0
