#Requires -Version 5.1
<#
.SYNOPSIS
    Installs or uninstalls the Copilot Squad agents, skills, and hooks.

.DESCRIPTION
    Runs the interactive menu when started with no arguments, or acts on the
    flags for scripted use. Install copies the squad's files into the chosen
    target and overwrites files that conflict by name. Uninstall removes only
    the squad's own items, leaves every other item in place, and reports any
    remaining items matching a squad name for manual review.

    The hooks component covers each hook JSON and its companion script
    folder, because a hook whose script cannot be launched fail-closes every
    tool call of its kind. The installed hook JSONs are rewritten from the
    shipped templates before use, so no placeholder path remains:
      - user level: the placeholder becomes the real profile's .copilot path
      - repo level: the placeholder becomes the repo-relative .github path
    A template without the placeholder aborts the run before anything is
    written.

    Two hooks ship. The shell guard (guard-pwsh-continuation) always travels
    with the hooks component. The subagent delegation guard
    (guard-subagent-delegation) denies a reviewer subagent call that omits
    the model or reasoning effort field, and it also denies an effort that
    differs from the installed reviewer effort when the call's model
    contains the installed reviewer model. It travels per -SubagentGuard:
    Auto installs it with the agents component, Skip leaves it out, and
    Force installs it into any install that includes the agents or hooks
    component, for example a hooks-only install when the agents were copied
    by hand. The guard script is rewritten with the four reviewer values, so
    a hooks-only guard install also requires them.

    The agents component rewrites the two Capybara templates the same way,
    filling the Owl and Cat placeholder pairs with the values collected by
    the menu, or passed with -OwlModel, -OwlReasoningEffort, -CatModel, and
    -CatReasoningEffort for scripted runs. The Capybara Duo template receives
    only the Owl pair. The model values may be full ids, or a distinctive
    part of the name such as GLM-5.3. The values do not have to match
    exactly, and the installed delegation rule resolves them to the first
    available match at run time. Reasoning effort values are limited to
    none, minimal, low, medium, high, xhigh, and max, accepted without
    regard to case and stored in lowercase.

    Runs that select the agents component also manage one entry in the
    user's global git excludes file: the file the global core.excludesFile
    names, or git's default ignore file under XDG_CONFIG_HOME or the git
    home folder's .config folder. The agents write their review reports
    under .github/temp_reports/, and a global exclude keeps those reports
    out of every repository's commits without a shared .gitignore rule that
    would reach contributors who do not use the squad. Install appends the
    entry below a marker comment unless the same pattern is already
    present, and uninstall removes only that marked pair. When git is not on
    PATH, or the excludes file cannot be resolved, is a folder, or is a
    read-only file that would need a write, the entry is skipped with a
    warning and the rest of the run proceeds.

.PARAMETER Action
    install (default) or uninstall.

.PARAMETER Components
    One or more of agents, skills, and hooks, or all (default),
    comma separated (-Components agents,skills).

.PARAMETER Level
    user (default) or repo.

.PARAMETER ProjectRoot
    Project folder that receives .github files at repo level. Required with
    -Level repo.

.PARAMETER UserRoot
    Overrides the user-level target root (default $HOME\.copilot), for tests
    and previews.

.PARAMETER OwlModel
    Model value copied into __OWL_MODEL__ in the installed Capybara
    templates and in the installed subagent delegation guard. May be the
    full id, or a distinctive part of the name, for example GLM-5.3. The
    value cannot contain a single quote or a newline, because the installed
    guard script embeds it in a single-quoted PowerShell literal that must
    stay on one line, and cannot be a placeholder. Required on scripted
    installs that include the agents component or the subagent delegation
    guard.

.PARAMETER OwlReasoningEffort
    Reasoning effort copied into __OWL_REASONING_EFFORT__ in the installed
    Capybara templates and in the installed subagent delegation guard. One
    of none, minimal, low, medium, high, xhigh, or max, accepted without
    regard to case. Required on scripted installs that include the agents
    component or the subagent delegation guard.

.PARAMETER CatModel
    Model value copied into __CAT_MODEL__ in the installed Capybara template
    and in the installed subagent delegation guard. May be the full id, or a
    distinctive part of the name. The value cannot contain a single quote or
    a newline, because the installed guard script embeds it in a
    single-quoted PowerShell literal that must stay on one line, and cannot
    be a placeholder. Required on scripted installs that include the agents
    component or the subagent delegation guard.

.PARAMETER CatReasoningEffort
    Reasoning effort copied into __CAT_REASONING_EFFORT__ in the installed
    Capybara template and in the installed subagent delegation guard. One of
    none, minimal, low, medium, high, xhigh, or max, accepted without regard
    to case. Required on scripted installs that include the agents component
    or the subagent delegation guard.

.PARAMETER SubagentGuard
    How the subagent delegation guard hook travels. Auto (default) installs
    it whenever the agents component is installed. Skip leaves it out and
    fails fast on any install that does not include the agents component.
    Force installs it into any install that includes the agents or hooks
    component, for example a hooks-only install for a hand-maintained
    agents folder, and fails fast when neither is selected. The guard embeds
    the four reviewer values, so installs that include it require all four
    even when the agents component is not selected. Only install runs accept
    a non-Auto value.

.PARAMETER TempReportsExclude
    How the temp reports entry in the global git excludes file is handled.
    Auto (default) adds the entry on installs that select the agents
    component and removes the installer's marked entry on uninstalls that
    select it. Skip leaves the excludes file untouched, and fails fast on
    any run that does not select the agents component.

.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File install.ps1

.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Action install -Components agents,skills -Level user -OwlModel 'GLM-5.3' -OwlReasoningEffort high -CatModel 'flash' -CatReasoningEffort low

.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Action install -Components hooks -Level repo -ProjectRoot C:\projects\my-app

.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Action install -Components hooks -Level user -SubagentGuard Force -OwlModel 'GLM-5.3' -OwlReasoningEffort high -CatModel 'flash' -CatReasoningEffort low

.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Action install -Components agents -Level user -TempReportsExclude Skip -OwlModel 'GLM-5.3' -OwlReasoningEffort high -CatModel 'flash' -CatReasoningEffort low

.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Action uninstall -Level user

.NOTES
    Use -WhatIf to print the planned operations without changing anything.
#>
[CmdletBinding(SupportsShouldProcess, PositionalBinding = $false)]
param(
    [ValidateSet('install', 'uninstall')]
    [string]$Action = 'install',

    [string[]]$Components = 'all',

    [ValidateSet('user', 'repo')]
    [string]$Level = 'user',

    [string]$ProjectRoot,

    [string]$UserRoot,

    [string]$OwlModel,

    [ValidateSet('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max')]
    [string]$OwlReasoningEffort,

    [string]$CatModel,

    [ValidateSet('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max')]
    [string]$CatReasoningEffort,

    [ValidateSet('Auto', 'Skip', 'Force')]
    [string]$SubagentGuard = 'Auto',

    [ValidateSet('Auto', 'Skip')]
    [string]$TempReportsExclude = 'Auto'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RepoRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$AgentFiles = 'Capybara.agent.md', 'CapybaraDuo.agent.md', 'Cat.agent.md', 'Owl.agent.md'
$SkillFolders = 'agents-md', 'commit-message', 'gh-multi-account', 'merge-strategy', 'pr-description'
$HookShellGuardName = 'guard-pwsh-continuation'
$HookSubagentGuardName = 'guard-subagent-delegation'
$HookNames = $HookShellGuardName, $HookSubagentGuardName
$HookUserPlaceholder = 'C:/Users/YOUR-PROFILE'
$HookRepoPlaceholder = 'C:/Users/YOUR-PROFILE/.copilot/scripts'
$OwlModelPlaceholder = '__OWL_MODEL__'
$OwlEffortPlaceholder = '__OWL_REASONING_EFFORT__'
$CatModelPlaceholder = '__CAT_MODEL__'
$CatEffortPlaceholder = '__CAT_REASONING_EFFORT__'
$CapybaraDuoFile = 'CapybaraDuo.agent.md'
$AgentFilesWithPlaceholders = 'Capybara.agent.md', $CapybaraDuoFile
# Parameter attributes cannot reference variables in Windows PowerShell 5.1,
# so the ValidateSet lists on the effort parameters repeat these values.
$ReasoningEffortValues = @('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max')
$DefaultOwlReasoningEffort = 'high'
$DefaultCatReasoningEffort = 'low'
$TempReportsExcludePattern = '**/.github/temp_reports/'
$TempReportsExcludeMarker = '# Copilot Squad agent reports (managed by the squad install.ps1)'
$TempReportsEquivalentPatternRegex = '^\*\*/\.github/temp_reports/?$'
$LeftoverPattern = '^(CapybaraDuo|Capybara|Cat|Owl|guard-pwsh-continuation|guard-subagent-delegation|agents-md|commit-message|gh-multi-account|merge-strategy|pr-description)([._\- ]|$)'

function Read-MenuChoiceIndex {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string[]]$OptionLabels,
        [int]$DefaultIndex = 0
    )
    Write-Host ''
    Write-Host $Prompt
    for ($i = 0; $i -lt $OptionLabels.Count; $i++) {
        Write-Host ('  [{0}] {1}' -f ($i + 1), $OptionLabels[$i])
    }
    $attempt = 0
    while ($attempt -lt 10) {
        $attempt++
        $answer = Read-Host "Enter a number (1-$($OptionLabels.Count)), or press Enter for [$($DefaultIndex + 1)]"
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $DefaultIndex
        }
        if ($answer -match '^\d{1,2}$') {
            $choice = [int]$answer
            if ($choice -ge 1 -and $choice -le $OptionLabels.Count) {
                return $choice - 1
            }
        }
        Write-Host 'Please enter a number from the list.' -ForegroundColor Yellow
    }
    throw 'No valid selection was entered.'
}

function Read-ProjectPathPrompt {
    while ($true) {
        $typed = (Read-Host 'Project folder to receive .github (press Enter for the current folder)').Trim().Trim('"')
        $candidate = $typed
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            $candidate = (Get-Location).Path
        }
        if (-not [System.IO.Path]::IsPathRooted($candidate)) {
            $candidate = Join-Path (Get-Location).Path $candidate
        }
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
        Write-Host "Folder not found: $candidate" -ForegroundColor Yellow
    }
}

function Read-NonEmptyPrompt {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$Example
    )
    $attempt = 0
    while ($attempt -lt 10) {
        $attempt++
        Write-Host ''
        Write-Host $Prompt
        Write-Host ('  {0}' -f $Example)
        $answer = [string](Read-Host 'Enter a value')
        if (-not [string]::IsNullOrWhiteSpace($answer)) {
            return $answer.Trim()
        }
        Write-Host 'Please enter a non-empty value.' -ForegroundColor Yellow
    }
    throw 'No valid value was entered.'
}

function Read-ReasoningEffortPrompt {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$DefaultEffort
    )
    $defaultIndex = [array]::IndexOf($ReasoningEffortValues, $DefaultEffort)
    if ($defaultIndex -lt 0) {
        throw "The default reasoning effort '$DefaultEffort' is not in the valid effort list."
    }
    $choiceIndex = Read-MenuChoiceIndex -Prompt $Prompt -OptionLabels $ReasoningEffortValues -DefaultIndex $defaultIndex
    return $ReasoningEffortValues[$choiceIndex]
}

function Read-ReviewerSettings {
    $settings = @{ OwlModel = ''; OwlEffort = ''; CatModel = ''; CatEffort = '' }
    $settings.OwlModel = Read-NonEmptyPrompt -Prompt 'Which model should Owl run on? Type any distinctive part of a model name.' -Example 'for example: GLM-5.3'
    $settings.OwlEffort = Read-ReasoningEffortPrompt -Prompt 'Which reasoning effort should Owl use?' -DefaultEffort $DefaultOwlReasoningEffort
    $settings.CatModel = Read-NonEmptyPrompt -Prompt 'Which model should Cat run on? Type any distinctive part of a model name.' -Example 'for example: flash'
    $settings.CatEffort = Read-ReasoningEffortPrompt -Prompt 'Which reasoning effort should Cat use?' -DefaultEffort $DefaultCatReasoningEffort
    return $settings
}

function Read-TempReportsExcludeChoice {
    $excludesFile = Get-GitGlobalExcludesFile
    # Without a resolvable excludes file there is nothing to consent to, and
    # planning warns with the reason.
    if ($excludesFile.SkipReason) {
        return 'Auto'
    }
    $prompt = 'Add {0} to your global git excludes file ({1}) so the agents'' review reports stay out of commits?' -f $TempReportsExcludePattern, $excludesFile.Path
    $choiceIndex = Read-MenuChoiceIndex $prompt @(
        'yes, add the entry (default)',
        'no, leave the git excludes file alone') 0
    if ($choiceIndex -eq 1) {
        return 'Skip'
    }
    return 'Auto'
}

function Read-ComponentMenu {
    $optionLabels = @(
        'all (agents, skills, and hooks)',
        'agents (4 custom agent profiles)',
        'skills (5 squad skills)',
        'hooks (2 guard hook configs and their companion scripts)')
    $optionValues = 'all', 'agents', 'skills', 'hooks'
    Write-Host ''
    Write-Host 'Which components? Enter one number, several numbers separated by commas (for example 2,3), or press Enter for [1].'
    for ($i = 0; $i -lt $optionLabels.Count; $i++) {
        Write-Host ('  [{0}] {1}' -f ($i + 1), $optionLabels[$i])
    }
    $attempt = 0
    while ($attempt -lt 10) {
        $attempt++
        $answer = Read-Host 'Enter component numbers'
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return 'all'
        }
        $numbers = @()
        $answerIsValid = $true
        foreach ($part in ($answer -split ',')) {
            $part = $part.Trim()
            if ($part -eq '') {
                continue
            }
            # The digit cap keeps the [int] cast below overflow for any length
            # of input; five digits is far above any component list size.
            if ($part -notmatch '^\d{1,5}$') {
                $answerIsValid = $false
                break
            }
            $number = [int]$part
            if ($number -lt 1 -or $number -gt $optionLabels.Count) {
                $answerIsValid = $false
                break
            }
            if ($numbers -notcontains $number) {
                $numbers += $number
            }
        }
        if ($answerIsValid -and $numbers.Count -eq 0) {
            $answerIsValid = $false
        }
        if ($answerIsValid) {
            $tokens = @()
            foreach ($number in $numbers) {
                $tokens += $optionValues[$number - 1]
            }
            if ($tokens -contains 'all' -and $tokens.Count -gt 1) {
                Write-Host 'All cannot be combined with named components. Enter [1] alone, or one or more of 2-4.' -ForegroundColor Yellow
                continue
            }
            return $tokens
        }
        Write-Host 'Please enter numbers from the list, separated by commas.' -ForegroundColor Yellow
    }
    throw 'No valid selection was entered.'
}

function Show-Menu {
    $actionValues = 'install', 'uninstall'
    $levelValues = 'user', 'repo'

    $actionIndex = Read-MenuChoiceIndex 'What should this script do?' @('install the squad', 'uninstall the squad') 0
    $componentSelection = Read-ComponentMenu
    $levelIndex = Read-MenuChoiceIndex 'Which level?' @(
        'user level (~/.copilot on this machine)',
        'repo level (one project''s .github folder)') 0

    $projectPath = ''
    if ($levelValues[$levelIndex] -eq 'repo') {
        $projectPath = Read-ProjectPathPrompt
    }

    $reviewerSettings = @{ OwlModel = ''; OwlEffort = ''; CatModel = ''; CatEffort = '' }
    $subagentGuard = 'Auto'
    $tempReportsExclude = 'Auto'
    if ($actionValues[$actionIndex] -eq 'install') {
        $selectedTokens = @($componentSelection)
        if (($selectedTokens -contains 'agents') -or ($selectedTokens -contains 'all')) {
            $reviewerSettings = Read-ReviewerSettings
            $tempReportsExclude = Read-TempReportsExcludeChoice
        }
        elseif ($selectedTokens -contains 'hooks') {
            $guardIndex = Read-MenuChoiceIndex 'Include the subagent delegation guard hook with the shell guard?' @(
                'no, install the shell guard only (default)',
                'yes, also enforce reviewer model and reasoning effort fields') 0
            if ($guardIndex -eq 1) {
                $subagentGuard = 'Force'
                $reviewerSettings = Read-ReviewerSettings
            }
        }
    }

    return @{
        Action = $actionValues[$actionIndex]
        Components = $componentSelection
        Level = $levelValues[$levelIndex]
        ProjectPath = $projectPath
        ReviewerSettings = $reviewerSettings
        SubagentGuard = $subagentGuard
        TempReportsExclude = $tempReportsExclude
    }
}

function Get-ComponentSelection {
    param([string[]]$RequestedComponents)
    $selected = @()
    foreach ($requestedComponent in $RequestedComponents) {
        foreach ($part in ($requestedComponent -split ',')) {
            $token = $part.Trim().ToLowerInvariant()
            if ($token -eq '') {
                continue
            }
            if ($selected -notcontains $token) {
                $selected += $token
            }
        }
    }
    if ($selected.Count -eq 0) {
        throw 'Pass at least one component: all, agents, skills, or hooks.'
    }
    foreach ($token in $selected) {
        if ('agents', 'skills', 'hooks', 'all' -notcontains $token) {
            throw "Unknown component '$token' in -Components. Use all, agents, skills, or hooks."
        }
    }
    if ($selected -contains 'all') {
        if ($selected.Count -gt 1) {
            throw '-Components all cannot be combined with named components.'
        }
        return 'all'
    }
    return $selected
}

function Confirm-ParameterCombo {
    if ($Level -eq 'user' -and -not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
        throw '-ProjectRoot applies only to -Level repo.'
    }
    if ($Level -eq 'repo' -and -not [string]::IsNullOrWhiteSpace($UserRoot)) {
        throw '-UserRoot applies only to -Level user.'
    }
    if ($Level -eq 'repo' -and [string]::IsNullOrWhiteSpace($ProjectRoot)) {
        throw "A repo-level $Action requires -ProjectRoot. Run the script without flags for a guided menu."
    }
}

# A guard install needs the reviewer values because the installed script
# embeds them. Uninstall plans include the guard whenever agents or hooks
# are selected so the same files are removed.
function Test-GuardHookIncluded {
    param(
        [Parameter(Mandatory)][string]$ActionValue,
        [Parameter(Mandatory)][string[]]$ComponentsValue,
        [Parameter(Mandatory)][string]$SubagentGuardMode
    )
    $componentSelection = $ComponentsValue
    if (@($ComponentsValue) -contains 'all') {
        $componentSelection = 'agents', 'skills', 'hooks'
    }
    if ($ActionValue -eq 'install') {
        return ($SubagentGuardMode -eq 'Force') -or
            (($SubagentGuardMode -eq 'Auto') -and (@($componentSelection) -contains 'agents'))
    }
    return (@($componentSelection) -contains 'agents') -or (@($componentSelection) -contains 'hooks')
}

# The model values are embedded into single-quoted PowerShell literals in
# the installed guard script, so reject characters that would terminate the
# literal or split it across lines, and reject placeholder-shaped values
# that would look unfilled.
function Confirm-ReviewerModelValue {
    param(
        [Parameter(Mandatory)][string]$FieldLabel,
        [Parameter(Mandatory)][string]$Value
    )
    if ($Value.IndexOf("'") -ge 0 -or
        $Value.IndexOf("`r") -ge 0 -or
        $Value.IndexOf("`n") -ge 0 -or
        $Value -match '^__.*__$') {
        throw "The $FieldLabel value cannot contain a single quote, a carriage return, or a line feed, and cannot be a placeholder. Enter a model id or a distinctive part of a model name."
    }
}

# Returns the four reviewer values the agents templates and the delegation
# guard need, or four empty strings when neither is installed. Callers only
# print or embed the values when they are present.
function Get-ReviewerSettings {
    param(
        [Parameter(Mandatory)][bool]$InstallingAgents,
        [Parameter(Mandatory)][bool]$GuardHookIncluded,
        [Parameter(Mandatory)][bool]$FromMenu
    )
    if (-not $InstallingAgents -and -not $GuardHookIncluded) {
        if (-not [string]::IsNullOrWhiteSpace($OwlModel) -or
            -not [string]::IsNullOrWhiteSpace($OwlReasoningEffort) -or
            -not [string]::IsNullOrWhiteSpace($CatModel) -or
            -not [string]::IsNullOrWhiteSpace($CatReasoningEffort)) {
            throw '-OwlModel, -OwlReasoningEffort, -CatModel, and -CatReasoningEffort apply only when installing the agents component or the subagent delegation guard.'
        }
        return @{ OwlModel = ''; OwlEffort = ''; CatModel = ''; CatEffort = '' }
    }
    if (-not $FromMenu) {
        foreach ($value in $OwlModel, $OwlReasoningEffort, $CatModel, $CatReasoningEffort) {
            if ([string]::IsNullOrWhiteSpace($value)) {
                throw 'A scripted install that includes the agents component or the subagent delegation guard requires -OwlModel, -OwlReasoningEffort, -CatModel, and -CatReasoningEffort. Run the script without flags for a guided menu.'
            }
        }
    }
    $settings = @{
        OwlModel = $OwlModel.Trim()
        OwlEffort = $OwlReasoningEffort.Trim().ToLowerInvariant()
        CatModel = $CatModel.Trim()
        CatEffort = $CatReasoningEffort.Trim().ToLowerInvariant()
    }
    Confirm-ReviewerModelValue -FieldLabel 'Owl model' -Value $settings.OwlModel
    Confirm-ReviewerModelValue -FieldLabel 'Cat model' -Value $settings.CatModel
    return $settings
}

function Get-TargetFolders {
    param(
        [Parameter(Mandatory)][string]$TargetLevel,
        [string]$ProjectPath
    )
    if ($TargetLevel -eq 'user') {
        $targetRoot = $UserRoot
        if ([string]::IsNullOrWhiteSpace($targetRoot)) {
            $targetRoot = Join-Path $HOME '.copilot'
        }
        return @{
            TargetRoot = $targetRoot
            Agents = Join-Path $targetRoot 'agents'
            Skills = Join-Path $targetRoot 'skills'
            Hooks = Join-Path $targetRoot 'hooks'
            Scripts = Join-Path $targetRoot 'scripts'
        }
    }

    $project = [System.IO.Path]::GetFullPath($ProjectPath)
    if (-not (Test-Path -LiteralPath $project -PathType Container)) {
        throw "Project folder not found: $project"
    }
    if ($project.TrimEnd('\', '/').ToLowerInvariant() -eq $RepoRoot.TrimEnd('\', '/').ToLowerInvariant()) {
        Write-Warning 'The selected project is the squad repo itself, which would create duplicate agent, skill, and hook sources. A different project folder is safer.'
    }
    $githubRoot = Join-Path $project '.github'
    return @{
        TargetRoot = $githubRoot
        Agents = Join-Path $githubRoot 'agents'
        Skills = Join-Path $githubRoot 'skills'
        Hooks = Join-Path $githubRoot 'hooks'
        Scripts = Join-Path $githubRoot 'scripts'
    }
}

function Get-RelativePathBelow {
    param(
        [Parameter(Mandatory)][string]$FullPath,
        [Parameter(Mandatory)][string]$BasePath
    )
    $base = [System.IO.Path]::GetFullPath($BasePath)
    if (-not $base.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $base += [System.IO.Path]::DirectorySeparatorChar
    }
    $full = [System.IO.Path]::GetFullPath($FullPath)
    if (-not $full.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Source file is not under the expected folder: $FullPath"
    }
    return $full.Substring($base.Length)
}

function Get-SourceFiles {
    param([Parameter(Mandatory)][string]$SourceFolder)
    if (-not (Test-Path -LiteralPath $SourceFolder -PathType Container)) {
        throw "Source folder missing in the squad repo: $SourceFolder"
    }
    return @(Get-ChildItem -LiteralPath $SourceFolder -Recurse -File)
}

# Rewrites a shipped template's placeholders, and throws when a placeholder is
# missing or survives. Callers resolve rewrites while planning their
# operations, so a broken template aborts the whole run before any file is
# written.
function ConvertTo-RewrittenTemplate {
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][hashtable]$Replacements,
        [string[]]$ForbiddenAfterRewrite = @()
    )
    if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
        throw "Source file missing in the squad repo: $TemplatePath"
    }
    # ReadAllText instead of Get-Content: Windows PowerShell 5.1 decodes a
    # BOM-less file in the system ANSI codepage, while .NET defaults to UTF-8.
    $raw = [System.IO.File]::ReadAllText($TemplatePath)
    foreach ($placeholder in $Replacements.Keys) {
        if (-not $raw.Contains($placeholder)) {
            throw "The template $TemplatePath does not contain the expected placeholder '$placeholder'. Restore the shipped template, then re-run."
        }
        if ([string]::IsNullOrWhiteSpace([string]$Replacements[$placeholder])) {
            throw "The replacement for '$placeholder' is empty in $TemplatePath, which would leave a broken instruction."
        }
    }
    # The hook's repo path contains the user path, so rewrite longest first to
    # keep a shorter placeholder from eating the text of a longer one.
    $rewritten = $raw
    foreach ($placeholder in @($Replacements.Keys | Sort-Object { $_.Length } -Descending)) {
        $rewritten = $rewritten.Replace($placeholder, [string]$Replacements[$placeholder])
    }
    $checkedPlaceholders = @($Replacements.Keys) + $ForbiddenAfterRewrite
    foreach ($remainingPlaceholder in $checkedPlaceholders) {
        if ($rewritten.Contains($remainingPlaceholder)) {
            throw "The placeholder '$remainingPlaceholder' is still present after rewriting $TemplatePath."
        }
    }
    return $rewritten
}

function Get-RewrittenHookJson {
    param(
        [Parameter(Mandatory)][string]$TargetLevel,
        [Parameter(Mandatory)][string]$HookJsonFileName
    )
    $sourceJsonPath = Join-Path (Join-Path $RepoRoot 'hooks') $HookJsonFileName
    $homePath = ($HOME -replace '\\', '/').TrimEnd('/')
    $repoPathSuffix = $HookRepoPlaceholder.Substring($HookUserPlaceholder.Length)
    if ($TargetLevel -eq 'user') {
        $rewritten = ConvertTo-RewrittenTemplate -TemplatePath $sourceJsonPath -Replacements @{
            $HookUserPlaceholder = $homePath
            $HookRepoPlaceholder = ($homePath + $repoPathSuffix)
        }
    }
    else {
        # Repo level keeps no profile path at all, so a user path outside the
        # repo placeholder aborts instead of being rewritten.
        $rewritten = ConvertTo-RewrittenTemplate -TemplatePath $sourceJsonPath -Replacements @{
            $HookRepoPlaceholder = '.github/scripts'
        } -ForbiddenAfterRewrite @($HookUserPlaceholder)
    }
    $null = $rewritten | ConvertFrom-Json
    return $rewritten
}

function Get-RewrittenAgentFile {
    param(
        [Parameter(Mandatory)][string]$AgentFilePath,
        [Parameter(Mandatory)][string]$AgentFileName,
        [Parameter(Mandatory)][hashtable]$Settings
    )
    $replacements = @{
        $OwlModelPlaceholder = $Settings.OwlModel
        $OwlEffortPlaceholder = $Settings.OwlEffort
    }
    if ($AgentFileName -eq $CapybaraDuoFile) {
        # Cat values have no meaning in Duo mode, so a Cat token that leaks
        # into the template is forbidden, not filled.
        return ConvertTo-RewrittenTemplate -TemplatePath $AgentFilePath -Replacements $replacements -ForbiddenAfterRewrite @($CatModelPlaceholder, $CatEffortPlaceholder)
    }
    $replacements[$CatModelPlaceholder] = $Settings.CatModel
    $replacements[$CatEffortPlaceholder] = $Settings.CatEffort
    return ConvertTo-RewrittenTemplate -TemplatePath $AgentFilePath -Replacements $replacements
}

# Returns the install or uninstall operations for one hook: its rewritten
# (install) or target-mapped (uninstall) JSON plus the verbatim copy of its
# companion script folder, with the folder to prune.
function Get-HookOperationOps {
    param(
        [Parameter(Mandatory)][string]$HookName,
        [Parameter(Mandatory)][hashtable]$Targets,
        [Parameter(Mandatory)][string]$TargetLevel,
        [Parameter(Mandatory)][string]$ActionValue,
        [Parameter(Mandatory)][hashtable]$ReviewerSettings
    )
    $hookJsonName = $HookName + '.json'
    $hookJsonSource = Join-Path (Join-Path $RepoRoot 'hooks') $hookJsonName
    $hookJsonOp = @{
        Component = 'hooks'
        Source = $hookJsonSource
        Target = Join-Path $Targets.Hooks $hookJsonName
        Display = Join-Path 'hooks' $hookJsonName
        RewrittenContent = $null
    }
    if ($ActionValue -eq 'install') {
        if (-not (Test-Path -LiteralPath $hookJsonSource -PathType Leaf)) {
            throw "Source file missing in the squad repo: $hookJsonSource"
        }
        $hookJsonOp.RewrittenContent = Get-RewrittenHookJson -TargetLevel $TargetLevel -HookJsonFileName $hookJsonName
    }
    $hookOps = @($hookJsonOp)
    $scriptSourceRoot = Join-Path (Join-Path $RepoRoot 'scripts') $HookName
    $scriptTargetRoot = Join-Path $Targets.Scripts $HookName
    foreach ($sourceFile in Get-SourceFiles -SourceFolder $scriptSourceRoot) {
        $relativePath = Get-RelativePathBelow -FullPath $sourceFile.FullName -BasePath $scriptSourceRoot
        # Only the guard itself embeds the reviewer values. The battery beside
        # it stays verbatim because it reads the constants from the script.
        $rewrittenContent = $null
        if ($ActionValue -eq 'install' -and
            $HookName -eq $HookSubagentGuardName -and
            $relativePath -eq ($HookName + '.ps1')) {
            $rewrittenContent = ConvertTo-RewrittenTemplate -TemplatePath $sourceFile.FullName -Replacements @{
                $OwlModelPlaceholder = $ReviewerSettings.OwlModel
                $OwlEffortPlaceholder = $ReviewerSettings.OwlEffort
                $CatModelPlaceholder = $ReviewerSettings.CatModel
                $CatEffortPlaceholder = $ReviewerSettings.CatEffort
            }
        }
        $hookOps += @{
            Component = 'hooks'
            Source = $sourceFile.FullName
            Target = Join-Path $scriptTargetRoot $relativePath
            Display = Join-Path (Join-Path 'scripts' $HookName) $relativePath
            RewrittenContent = $rewrittenContent
        }
    }
    return @{ Ops = $hookOps; Folder = $scriptTargetRoot }
}

function Get-InstallOperationPlan {
    param(
        [Parameter(Mandatory)][string]$ActionValue,
        [string[]]$ComponentsValue = @('all'),
        [Parameter(Mandatory)][hashtable]$Targets,
        [Parameter(Mandatory)][string]$TargetLevel,
        [Parameter(Mandatory)][hashtable]$ReviewerSettings,
        [string]$SubagentGuardMode = 'Auto'
    )
    $componentSelection = 'agents', 'skills', 'hooks'
    if (@($ComponentsValue) -notcontains 'all') {
        $componentSelection = $ComponentsValue
    }

    $includeGuardHook = Test-GuardHookIncluded -ActionValue $ActionValue -ComponentsValue $componentSelection -SubagentGuardMode $SubagentGuardMode
    $plannedHookNames = @($HookNames | Where-Object { $_ -ne $HookSubagentGuardName -or $includeGuardHook })

    # Only the selected components are planned, so a partial clone can install
    # or remove one component without the other components' sources in place.
    $fileOps = @()
    $folderPrunes = @()

    foreach ($component in $componentSelection) {
        if ($component -eq 'agents') {
            foreach ($agentFileName in $AgentFiles) {
                $agentOp = @{
                    Component = 'agents'
                    Source = Join-Path (Join-Path $RepoRoot 'agents') $agentFileName
                    Target = Join-Path $Targets.Agents $agentFileName
                    Display = Join-Path 'agents' $agentFileName
                    RewrittenContent = $null
                }
                if ($ActionValue -eq 'install' -and $AgentFilesWithPlaceholders -contains $agentFileName) {
                    $agentOp.RewrittenContent = Get-RewrittenAgentFile -AgentFilePath $agentOp.Source -AgentFileName $agentFileName -Settings $ReviewerSettings
                }
                $fileOps += $agentOp
            }
        }
        elseif ($component -eq 'skills') {
            foreach ($skillFolder in $SkillFolders) {
                $sourceSkillRoot = Join-Path (Join-Path $RepoRoot 'skills') $skillFolder
                $targetSkillRoot = Join-Path $Targets.Skills $skillFolder
                foreach ($sourceFile in Get-SourceFiles -SourceFolder $sourceSkillRoot) {
                    $relativePath = Get-RelativePathBelow -FullPath $sourceFile.FullName -BasePath $sourceSkillRoot
                    $fileOps += @{
                        Component = 'skills'
                        Source = $sourceFile.FullName
                        Target = Join-Path $targetSkillRoot $relativePath
                        Display = Join-Path (Join-Path 'skills' $skillFolder) $relativePath
                        RewrittenContent = $null
                    }
                }
                $folderPrunes += @{ Component = 'skills'; Folder = $targetSkillRoot }
            }
        }
        elseif ($component -eq 'hooks') {
            foreach ($hookName in $plannedHookNames) {
                $hookPlan = Get-HookOperationOps -HookName $hookName -Targets $Targets -TargetLevel $TargetLevel -ActionValue $ActionValue -ReviewerSettings $ReviewerSettings
                $fileOps += $hookPlan.Ops
                $folderPrunes += @{ Component = 'hooks'; Folder = $hookPlan.Folder }
            }
        }
    }

    # The guard also travels with any install or uninstall whose selection
    # does not include the hooks component, where the hooks branch above
    # never executes, so the summary's claim stays true and those uninstalls
    # still remove the guard.
    if ($includeGuardHook -and (@($componentSelection) -notcontains 'hooks')) {
        $guardPlan = Get-HookOperationOps -HookName $HookSubagentGuardName -Targets $Targets -TargetLevel $TargetLevel -ActionValue $ActionValue -ReviewerSettings $ReviewerSettings
        $fileOps += $guardPlan.Ops
        $folderPrunes += @{ Component = 'hooks'; Folder = $guardPlan.Folder }
    }

    # Only install runs assert source files exist; uninstall removes the
    # mapped targets without per-file source checks.
    foreach ($fileOp in $fileOps) {
        if ($ActionValue -eq 'install' -and -not $fileOp.RewrittenContent -and -not (Test-Path -LiteralPath $fileOp.Source -PathType Leaf)) {
            throw "Source file missing in the squad repo: $($fileOp.Source)"
        }
    }

    # A selected component with no planned operations means its sources are
    # an empty folder in the squad repo; say so instead of exiting silently.
    foreach ($component in $componentSelection) {
        if (@($fileOps | Where-Object { $_.Component -eq $component }).Count -eq 0) {
            Write-Warning "Component '$component' planned no operations because its source folder in the squad repo is empty."
        }
    }

    # The leftover scan only sees top-level entries of the target folders, so
    # these exclusions cover the full map without reading any source file.
    # The hook entries stay unconditional: a partial uninstall must not
    # report intact hook files as leftovers just because its own selection
    # did not plan them.
    $squadPaths = @()
    foreach ($agentFileName in $AgentFiles) {
        $squadPaths += (Join-Path $Targets.Agents $agentFileName)
    }
    foreach ($hookName in $HookNames) {
        $squadPaths += (Join-Path $Targets.Hooks ($hookName + '.json'))
    }
    $squadFolders = @()
    foreach ($skillFolder in $SkillFolders) {
        $squadFolders += (Join-Path $Targets.Skills $skillFolder)
    }
    foreach ($hookName in $HookNames) {
        $squadFolders += (Join-Path $Targets.Scripts $hookName)
    }

    return @{
        FileOps = $fileOps
        FolderPrunes = $folderPrunes
        SquadPaths = $squadPaths
        SquadFolders = $squadFolders
        GuardHookIncluded = $includeGuardHook
    }
}

function Invoke-InstallPlan {
    param([hashtable[]]$FileOps = @())
    $copiedCount = 0
    $overwrittenCount = 0
    foreach ($fileOp in $FileOps) {
        $targetDirectory = Split-Path -Parent $fileOp.Target
        if (-not (Test-Path -LiteralPath $targetDirectory -PathType Container)) {
            New-Item -Path $targetDirectory -ItemType Directory -Force | Out-Null
        }
        $existed = Test-Path -LiteralPath $fileOp.Target -PathType Leaf
        if ($fileOp.RewrittenContent) {
            if ($WhatIfPreference) {
                Write-Host ('What if: writing rewritten content to {0}' -f $fileOp.Target)
            }
            else {
                # WriteAllText writes UTF-8 without a BOM. Some JSON readers
                # reject a BOM, and the shipped templates are BOM-less.
                [System.IO.File]::WriteAllText($fileOp.Target, $fileOp.RewrittenContent)
            }
        }
        else {
            Copy-Item -LiteralPath $fileOp.Source -Destination $fileOp.Target -Force
        }
        $status = 'copied'
        $statusColor = 'Green'
        if ($existed) {
            $status = 'overwritten'
            $statusColor = 'Yellow'
            $overwrittenCount++
        }
        else {
            $copiedCount++
        }
        if ($WhatIfPreference) {
            $status = "planned ($status)"
        }
        Write-Host ('  {0,-70} {1}' -f $fileOp.Display, $status) -ForegroundColor $statusColor
    }
    return @{ Copied = $copiedCount; Overwritten = $overwrittenCount }
}

function Invoke-UninstallPlan {
    param(
        [hashtable[]]$FileOps = @(),
        [hashtable[]]$FolderPrunes = @(),
        [Parameter(Mandatory)][hashtable]$Targets,
        [Parameter(Mandatory)][string[]]$SquadPaths,
        [Parameter(Mandatory)][string[]]$SquadFolders
    )
    $removedCount = 0
    $absentCount = 0
    foreach ($fileOp in $FileOps) {
        if (Test-Path -LiteralPath $fileOp.Target) {
            Remove-Item -LiteralPath $fileOp.Target -Force
            $removedCount++
            $statusLabel = 'removed'
            $statusColor = 'Green'
        }
        else {
            $absentCount++
            $statusLabel = 'absent'
            $statusColor = 'DarkGray'
        }
        if ($WhatIfPreference) {
            $statusLabel = "planned ($statusLabel)"
        }
        Write-Host ('  {0,-70} {1}' -f $fileOp.Display, $statusLabel) -ForegroundColor $statusColor
    }

    foreach ($folderPrune in $FolderPrunes) {
        if (Test-Path -LiteralPath $folderPrune.Folder -PathType Container) {
            $remainingFiles = @(Get-ChildItem -LiteralPath $folderPrune.Folder -Recurse -File)
            if ($remainingFiles.Count -eq 0) {
                Remove-Item -LiteralPath $folderPrune.Folder -Recurse -Force
                Write-Host ('  {0}  removed (empty folder)' -f $folderPrune.Folder) -ForegroundColor Green
            }
        }
    }

    # A leftover matches a squad name but is not a file or folder the squad's
    # full map would have placed, such as a manually renamed .disabled copy.
    $leftovers = @()
    foreach ($scanFolder in @($Targets.Agents, $Targets.Skills, $Targets.Hooks, $Targets.Scripts)) {
        if (-not (Test-Path -LiteralPath $scanFolder -PathType Container)) {
            continue
        }
        foreach ($entry in (Get-ChildItem -LiteralPath $scanFolder -Force)) {
            if ($entry.Name -match $LeftoverPattern -and
                -not ($SquadPaths -contains $entry.FullName) -and
                -not ($SquadFolders -contains $entry.FullName)) {
                $leftovers += $entry.FullName
            }
        }
    }
    if ($leftovers.Count -gt 0) {
        Write-Host '  Entries matching squad names that were left in place (review and remove manually):' -ForegroundColor Yellow
        foreach ($leftover in $leftovers) {
            Write-Host ('    {0}' -f $leftover) -ForegroundColor Yellow
        }
    }
    return @{ Removed = $removedCount; Absent = $absentCount; Leftovers = $leftovers }
}

# Runs a git query and returns its exit code and first output line. Output is
# decoded as UTF-8, which git writes, because PowerShell decodes native output
# with the console code page and would garble a non-ASCII path such as a
# profile folder name. Stderr is left to the console, so git's own message
# accompanies the installer's warning. The callers pass fixed tokens without
# spaces or quotes, so joining them needs no quoting.
function Invoke-GitQuery {
    param(
        [Parameter(Mandatory)][string]$GitPath,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $GitPath
    $startInfo.Arguments = $Arguments -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $standardOutput = $process.StandardOutput.ReadToEnd()
        $process.WaitForExit()
        return @{ ExitCode = $process.ExitCode; FirstLine = ($standardOutput -split "`r?`n")[0] }
    }
    finally {
        $process.Dispose()
    }
}

# Returns the global excludes file git reads as @{ Path; SkipReason }, with
# exactly one of the two set, so callers skip instead of writing a file git
# would never read. Only the global scope is consulted, so a core.excludesFile
# set solely in system config is not seen.
function Get-GitGlobalExcludesFile {
    $gitCommand = Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $gitCommand) {
        return @{ Path = ''; SkipReason = 'git was not found on PATH' }
    }
    # A scoped read skips include.path files unless asked, and dotfile setups
    # often keep core.excludesFile in an included file.
    $configuredQuery = Invoke-GitQuery -GitPath $gitCommand.Path -Arguments @('config', '--global', '--includes', '--type=path', '--get', 'core.excludesFile')
    if ($configuredQuery.ExitCode -ne 0 -and $configuredQuery.ExitCode -ne 1) {
        return @{ Path = ''; SkipReason = "git could not read its config (exit code $($configuredQuery.ExitCode))" }
    }
    if ($configuredQuery.ExitCode -eq 0) {
        $configuredPath = $configuredQuery.FirstLine
        if ([string]::IsNullOrWhiteSpace($configuredPath)) {
            return @{ Path = ''; SkipReason = 'core.excludesFile is empty, so git reads no global excludes file' }
        }
        if (-not [System.IO.Path]::IsPathRooted($configuredPath)) {
            return @{ Path = ''; SkipReason = "core.excludesFile is the relative path '$configuredPath', which git resolves against each repository" }
        }
        return @{ Path = [System.IO.Path]::GetFullPath($configuredPath); SkipReason = '' }
    }
    if (-not [string]::IsNullOrEmpty($env:XDG_CONFIG_HOME)) {
        return @{ Path = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $env:XDG_CONFIG_HOME 'git') 'ignore')); SkipReason = '' }
    }
    # git expands ~ with its own home lookup, which on Windows falls back from
    # HOME to HOMEDRIVE plus HOMEPATH, and then to USERPROFILE, so asking git
    # yields the exact default path git reads.
    $homeDefaultQuery = Invoke-GitQuery -GitPath $gitCommand.Path -Arguments @('-c', 'squad.excludesprobe=~/.config/git/ignore', 'config', '--type=path', '--get', 'squad.excludesprobe')
    if ($homeDefaultQuery.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($homeDefaultQuery.FirstLine)) {
        return @{ Path = ''; SkipReason = 'git could not resolve its home folder' }
    }
    return @{ Path = [System.IO.Path]::GetFullPath($homeDefaultQuery.FirstLine); SkipReason = '' }
}

function Read-ExcludesFileContent {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }
    return [System.IO.File]::ReadAllText($Path)
}

function Test-TempReportsEntryPresent {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    # git keeps leading spaces as part of a pattern and drops only trailing
    # ones, so only trailing spaces are trimmed before matching.
    foreach ($line in ($Content -split "`r?`n")) {
        if ($line.TrimEnd(' ') -match $TempReportsEquivalentPatternRegex) {
            return $true
        }
    }
    return $false
}

function Get-ExcludesContentWithEntry {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    $newline = "`n"
    if ($Content.Contains("`r`n")) {
        $newline = "`r`n"
    }
    $separator = ''
    if ($Content.Length -gt 0 -and -not $Content.EndsWith("`n")) {
        $separator = $newline
    }
    return $Content + $separator + $TempReportsExcludeMarker + $newline + $TempReportsExcludePattern + $newline
}

# Only the marker line directly followed by the installer's pattern counts as
# the installer's entry, so a user's own equivalent line always survives.
function Get-ExcludesContentWithoutEntry {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    $markedEntryRegex = '(?m)^' + [regex]::Escape($TempReportsExcludeMarker) + '\r?\n' + [regex]::Escape($TempReportsExcludePattern) + '(\r?\n|\z)'
    return [regex]::Replace($Content, $markedEntryRegex, '')
}

function New-SkippedExcludePlan {
    param([Parameter(Mandatory)][string]$Reason)
    Write-Warning ('The temp reports entry in the global git excludes file was skipped: {0}.' -f $Reason)
    return @{ State = 'Skipped'; Path = ''; SkipReason = $Reason }
}

# Decides the excludes file change while planning, so its summary and any
# skip warning appear before the Proceed prompt, and a folder path or a
# read-only file is skipped before any squad file is copied.
function Get-TempReportsExcludePlan {
    param(
        [Parameter(Mandatory)][string]$ActionValue,
        [Parameter(Mandatory)][bool]$AgentsSelected,
        [Parameter(Mandatory)][string]$Mode
    )
    if (-not $AgentsSelected) {
        return @{ State = 'NotApplicable'; Path = ''; SkipReason = '' }
    }
    if ($Mode -eq 'Skip') {
        return @{ State = 'Skipped'; Path = ''; SkipReason = 'opted out' }
    }
    $excludesFile = Get-GitGlobalExcludesFile
    if ($excludesFile.SkipReason) {
        return New-SkippedExcludePlan -Reason $excludesFile.SkipReason
    }
    if (Test-Path -LiteralPath $excludesFile.Path -PathType Container) {
        return New-SkippedExcludePlan -Reason "the excludes path $($excludesFile.Path) is a folder"
    }
    $content = Read-ExcludesFileContent -Path $excludesFile.Path
    if ($ActionValue -eq 'install') {
        $state = 'Add'
        if (Test-TempReportsEntryPresent -Content $content) {
            $state = 'Present'
        }
    }
    else {
        $state = 'Absent'
        if ((Get-ExcludesContentWithoutEntry -Content $content) -cne $content) {
            $state = 'Remove'
        }
    }
    $needsWrite = ('Add', 'Remove') -contains $state
    if ($needsWrite -and (Test-Path -LiteralPath $excludesFile.Path -PathType Leaf) -and (Get-Item -LiteralPath $excludesFile.Path -Force).IsReadOnly) {
        return New-SkippedExcludePlan -Reason "the excludes file $($excludesFile.Path) is read-only"
    }
    return @{ State = $state; Path = $excludesFile.Path; SkipReason = '' }
}

function Get-TempReportsExcludeSummary {
    param([Parameter(Mandatory)][hashtable]$ExcludePlan)
    switch ($ExcludePlan.State) {
        'Add' { return ('will add {0} to {1}' -f $TempReportsExcludePattern, $ExcludePlan.Path) }
        'Present' { return ('already covered in {0}' -f $ExcludePlan.Path) }
        'Remove' { return ('will remove the installer''s entry from {0}' -f $ExcludePlan.Path) }
        'Absent' { return ('no installer entry in {0}' -f $ExcludePlan.Path) }
        'Skipped' { return ('skipped ({0})' -f $ExcludePlan.SkipReason) }
    }
    throw "Unknown temp reports exclude state '$($ExcludePlan.State)'."
}

function Invoke-TempReportsExcludePlan {
    param([Parameter(Mandatory)][hashtable]$ExcludePlan)
    if ('Add', 'Remove' -notcontains $ExcludePlan.State) {
        return
    }
    $statusLabel = 'entry added'
    if ($ExcludePlan.State -eq 'Remove') {
        $statusLabel = 'entry removed'
    }
    if ($WhatIfPreference) {
        Write-Host ('  {0,-70} planned ({1})' -f $ExcludePlan.Path, $statusLabel) -ForegroundColor Green
        return
    }
    # Re-read at write time, because a menu run can wait at Proceed while
    # the user or another tool edits the same file.
    $content = Read-ExcludesFileContent -Path $ExcludePlan.Path
    if ($ExcludePlan.State -eq 'Add') {
        $updatedContent = $content
        if (-not (Test-TempReportsEntryPresent -Content $content)) {
            $updatedContent = Get-ExcludesContentWithEntry -Content $content
        }
    }
    else {
        $updatedContent = Get-ExcludesContentWithoutEntry -Content $content
    }
    if ($updatedContent -ceq $content) {
        Write-Host ('  {0,-70} unchanged' -f $ExcludePlan.Path) -ForegroundColor DarkGray
        return
    }
    $excludesFolder = Split-Path -Parent $ExcludePlan.Path
    if (-not (Test-Path -LiteralPath $excludesFolder -PathType Container)) {
        New-Item -Path $excludesFolder -ItemType Directory -Force | Out-Null
    }
    # WriteAllText keeps the user's file in UTF-8, where Set-Content on
    # Windows PowerShell 5.1 would re-encode it in the ANSI codepage.
    [System.IO.File]::WriteAllText($ExcludePlan.Path, $updatedContent)
    Write-Host ('  {0,-70} {1}' -f $ExcludePlan.Path, $statusLabel) -ForegroundColor Green
}

try {
    $useMenu = ($PSBoundParameters.Count -eq 0)
    if ($useMenu) {
        $menuChoices = Show-Menu
        $Action = $menuChoices.Action
        $Components = $menuChoices.Components
        $Level = $menuChoices.Level
        $ProjectRoot = $menuChoices.ProjectPath
        # The effort parameters carry ValidateSet attributes, which also cover
        # assignments to their variables, so an empty menu effort stays
        # unassigned.
        if (-not [string]::IsNullOrWhiteSpace($menuChoices.ReviewerSettings.OwlModel)) {
            $OwlModel = $menuChoices.ReviewerSettings.OwlModel
        }
        if (-not [string]::IsNullOrWhiteSpace($menuChoices.ReviewerSettings.OwlEffort)) {
            $OwlReasoningEffort = $menuChoices.ReviewerSettings.OwlEffort
        }
        if (-not [string]::IsNullOrWhiteSpace($menuChoices.ReviewerSettings.CatModel)) {
            $CatModel = $menuChoices.ReviewerSettings.CatModel
        }
        if (-not [string]::IsNullOrWhiteSpace($menuChoices.ReviewerSettings.CatEffort)) {
            $CatReasoningEffort = $menuChoices.ReviewerSettings.CatEffort
        }
        $SubagentGuard = $menuChoices.SubagentGuard
        $TempReportsExclude = $menuChoices.TempReportsExclude
    }

    Confirm-ParameterCombo
    $Components = Get-ComponentSelection -RequestedComponents @($Components)
    $targets = Get-TargetFolders -TargetLevel $Level -ProjectPath $ProjectRoot
    $selectedTokens = @($Components)
    $agentsSelected = ($selectedTokens -contains 'agents') -or ($selectedTokens -contains 'all')
    $installingAgents = $agentsSelected -and ($Action -eq 'install')
    $installingHooks = (($selectedTokens -contains 'hooks') -or ($selectedTokens -contains 'all')) -and ($Action -eq 'install')
    if ($TempReportsExclude -eq 'Skip' -and -not $agentsSelected) {
        throw '-TempReportsExclude Skip applies only when the agents component is selected.'
    }
    if ($PSBoundParameters.ContainsKey('SubagentGuard') -and $Action -eq 'uninstall' -and $SubagentGuard -ne 'Auto') {
        throw '-SubagentGuard applies only to install runs.'
    }
    if ($Action -eq 'install' -and $SubagentGuard -eq 'Skip' -and -not $installingAgents) {
        throw '-SubagentGuard Skip applies only when installing the agents component.'
    }
    if ($Action -eq 'install' -and $SubagentGuard -eq 'Force' -and -not ($installingAgents -or $installingHooks)) {
        throw '-SubagentGuard Force requires the agents or hooks component.'
    }
    $guardInstallIncluded = ($Action -eq 'install') -and (Test-GuardHookIncluded -ActionValue $Action -ComponentsValue $selectedTokens -SubagentGuardMode $SubagentGuard)
    $reviewerSettings = Get-ReviewerSettings -InstallingAgents $installingAgents -GuardHookIncluded $guardInstallIncluded -FromMenu $useMenu
    $plan = Get-InstallOperationPlan -ActionValue $Action -ComponentsValue $Components -Targets $targets -TargetLevel $Level -ReviewerSettings $reviewerSettings -SubagentGuardMode $SubagentGuard
    $tempReportsExcludePlan = Get-TempReportsExcludePlan -ActionValue $Action -AgentsSelected $agentsSelected -Mode $TempReportsExclude

    Write-Host "Copilot Squad $($Action.ToLowerInvariant())"
    Write-Host "Level: $Level"
    Write-Host "Components: $($Components -join ', ')"
    Write-Host "Target: $($targets.TargetRoot)"
    if ($installingAgents -or ($Action -eq 'install' -and $plan.GuardHookIncluded)) {
        Write-Host ('Owl model: {0} (effort: {1})' -f $reviewerSettings.OwlModel, $reviewerSettings.OwlEffort)
        Write-Host ('Cat model: {0} (effort: {1})' -f $reviewerSettings.CatModel, $reviewerSettings.CatEffort)
    }
    if ($Action -eq 'install') {
        $guardSummary = 'not included'
        if ($plan.GuardHookIncluded) {
            $guardSummary = 'included'
        }
        Write-Host ('Subagent delegation guard: {0}' -f $guardSummary)
    }
    if ($tempReportsExcludePlan.State -ne 'NotApplicable') {
        Write-Host ('Temp reports git exclude: {0}' -f (Get-TempReportsExcludeSummary -ExcludePlan $tempReportsExcludePlan))
    }
    Write-Host ''

    $proceed = $true
    if ($useMenu) {
        Write-Host ('Planned files: {0}' -f $plan.FileOps.Count)
        if ($Action -eq 'install') {
            Write-Host 'Existing files with the same name are overwritten.'
        }
        $proceedIndex = Read-MenuChoiceIndex 'Proceed?' @('Yes, proceed.', 'No, cancel.') 1
        $proceed = ($proceedIndex -eq 0)
    }
    if (-not $proceed) {
        Write-Host 'Cancelled. No changes were made.'
        exit 0
    }
    Write-Host ''

    if ($Action -eq 'install') {
        $summary = Invoke-InstallPlan -FileOps $plan.FileOps
    }
    else {
        $summary = Invoke-UninstallPlan -FileOps $plan.FileOps -FolderPrunes $plan.FolderPrunes -Targets $targets -SquadPaths $plan.SquadPaths -SquadFolders $plan.SquadFolders
    }
    Invoke-TempReportsExcludePlan -ExcludePlan $tempReportsExcludePlan

    if ($WhatIfPreference) {
        Write-Host ''
        Write-Host 'What-if run finished. No changes were made.'
        exit 0
    }

    Write-Host ''
    if ($Action -eq 'install') {
        Write-Host ('Done: {0} copied, {1} overwritten.' -f $summary.Copied, $summary.Overwritten)
    }
    else {
        Write-Host ('Done: {0} removed, {1} absent, {2} leftover(s) reported.' -f $summary.Removed, $summary.Absent, $summary.Leftovers.Count)
    }
    exit 0
}
catch {
    Write-Error $_
    exit 1
}