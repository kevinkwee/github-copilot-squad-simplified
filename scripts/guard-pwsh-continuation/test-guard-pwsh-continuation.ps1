#requires -Version 7
<#
    Out-of-process test battery for guard-pwsh-continuation.ps1. Each case
    builds the hook stdin JSON the Copilot SDK harness delivers for the
    PascalCase PreToolUse event, pipes it to the hook script, and compares
    the hook's flat permissionDecision against the expected verdict.

    Must run under pwsh 7: a 5.1 interpreter can produce wrong verdicts for
    pwsh 7 command syntax, and the battery's own logic assumes pwsh 7
    semantics. Run with:
      pwsh -NoProfile -File test-guard-pwsh-continuation.ps1
    Exits with code 1 if any case fails and prints a per-case PASS/FAIL line.

    The guard is designed to allow every command on non-Windows platforms
    (sessions there run bash, not PowerShell), so expected denials flip to
    expected allows when the battery itself runs on a non-Windows host.
#>

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$HookScript = Join-Path $ScriptDir 'guard-pwsh-continuation.ps1'

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
        timestamp       = '2026-10-11T12:00:00Z'
        cwd             = 'C:\repo'
        tool_name       = $ToolName
        tool_input      = $ToolInput
    }
}

# On non-Windows the guard allows everything by design, so expected denials
# become expected allows there.
function Get-ExpectedVerdict {
    param([Parameter(Mandatory)][string]$Expected)
    if ($IsWindows) { $Expected }
    elseif ($Expected -eq 'deny') { 'allow' }
    else { $Expected }
}

# The Copilot SDK harness reports the Claude-compatible tool name Bash for
# its powershell/bash runtime tools under the PascalCase PreToolUse event.
$cases = @(
    @{ Name = 'unclosed double quote'; Cmd = 'rg -n "foo'; Expected = 'deny' },
    @{ Name = 'missing closing brace'; Cmd = "if (`$true) { Write-Host 'hi'"; Expected = 'deny' },
    @{ Name = 'dangling pipe'; Cmd = 'Get-ChildItem | '; Expected = 'deny' },
    @{ Name = 'trailing backtick'; Cmd = 'Get-ChildItem `'; Expected = 'deny' },
    @{ Name = 'unclosed single quote'; Cmd = "rg -n 'pattern"; Expected = 'deny' },
    @{ Name = 'incomplete here-string'; Cmd = "@'`r`nline1"; Expected = 'deny' },
    @{ Name = 'incomplete subexpression'; Cmd = '$(Get-Date'; Expected = 'deny' },
    @{ Name = 'unclosed hashtable'; Cmd = '@{ a = 1'; Expected = 'deny' },
    @{ Name = 'bash-style backslash-escaped quote (balanced)'; Cmd = 'git commit -m "fix: resolve \"timeout\" error"'; Expected = 'allow' },
    @{ Name = 'hard syntax error (fails fast, no hang)'; Cmd = 'Write-Host "x" extra)'; Expected = 'allow' },
    @{ Name = 'normal pipeline'; Cmd = 'Get-ChildItem | Select-Object -First 10'; Expected = 'allow' },
    @{ Name = 'backtick-escaped quotes'; Cmd = 'git commit -m "fix: resolve `"timeout`" error"'; Expected = 'allow' },
    @{ Name = 'proper regex single-quote doubling'; Cmd = 'rg -n ''key\s*=\s*[''''"]value[''''"]'' -g ''*.py'' src/'; Expected = 'allow' },
    @{ Name = 'multi-line complete'; Cmd = "if (`$true) {`n    Write-Host 'ok'`n} else {`n    Write-Host 'no'`n}"; Expected = 'allow' },
    @{ Name = 'complete here-string'; Cmd = "@'`r`nline1`r`n'@ | Write-Output"; Expected = 'allow' },
    @{ Name = 'real agent command with pipes and braces'; Cmd = 'rg -n "Group" "c:\path\dashboard.py" | Select-Object -First 10; rg -n "model_name" "c:\path\file.py" | Measure-Object -Line'; Expected = 'allow' }
)

$failures = 0
foreach ($case in $cases) {
    $stdinJson = (New-HookInput -ToolName 'Bash' -ToolInput @{ command = $case.Cmd }) |
        ConvertTo-Json -Depth 6 -Compress
    $result = Invoke-Hook -StdinJson $stdinJson
    $expected = Get-ExpectedVerdict -Expected $case.Expected

    if ($result.ExitCode -ne 0) {
        Write-Output "FAIL [$($case.Name)]: hook exited with $($result.ExitCode)"
        $failures++
        continue
    }

    $parsed = if ([string]::IsNullOrWhiteSpace($result.Stdout)) { $null }
        else { $result.Stdout | ConvertFrom-Json }
    # Normalize empty stdout to the allow verdict for comparison.
    $decision = if ($parsed) { $parsed.permissionDecision } else { 'allow' }

    if ($decision -ne $expected) {
        Write-Output "FAIL [$($case.Name)]: expected $expected, got $decision"
        $failures++
        continue
    }

    # A deny must always carry the reason the Copilot SDK harness requires.
    if ($decision -eq 'deny' -and [string]::IsNullOrWhiteSpace($parsed.permissionDecisionReason)) {
        Write-Output "FAIL [$($case.Name)]: deny without permissionDecisionReason"
        $failures++
        continue
    }

    Write-Output "PASS [$($case.Name)]: $decision"
}

# A non-shell tool must early-exit without parsing any command.
$stdinJson = (New-HookInput -ToolName 'Read' -ToolInput @{ file_path = 'C:\repo\file.txt' }) |
    ConvertTo-Json -Depth 6 -Compress
$result = Invoke-Hook -StdinJson $stdinJson
if ($result.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($result.Stdout)) {
    Write-Output 'PASS [non-shell tool (Read)]: allow (empty)'
}
else {
    Write-Output 'FAIL [non-shell tool (Read)]: expected allow (empty)'
    $failures++
}

# The VS Code Local harness reports run_in_terminal; this hook is adapted
# for the Copilot SDK harness only, so even an incomplete command under that
# tool name must be allowed through untouched.
$stdinJson = (New-HookInput -ToolName 'run_in_terminal' -ToolInput @{ command = 'rg -n "foo' }) |
    ConvertTo-Json -Depth 6 -Compress
$result = Invoke-Hook -StdinJson $stdinJson
if ($result.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($result.Stdout)) {
    Write-Output 'PASS [Local harness run_in_terminal, incomplete command]: allow (empty)'
}
else {
    Write-Output 'FAIL [Local harness run_in_terminal, incomplete command]: expected allow (empty)'
    $failures++
}

# Defensive fallback: a payload reporting the runtime tool name powershell
# must be judged the same way as the Claude tool name Bash.
$stdinJson = (New-HookInput -ToolName 'powershell' -ToolInput @{ command = 'rg -n "foo' }) |
    ConvertTo-Json -Depth 6 -Compress
$result = Invoke-Hook -StdinJson $stdinJson
$expected = Get-ExpectedVerdict -Expected 'deny'
$parsed = if ([string]::IsNullOrWhiteSpace($result.Stdout)) { $null }
    else { $result.Stdout | ConvertFrom-Json }
$decision = if ($parsed) { $parsed.permissionDecision } else { 'allow' }
$reasonPresent = $decision -ne 'deny' -or -not [string]::IsNullOrWhiteSpace($parsed.permissionDecisionReason)
if ($result.ExitCode -eq 0 -and $decision -eq $expected -and $reasonPresent) {
    Write-Output "PASS [runtime tool name powershell, incomplete command]: $decision"
}
else {
    Write-Output "FAIL [runtime tool name powershell, incomplete command]: expected $expected, got $decision"
    $failures++
}

# A command that is complete must produce NO stdout at all (allow by default).
$stdinJson = (New-HookInput -ToolName 'Bash' -ToolInput @{ command = 'Get-Date' }) |
    ConvertTo-Json -Depth 6 -Compress
$result = Invoke-Hook -StdinJson $stdinJson
if ($result.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($result.Stdout)) {
    Write-Output 'PASS [complete command emits no stdout]: allow (empty)'
}
else {
    Write-Output 'FAIL [complete command emits no stdout]: expected allow (empty)'
    $failures++
}

# Malformed stdin JSON must fail open to allow.
$result = Invoke-Hook -StdinJson 'not json at all'
if ($result.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($result.Stdout)) {
    Write-Output 'PASS [malformed stdin JSON]: allow (empty)'
}
else {
    Write-Output 'FAIL [malformed stdin JSON]: expected allow (empty)'
    $failures++
}

# A null tool_input must fail open to allow.
$stdinJson = (New-HookInput -ToolName 'Bash' -ToolInput $null) |
    ConvertTo-Json -Depth 6 -Compress
$result = Invoke-Hook -StdinJson $stdinJson
if ($result.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($result.Stdout)) {
    Write-Output 'PASS [null tool_input]: allow (empty)'
}
else {
    Write-Output 'FAIL [null tool_input]: expected allow (empty)'
    $failures++
}

# An empty or whitespace-only command must fail open to allow.
$stdinJson = (New-HookInput -ToolName 'Bash' -ToolInput @{ command = '   ' }) |
    ConvertTo-Json -Depth 6 -Compress
$result = Invoke-Hook -StdinJson $stdinJson
if ($result.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($result.Stdout)) {
    Write-Output 'PASS [whitespace-only command]: allow (empty)'
}
else {
    Write-Output 'FAIL [whitespace-only command]: expected allow (empty)'
    $failures++
}

# A non-PreToolUse event must fail open to allow.
$stdinJson = (New-HookInput -ToolName 'Bash' -ToolInput @{ command = 'rg -n "foo' } -EventName 'PostToolUse') |
    ConvertTo-Json -Depth 6 -Compress
$result = Invoke-Hook -StdinJson $stdinJson
if ($result.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($result.Stdout)) {
    Write-Output 'PASS [non-PreToolUse event]: allow (empty)'
}
else {
    Write-Output 'FAIL [non-PreToolUse event]: expected allow (empty)'
    $failures++
}

if ($failures -gt 0) {
    Write-Output "$failures case(s) failed."
    exit 1
}
Write-Output 'All cases passed.'
exit 0