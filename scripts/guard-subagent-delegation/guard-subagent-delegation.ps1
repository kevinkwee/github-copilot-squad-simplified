#requires -Version 7
<#
    Companion script for guard-subagent-delegation.json (PreToolUse hook),
    following the guard-pwsh-continuation.ps1 contract on the Copilot SDK
    harness.

    Denies a subagent tool call that starts a squad reviewer (Owl, Cat)
    without the fields the delegation rule requires on every reviewer call:
    model and reasoning_effort. Instructions alone do not enforce those
    fields, and an omitted model silently runs the reviewer on a fallback
    model, so the deny fails loudly. The reason returned to the caller
    names the missing fields and tells it to retry with both fields set,
    or to surface the limitation to the user when its tool cannot set
    them.

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
    - Enforcement is presence only: the delegation rule lets the caller
      run a reviewer on a model the user names for that call instead of
      the configured one, so any non-empty value satisfies the check and
      values are never compared against the configured model.

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

$missingFields = @()
foreach ($requiredFieldName in $RequiredFieldNamesByName.Keys) {
    $candidateNames = @($RequiredFieldNamesByName[$requiredFieldName])
    if (-not (Get-ToolInputValue -ToolInput $toolInput -Names $candidateNames)) {
        $missingFields += $requiredFieldName
    }
}
if ($missingFields.Count -eq 0) { Write-Allow }

if ($missingFields.Count -eq 1) {
    $fieldDescription = 'the {0} field' -f $missingFields[0]
}
else {
    $fieldDescription = 'the {0} and {1} fields' -f $missingFields[0], $missingFields[1]
}

$reason = "The subagent call to $agentType was denied because it omits $fieldDescription that the " +
    'delegation rule requires on every reviewer call. Retry the call with ' +
    'model set to the first available match of the configured reviewer ' +
    'model and reasoning_effort set to the configured effort. If the ' +
    'calling tool cannot set both fields, surface the limitation to the ' +
    'user instead of retrying without them or skipping the review.'

Write-Deny -Reason $reason