#requires -Version 7
<#
    Companion script for guard-pwsh-continuation.json (PreToolUse hook),
    adapted for the Copilot SDK harness: the Copilot sessions the VS Code
    Agents window and Chat view run on the Agent Host, plus Copilot CLI,
    which share the same SDK hook implementation.

    Denies a fresh-shell-command tool call whose PowerShell command would
    leave the terminal at the `>>` continuation prompt instead of executing.
    A command in that state produces no output and blocks the tool call
    until the user presses Ctrl+C.

    Detection uses the same mechanism PSReadLine uses to decide whether to
    show the continuation prompt: the official PowerShell parser is run over
    the command and any ParseError flagged IncompleteInput means the console
    would print `>>` and wait for more input. Parse errors that are NOT
    incomplete (for example a stray closing parenthesis) execute and fail
    immediately, so they are allowed through rather than denied.

    Copilot SDK harness contract:
    - The hook file is configured with the PascalCase PreToolUse event, so
      the harness delivers the VS Code compatible payload (hook_event_name,
      session_id, timestamp, cwd, tool_name, tool_input) and reports the
      Claude tool name Bash for its powershell/bash runtime tools. The
      runtime name powershell is kept as a defensive fallback for SDK
      versions that report runtime names.
    - The deny decision uses the flat preToolUse output documented for the
      Copilot SDK harness (permissionDecision plus permissionDecisionReason,
      which is required for a deny). The nested hookSpecificOutput shape
      belongs to the VS Code Local harness and Claude Code; it is not
      emitted, so those harnesses stay unaffected if they ever load the same
      hook file.
    - Command preToolUse hooks fail closed on the Copilot SDK harness: a
      non-zero exit denies the tool call even when stdout reports allow.
      The script therefore exits 0 on every path, including internal
      failure, so a runtime error fails open to allow. On the harness side
      only a timeout fails open, which is fine: the parse runs in well
      under the hook's timeout budget.
    - The version gate pins pwsh 7 so the parse grammar matches the shell
      that runs session commands. The hook config launches the script with
      pwsh explicitly, so the gate is a backstop against the script being
      run by some other interpreter.

    Scope: only fresh shell commands from the Copilot SDK harness are
    checked. Tools that feed input to a process that is already running
    (send_to_terminal, browser typing) are not checked: a PowerShell parse
    of that input has no meaning and would only cause false denials.
    Sessions on non-Windows platforms run bash commands, which a PowerShell
    parse cannot judge, so those are allowed without parsing. The VS Code
    Local harness reports its own tool names (run_in_terminal and friends),
    none of which are checked, so Local sessions stay unaffected.
    Multi-line commands are checked as a whole: the parser is given the
    full string with embedded newlines, which is exactly how the console
    receives a multi-line paste.

    Reads the hook event JSON from stdin and emits the PreToolUse permission
    decision JSON on stdout, always exiting 0. Empty stdout is an allow; the
    deny is communicated via JSON, never via a non-zero exit code.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'

# A runtime failure must fail open to allow; a hook must never block a
# legitimate tool call. Every path below exits 0 because the Copilot SDK
# harness treats any non-zero exit as a deny.

# The only tools whose input is a fresh shell command on the Copilot SDK
# harness. Bash is the Claude-compatible name reported for the powershell
# and bash runtime tools under the PascalCase PreToolUse event; powershell
# is the runtime name, kept as a defensive fallback.
$TerminalToolNames = @('Bash', 'powershell')

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

# Parses the command and returns the first ParseError flagged IncompleteInput,
# or $null when the command is complete. This is the predicate the console
# itself uses before showing the continuation prompt.
function Get-IncompleteParseError {
    param([Parameter(Mandatory)][string]$Command)

    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseInput(
        $Command, [ref]$tokens, [ref]$errors) | Out-Null

    foreach ($parseError in @($errors)) {
        if ($parseError.IncompleteInput) { return $parseError }
    }
    return $null
}

# Builds the deny reason from the parser error: the console prompt the agent
# would have hit plus the fix (rewrite the command) and the quoting hint that
# prevents the most common cause of these errors. Single-quoted segments keep
# the backtick and double quote examples literal.
function Get-DenyReason {
    param([Parameter(Mandatory)]$ParseError)

    $position = 'line {0}, col {1}' -f $ParseError.Extent.StartLineNumber,
        $ParseError.Extent.StartColumnNumber
    $detail = $ParseError.Message
    $reason = 'PowerShell would open the continuation prompt (>>) and hang waiting ' +
        "for more input: $detail (at $position). Rewrite the command as one " +
        'complete statement. In PowerShell, escape a double quote inside a ' +
        'double-quoted string with a backtick (`"), prefer single-quoted ' +
        "strings, and double a single quote inside single quotes (''). Do not " +
        'use bash-style backslash escapes.'
    return $reason
}

$hookEvent = Read-StdinJson
if (-not $hookEvent) { Write-Allow }

if ($hookEvent.hook_event_name -ne 'PreToolUse') { Write-Allow }

if ($hookEvent.tool_name -notin $TerminalToolNames) { Write-Allow }

# Non-Windows sessions run bash commands; a PowerShell parse of those would
# only cause false denials, so allow without parsing.
if (-not $IsWindows) { Write-Allow }

$toolInput = $hookEvent.tool_input
# tool_input normally arrives as a parsed object on the Copilot SDK harness;
# a raw JSON string is normalized before reading .command.
if ($toolInput -is [string]) {
    try { $toolInput = $toolInput | ConvertFrom-Json } catch { $toolInput = $null }
}
$command = if ($toolInput) { $toolInput.command } else { $null }
if (-not $command) { Write-Allow }

$incompleteError = Get-IncompleteParseError -Command ([string]$command)
if ($incompleteError) {
    Write-Deny -Reason (Get-DenyReason -ParseError $incompleteError)
}

Write-Allow