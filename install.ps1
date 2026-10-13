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

    The hooks component covers both the hook JSON and its companion script,
    because a hook whose script cannot be launched fail-closes every shell
    tool call. The installed hook JSON is rewritten from the shipped template
    before use, so no placeholder path remains:
      - user level: the placeholder becomes the real profile's .copilot path
      - repo level: the placeholder becomes the repo-relative .github path
    A template without the placeholder aborts the run before anything is
    written.

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

.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File install.ps1

.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Action install -Components agents,skills -Level user

.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Action install -Components hooks -Level repo -ProjectRoot C:\projects\my-app

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

    [string]$UserRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RepoRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$AgentFiles = 'Capybara.agent.md', 'CapybaraDuo.agent.md', 'Cat.agent.md', 'Owl.agent.md'
$SkillFolders = 'agents-md', 'commit-message', 'pr-description'
$HookJsonName = 'guard-pwsh-continuation.json'
$HookScriptFolder = 'guard-pwsh-continuation'
$HookUserPlaceholder = 'C:/Users/YOUR-PROFILE'
$HookRepoPlaceholder = 'C:/Users/YOUR-PROFILE/.copilot/scripts'
$LeftoverPattern = '^(CapybaraDuo|Capybara|Cat|Owl|guard-pwsh-continuation|agents-md|commit-message|pr-description)([._\- ]|$)'

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

function Read-ComponentMenu {
    $optionLabels = @(
        'all (agents, skills, and hooks)',
        'agents (4 custom agent profiles)',
        'skills (3 squad skills)',
        'hooks (guard hook config and its companion script)')
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

    return @{
        Action = $actionValues[$actionIndex]
        Components = $componentSelection
        Level = $levelValues[$levelIndex]
        ProjectPath = $projectPath
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

function Get-RewrittenHookJson {
    param([Parameter(Mandatory)][string]$TargetLevel)
    $sourceJsonPath = Join-Path (Join-Path $RepoRoot 'hooks') $HookJsonName
    if (-not (Test-Path -LiteralPath $sourceJsonPath -PathType Leaf)) {
        throw "Source file missing in the squad repo: $sourceJsonPath"
    }
    $raw = Get-Content -LiteralPath $sourceJsonPath -Raw
    $placeholder = $HookUserPlaceholder
    if ($TargetLevel -eq 'repo') {
        $placeholder = $HookRepoPlaceholder
    }
    if (-not $raw.Contains($placeholder)) {
        throw "The hook template $sourceJsonPath does not contain the expected placeholder '$placeholder'. Restore the shipped template, then re-run."
    }

    if ($TargetLevel -eq 'user') {
        $replacement = ($HOME -replace '\\', '/').TrimEnd('/')
    }
    else {
        $replacement = '.github/scripts'
    }
    $rewritten = $raw.Replace($placeholder, $replacement)
    foreach ($remainingPlaceholder in $HookUserPlaceholder, $HookRepoPlaceholder) {
        if ($rewritten.Contains($remainingPlaceholder)) {
            throw "The hook placeholder '$remainingPlaceholder' is still present after rewriting."
        }
    }
    $null = $rewritten | ConvertFrom-Json
    return $rewritten
}

function Get-InstallOperationPlan {
    param(
        [Parameter(Mandatory)][string]$ActionValue,
        [string[]]$ComponentsValue = @('all'),
        [Parameter(Mandatory)][hashtable]$Targets,
        [Parameter(Mandatory)][string]$TargetLevel
    )
    $componentSelection = 'agents', 'skills', 'hooks'
    if (@($ComponentsValue) -notcontains 'all') {
        $componentSelection = $ComponentsValue
    }

    # Only the selected components are planned, so a partial clone can install
    # or remove one component without the other components' sources in place.
    $fileOps = @()
    $folderPrunes = @()

    foreach ($component in $componentSelection) {
        if ($component -eq 'agents') {
            foreach ($agentFileName in $AgentFiles) {
                $fileOps += @{
                    Component = 'agents'
                    Source = Join-Path (Join-Path $RepoRoot 'agents') $agentFileName
                    Target = Join-Path $Targets.Agents $agentFileName
                    Display = Join-Path 'agents' $agentFileName
                    RewrittenContent = $null
                }
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
            $hookJsonSource = Join-Path (Join-Path $RepoRoot 'hooks') $HookJsonName
            $hookJsonOp = @{
                Component = 'hooks'
                Source = $hookJsonSource
                Target = Join-Path $Targets.Hooks $HookJsonName
                Display = Join-Path 'hooks' $HookJsonName
                RewrittenContent = $null
            }
            if ($ActionValue -eq 'install') {
                if (-not (Test-Path -LiteralPath $hookJsonSource -PathType Leaf)) {
                    throw "Source file missing in the squad repo: $hookJsonSource"
                }
                # The rewrite is resolved while planning, so a broken template
                # aborts the whole run before any file is written.
                $hookJsonOp.RewrittenContent = Get-RewrittenHookJson -TargetLevel $TargetLevel
            }
            $fileOps += $hookJsonOp

            $scriptSourceRoot = Join-Path (Join-Path $RepoRoot 'scripts') $HookScriptFolder
            $scriptTargetRoot = Join-Path $Targets.Scripts $HookScriptFolder
            foreach ($sourceFile in Get-SourceFiles -SourceFolder $scriptSourceRoot) {
                $relativePath = Get-RelativePathBelow -FullPath $sourceFile.FullName -BasePath $scriptSourceRoot
                $fileOps += @{
                    Component = 'hooks'
                    Source = $sourceFile.FullName
                    Target = Join-Path $scriptTargetRoot $relativePath
                    Display = Join-Path (Join-Path 'scripts' $HookScriptFolder) $relativePath
                    RewrittenContent = $null
                }
            }
            $folderPrunes += @{ Component = 'hooks'; Folder = $scriptTargetRoot }
        }
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
    $squadPaths = @()
    foreach ($agentFileName in $AgentFiles) {
        $squadPaths += (Join-Path $Targets.Agents $agentFileName)
    }
    $squadPaths += (Join-Path $Targets.Hooks $HookJsonName)
    $squadFolders = @()
    foreach ($skillFolder in $SkillFolders) {
        $squadFolders += (Join-Path $Targets.Skills $skillFolder)
    }
    $squadFolders += (Join-Path $Targets.Scripts $HookScriptFolder)

    return @{
        FileOps = $fileOps
        FolderPrunes = $folderPrunes
        SquadPaths = $squadPaths
        SquadFolders = $squadFolders
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
                Write-Host ('What if: writing rewritten hook JSON to {0}' -f $fileOp.Target)
            }
            else {
                # WriteAllText keeps the JSON free of a PowerShell BOM, which
                # some JSON readers reject.
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
    }

    Confirm-ParameterCombo
    $Components = Get-ComponentSelection -RequestedComponents @($Components)
    $targets = Get-TargetFolders -TargetLevel $Level -ProjectPath $ProjectRoot
    $plan = Get-InstallOperationPlan -ActionValue $Action -ComponentsValue $Components -Targets $targets -TargetLevel $Level

    Write-Host "Copilot Squad $($Action.ToLowerInvariant())"
    Write-Host "Level: $Level"
    Write-Host "Components: $($Components -join ', ')"
    Write-Host "Target: $($targets.TargetRoot)"
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