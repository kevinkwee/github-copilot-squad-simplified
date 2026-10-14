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
    the model or reasoning effort field, and travels per -SubagentGuard: Auto
    installs it with the agents component, Skip leaves it out, and Force
    installs it into any install that includes the agents or hooks
    component, for example a hooks-only install when the agents were copied
    by hand.

    The agents component rewrites the two Capybara templates the same way,
    filling the Owl and Cat placeholder pairs with the values collected by
    the menu, or passed with -OwlModel, -OwlReasoningEffort, -CatModel, and
    -CatReasoningEffort for scripted runs. The Capybara Duo template receives
    only the Owl pair. The model values may be full ids, or a distinctive
    part of the name such as GLM-5.3. The values do not have to match
    exactly, and the installed delegation rule resolves them to the first
    available match at run time.

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
    templates. May be the full id, or a distinctive part of the name, for
    example GLM-5.3. Required on scripted installs that include the agents
    component.

.PARAMETER OwlReasoningEffort
    Reasoning effort copied into __OWL_REASONING_EFFORT__ in the installed
    Capybara templates. Required on scripted installs that include the
    agents component.

.PARAMETER CatModel
    Model value copied into __CAT_MODEL__ in the installed Capybara template.
    May be the full id, or a distinctive part of the name. Required on
    scripted installs that include the agents component.

.PARAMETER CatReasoningEffort
    Reasoning effort copied into __CAT_REASONING_EFFORT__ in the installed
    Capybara template. Required on scripted installs that include the
    agents component.

.PARAMETER SubagentGuard
    How the subagent delegation guard hook travels. Auto (default) installs
    it whenever the agents component is installed. Skip leaves it out and
    fails fast on any install that does not include the agents component.
    Force installs it into any install that includes the agents or hooks
    component, for example a hooks-only install for a hand-maintained
    agents folder, and fails fast when neither is selected. Only install
    runs accept a non-Auto value.

.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File install.ps1

.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Action install -Components agents,skills -Level user -OwlModel 'GLM-5.3' -OwlReasoningEffort high -CatModel 'flash' -CatReasoningEffort low

.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Action install -Components hooks -Level repo -ProjectRoot C:\projects\my-app

.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Action install -Components hooks -Level user -SubagentGuard Force

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

    [string]$OwlReasoningEffort,

    [string]$CatModel,

    [string]$CatReasoningEffort,

    [ValidateSet('Auto', 'Skip', 'Force')]
    [string]$SubagentGuard = 'Auto'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RepoRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$AgentFiles = 'Capybara.agent.md', 'CapybaraDuo.agent.md', 'Cat.agent.md', 'Owl.agent.md'
$SkillFolders = 'agents-md', 'commit-message', 'pr-description'
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
$LeftoverPattern = '^(CapybaraDuo|Capybara|Cat|Owl|guard-pwsh-continuation|guard-subagent-delegation|agents-md|commit-message|pr-description)([._\- ]|$)'

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

function Read-ComponentMenu {
    $optionLabels = @(
        'all (agents, skills, and hooks)',
        'agents (4 custom agent profiles)',
        'skills (3 squad skills)',
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
    if ($actionValues[$actionIndex] -eq 'install') {
        $selectedTokens = @($componentSelection)
        if (($selectedTokens -contains 'agents') -or ($selectedTokens -contains 'all')) {
            $reviewerSettings.OwlModel = Read-NonEmptyPrompt -Prompt 'Which model should Owl run on? Type any distinctive part of a model name.' -Example 'for example: GLM-5.3'
            $reviewerSettings.OwlEffort = Read-NonEmptyPrompt -Prompt 'Which reasoning effort should Owl use?' -Example 'for example: high (common values are low, medium, high)'
            $reviewerSettings.CatModel = Read-NonEmptyPrompt -Prompt 'Which model should Cat run on? Type any distinctive part of a model name.' -Example 'for example: flash'
            $reviewerSettings.CatEffort = Read-NonEmptyPrompt -Prompt 'Which reasoning effort should Cat use?' -Example 'for example: low (common values are low, medium, high)'
        }
        elseif ($selectedTokens -contains 'hooks') {
            $guardIndex = Read-MenuChoiceIndex 'Include the subagent delegation guard hook with the shell guard?' @(
                'no, install the shell guard only (default)',
                'yes, also enforce reviewer model and reasoning effort fields') 0
            if ($guardIndex -eq 1) {
                $subagentGuard = 'Force'
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

function Get-ReviewerSettings {
    param(
        [Parameter(Mandatory)][bool]$InstallingAgents,
        [Parameter(Mandatory)][bool]$FromMenu
    )
    if (-not $InstallingAgents) {
        if (-not [string]::IsNullOrWhiteSpace($OwlModel) -or
            -not [string]::IsNullOrWhiteSpace($OwlReasoningEffort) -or
            -not [string]::IsNullOrWhiteSpace($CatModel) -or
            -not [string]::IsNullOrWhiteSpace($CatReasoningEffort)) {
            throw '-OwlModel, -OwlReasoningEffort, -CatModel, and -CatReasoningEffort apply only when installing the agents component.'
        }
        return @{ OwlModel = ''; OwlEffort = ''; CatModel = ''; CatEffort = '' }
    }
    if ($FromMenu) {
        return @{ OwlModel = $OwlModel; OwlEffort = $OwlReasoningEffort; CatModel = $CatModel; CatEffort = $CatReasoningEffort }
    }
    foreach ($value in $OwlModel, $OwlReasoningEffort, $CatModel, $CatReasoningEffort) {
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw 'A scripted install that includes the agents component requires -OwlModel, -OwlReasoningEffort, -CatModel, and -CatReasoningEffort. Run the script without flags for a guided menu.'
        }
    }
    return @{
        OwlModel = $OwlModel.Trim()
        OwlEffort = $OwlReasoningEffort.Trim()
        CatModel = $CatModel.Trim()
        CatEffort = $CatReasoningEffort.Trim()
    }
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
        [Parameter(Mandatory)][string]$ActionValue
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
        $hookOps += @{
            Component = 'hooks'
            Source = $sourceFile.FullName
            Target = Join-Path $scriptTargetRoot $relativePath
            Display = Join-Path (Join-Path 'scripts' $HookName) $relativePath
            RewrittenContent = $null
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

    # The subagent delegation hook travels with the agents on install (the
    # agents component is the only one that collects reviewer model values),
    # and Force also lets it travel where the agents component is not
    # selected, for an install whose agents were copied by hand. An
    # uninstall removes it whenever the components that could have installed
    # it are removed, so uninstalling agents alone also cleans the guard.
    $includeGuardHook = $false
    if ($ActionValue -eq 'install') {
        $includeGuardHook = ($SubagentGuardMode -eq 'Force') -or
            (($SubagentGuardMode -eq 'Auto') -and ($componentSelection -contains 'agents'))
    }
    else {
        $includeGuardHook = ($componentSelection -contains 'agents') -or ($componentSelection -contains 'hooks')
    }
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
                $hookPlan = Get-HookOperationOps -HookName $hookName -Targets $Targets -TargetLevel $TargetLevel -ActionValue $ActionValue
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
        $guardPlan = Get-HookOperationOps -HookName $HookSubagentGuardName -Targets $Targets -TargetLevel $TargetLevel -ActionValue $ActionValue
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

try {
    $useMenu = ($PSBoundParameters.Count -eq 0)
    if ($useMenu) {
        $menuChoices = Show-Menu
        $Action = $menuChoices.Action
        $Components = $menuChoices.Components
        $Level = $menuChoices.Level
        $ProjectRoot = $menuChoices.ProjectPath
        $OwlModel = $menuChoices.ReviewerSettings.OwlModel
        $OwlReasoningEffort = $menuChoices.ReviewerSettings.OwlEffort
        $CatModel = $menuChoices.ReviewerSettings.CatModel
        $CatReasoningEffort = $menuChoices.ReviewerSettings.CatEffort
        $SubagentGuard = $menuChoices.SubagentGuard
    }

    Confirm-ParameterCombo
    $Components = Get-ComponentSelection -RequestedComponents @($Components)
    $targets = Get-TargetFolders -TargetLevel $Level -ProjectPath $ProjectRoot
    $selectedTokens = @($Components)
    $installingAgents = (($selectedTokens -contains 'agents') -or ($selectedTokens -contains 'all')) -and ($Action -eq 'install')
    $installingHooks = (($selectedTokens -contains 'hooks') -or ($selectedTokens -contains 'all')) -and ($Action -eq 'install')
    if ($PSBoundParameters.ContainsKey('SubagentGuard') -and $Action -eq 'uninstall' -and $SubagentGuard -ne 'Auto') {
        throw '-SubagentGuard applies only to install runs.'
    }
    if ($Action -eq 'install' -and $SubagentGuard -eq 'Skip' -and -not $installingAgents) {
        throw '-SubagentGuard Skip applies only when installing the agents component.'
    }
    if ($Action -eq 'install' -and $SubagentGuard -eq 'Force' -and -not ($installingAgents -or $installingHooks)) {
        throw '-SubagentGuard Force requires the agents or hooks component.'
    }
    $reviewerSettings = Get-ReviewerSettings -InstallingAgents $installingAgents -FromMenu $useMenu
    $plan = Get-InstallOperationPlan -ActionValue $Action -ComponentsValue $Components -Targets $targets -TargetLevel $Level -ReviewerSettings $reviewerSettings -SubagentGuardMode $SubagentGuard

    Write-Host "Copilot Squad $($Action.ToLowerInvariant())"
    Write-Host "Level: $Level"
    Write-Host "Components: $($Components -join ', ')"
    Write-Host "Target: $($targets.TargetRoot)"
    if ($installingAgents) {
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