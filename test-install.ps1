#requires -Version 7
<#
    Out-of-process test battery for install.ps1. Each case builds disposable
    temp roots and runs the installer (or uninstaller) as a child process with
    flags, so the real $HOME\.copilot and any real project are never touched.
    Results are asserted on the resulting file tree, the rewritten hook JSON,
    exit codes, and the reported summary lines.

    Must run under pwsh 7 like the guard battery; case 15 additionally covers
    Windows PowerShell 5.1 by launching powershell.exe when it exists.

    Run with:
      pwsh -NoProfile -File test-install.ps1
    Exits with code 1 if any case fails and prints a per-case PASS/FAIL line.
#>

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Installer = Join-Path $ScriptRoot 'install.ps1'

$script:caseFailures = 0
$script:tempRoots = @( )

$RelativeLayout = @(
    'agents/Capybara.agent.md',
    'agents/CapybaraDuo.agent.md',
    'agents/Cat.agent.md',
    'agents/Owl.agent.md',
    'skills/agents-md/SKILL.md',
    'skills/agents-md/assets/AGENTS-template.md',
    'skills/commit-message/SKILL.md',
    'skills/pr-description/SKILL.md',
    'hooks/guard-pwsh-continuation.json',
    'scripts/guard-pwsh-continuation/guard-pwsh-continuation.ps1',
    'scripts/guard-pwsh-continuation/test-guard-pwsh-continuation.ps1'
)

function New-TempRoot {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('capy-install-' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -Path $path -ItemType Directory -Force | Out-Null
    $script:tempRoots += $path
    return $path
}

function Invoke-InstallerRun {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [ValidateSet('pwsh', 'windows-powershell')][string]$Runtime = 'pwsh',
        [string]$ExecutablePath = '',
        [string]$WorkingDirectory = ''
    )
    if ($ExecutablePath -eq '') {
        $ExecutablePath = $Installer
    }
    $hostArguments = @('-NoProfile')
    if ($Runtime -eq 'windows-powershell') {
        $hostArguments += @('-ExecutionPolicy', 'Bypass')
    }
    if ($WorkingDirectory -ne '') {
        $hostArguments += @('-WorkingDirectory', $WorkingDirectory)
    }
    $command = 'pwsh'
    if ($Runtime -eq 'windows-powershell') {
        $command = 'powershell.exe'
    }
    $output = & $command @hostArguments -File $ExecutablePath @Arguments 2>&1
    [pscustomobject]@{
        Output   = ($output | Out-String)
        ExitCode = $LASTEXITCODE
    }
}

function Add-Result {
    param([bool]$Condition, [string]$CaseName, [string]$FailMessage)
    if ($Condition) {
        Write-Output "PASS [$CaseName]"
    }
    else {
        Write-Output "FAIL [$CaseName]: $FailMessage"
        $script:caseFailures++
    }
}

function Test-AllFilesExist {
    param([string]$Root, [string[]]$RelativePaths)
    if (-not (Test-Path -LiteralPath $Root)) {
        return $false
    }
    foreach ($relativePath in $RelativePaths) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $relativePath) -PathType Leaf)) {
            return $false
        }
    }
    return $true
}

function Get-InstalledFileCount {
    param([string]$Root)
    if (-not (Test-Path -LiteralPath $Root)) {
        return 0
    }
    return @(Get-ChildItem -LiteralPath $Root -Recurse -File).Count
}

try {
    # Case 1: install all to a fresh user-level root.
    $userRoot = New-TempRoot
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'all', '-Level', 'user', '-UserRoot', $userRoot)
    Add-Result -Condition ($result.ExitCode -eq 0) -CaseName 'install all (user level) exits 0' -FailMessage "exit code $($result.ExitCode)"
    Add-Result -Condition (Test-AllFilesExist -Root $userRoot -RelativePaths $RelativeLayout) -CaseName 'install all (user level) file set' -FailMessage 'expected files are missing'
    Add-Result -Condition ($result.Output.Contains('Done: 11 copied, 0 overwritten.')) -CaseName 'install all (user level) summary' -FailMessage $result.Output

    # Case 2: the installed hook JSON has the real profile path and no placeholder.
    $installedJsonPath = Join-Path $userRoot 'hooks/guard-pwsh-continuation.json'
    $installedJson = Get-Content -LiteralPath $installedJsonPath -Raw
    $profilePrefix = ($HOME -replace '\\', '/').TrimEnd('/')
    $expectedFileArgument = "$profilePrefix/.copilot/scripts/guard-pwsh-continuation/guard-pwsh-continuation.ps1"
    $parsedJson = $null
    try {
        $parsedJson = $installedJson | ConvertFrom-Json
    }
    catch {
    }
    Add-Result -Condition ($null -ne $parsedJson) -CaseName 'installed hook JSON parses' -FailMessage 'ConvertFrom-Json failed'
    Add-Result -Condition (-not $installedJson.Contains('C:/Users/YOUR-PROFILE')) -CaseName 'installed hook JSON has no placeholder' -FailMessage $installedJson
    Add-Result -Condition ($installedJson.Contains($expectedFileArgument)) -CaseName 'installed hook JSON -File points at the real profile' -FailMessage $installedJson
    Add-Result -Condition ($parsedJson.hooks.PreToolUse[0].timeout -eq 10) -CaseName 'installed hook JSON keeps the timeout' -FailMessage $installedJson

    # Case 3: agents only.
    $agentsRoot = New-TempRoot
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $agentsRoot)
    Add-Result -Condition ($result.ExitCode -eq 0) -CaseName 'install agents only exits 0' -FailMessage "exit code $($result.ExitCode)"
    Add-Result -Condition (Test-AllFilesExist -Root $agentsRoot -RelativePaths $RelativeLayout[0..3]) -CaseName 'install agents only file set' -FailMessage 'agent files are missing'
    Add-Result -Condition (-not (Test-Path -LiteralPath (Join-Path $agentsRoot 'skills/commit-message/SKILL.md'))) -CaseName 'install agents only skips skills' -FailMessage 'skill was installed'
    Add-Result -Condition (-not (Test-Path -LiteralPath (Join-Path $agentsRoot 'hooks/guard-pwsh-continuation.json'))) -CaseName 'install agents only skips hooks' -FailMessage 'hook was installed'

    # Case 4: skills only, including the assets subfolder.
    $skillsRoot = New-TempRoot
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'skills', '-Level', 'user', '-UserRoot', $skillsRoot)
    Add-Result -Condition ($result.ExitCode -eq 0) -CaseName 'install skills only exits 0' -FailMessage "exit code $($result.ExitCode)"
    Add-Result -Condition (Test-AllFilesExist -Root $skillsRoot -RelativePaths $RelativeLayout[4..7]) -CaseName 'install skills only file set incl. assets' -FailMessage 'skill files are missing'
    Add-Result -Condition (-not (Test-Path -LiteralPath (Join-Path $skillsRoot 'agents/Capybara.agent.md'))) -CaseName 'install skills only skips agents' -FailMessage 'agent was installed'

    # Case 5: hooks only.
    $hooksRoot = New-TempRoot
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'hooks', '-Level', 'user', '-UserRoot', $hooksRoot)
    Add-Result -Condition ($result.ExitCode -eq 0) -CaseName 'install hooks only exits 0' -FailMessage "exit code $($result.ExitCode)"
    Add-Result -Condition (Test-AllFilesExist -Root $hooksRoot -RelativePaths $RelativeLayout[8..10]) -CaseName 'install hooks only file set' -FailMessage 'hook files are missing'
    Add-Result -Condition (-not (Test-Path -LiteralPath (Join-Path $hooksRoot 'agents/Capybara.agent.md'))) -CaseName 'install hooks only skips agents' -FailMessage 'agent was installed'

    # Case 6: a name conflict is overwritten by default.
    $overwriteRoot = New-TempRoot
    $sentinelPath = Join-Path $overwriteRoot 'agents/Capybara.agent.md'
    New-Item -Path (Join-Path $overwriteRoot 'agents') -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath $sentinelPath -Value 'SENTINEL-OLD-CONTENT' -NoNewline
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'all', '-Level', 'user', '-UserRoot', $overwriteRoot)
    Add-Result -Condition ($result.ExitCode -eq 0) -CaseName 'conflicting install exits 0' -FailMessage "exit code $($result.ExitCode)"
    Add-Result -Condition (((Get-Content -LiteralPath $sentinelPath -Raw).TrimEnd()) -ne 'SENTINEL-OLD-CONTENT') -CaseName 'conflicting install overwrites the file' -FailMessage 'sentinel content survived'
    Add-Result -Condition ($result.Output.Contains('Done: 10 copied, 1 overwritten.')) -CaseName 'conflicting install reports overwrite' -FailMessage $result.Output

    # Case 7: re-running the install is idempotent.
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'all', '-Level', 'user', '-UserRoot', $overwriteRoot)
    Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains('Done: 0 copied, 11 overwritten.')) -CaseName 're-run reports 11 overwritten' -FailMessage $result.Output

    # Case 8: repo-level install into an existing project folder.
    $repoProject = New-TempRoot
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'all', '-Level', 'repo', '-ProjectRoot', $repoProject)
    Add-Result -Condition ($result.ExitCode -eq 0) -CaseName 'repo-level install exits 0' -FailMessage "exit code $($result.ExitCode)"
    Add-Result -Condition (Test-AllFilesExist -Root $repoProject -RelativePaths ($RelativeLayout | ForEach-Object { '.github/' + $_ })) -CaseName 'repo-level install file set under .github' -FailMessage 'expected files are missing'
    $repoJsonPath = Join-Path $repoProject '.github/hooks/guard-pwsh-continuation.json'
    $repoJson = Get-Content -LiteralPath $repoJsonPath -Raw
    Add-Result -Condition ($repoJson.Contains('.github/scripts/guard-pwsh-continuation/guard-pwsh-continuation.ps1')) -CaseName 'repo-level hook JSON is repo-relative' -FailMessage $repoJson
    Add-Result -Condition (-not $repoJson.Contains('C:/Users/YOUR-PROFILE')) -CaseName 'repo-level hook JSON has no placeholder' -FailMessage $repoJson

    # Case 9: repo-level flags without -ProjectRoot fail clearly.
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'all', '-Level', 'repo')
    Add-Result -Condition ($result.ExitCode -eq 1 -and $result.Output.Contains('requires -ProjectRoot')) -CaseName 'repo-level without -ProjectRoot fails' -FailMessage $result.Output

    # Case 10: -ProjectRoot combined with the user level fails clearly.
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'all', '-Level', 'user', '-UserRoot', (New-TempRoot), '-ProjectRoot', (New-TempRoot))
    Add-Result -Condition ($result.ExitCode -eq 1 -and $result.Output.Contains('applies only')) -CaseName 'user level with -ProjectRoot fails' -FailMessage $result.Output

    # Case 11: uninstall all removes only squad files.
    $uninstallRoot = New-TempRoot
    $null = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'all', '-Level', 'user', '-UserRoot', $uninstallRoot)
    New-Item -Path (Join-Path $uninstallRoot 'agents') -ItemType Directory -Force | Out-Null
    $unrelatedAgent = Join-Path $uninstallRoot 'agents/MyOwn.agent.md'
    Set-Content -LiteralPath $unrelatedAgent -Value 'KEEP ME' -NoNewline
    $result = Invoke-InstallerRun -Arguments @('-Action', 'uninstall', '-Components', 'all', '-Level', 'user', '-UserRoot', $uninstallRoot)
    Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains('Done: 11 removed, 0 absent, 0 leftover(s) reported.')) -CaseName 'uninstall all summary' -FailMessage $result.Output
    Add-Result -Condition (Test-Path -LiteralPath $unrelatedAgent -PathType Leaf) -CaseName 'uninstall keeps unrelated files' -FailMessage 'unrelated agent was removed'
    Add-Result -Condition (-not (Test-Path -LiteralPath (Join-Path $uninstallRoot 'agents/Capybara.agent.md'))) -CaseName 'uninstall removes squad agents' -FailMessage 'squad agent survived'
    Add-Result -Condition (-not (Test-Path -LiteralPath (Join-Path $uninstallRoot 'skills/agents-md'))) -CaseName 'uninstall prunes empty squad folders' -FailMessage 'skill folder survived'
    Add-Result -Condition (Test-Path -LiteralPath (Join-Path $uninstallRoot 'agents') -PathType Container) -CaseName 'uninstall keeps non-empty root folders' -FailMessage 'agents folder was removed'

    # Case 12: repo-level uninstall of hooks only.
    $repoUninstallProject = New-TempRoot
    $null = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'all', '-Level', 'repo', '-ProjectRoot', $repoUninstallProject)
    $unrelatedSkillNote = Join-Path $repoUninstallProject '.github/skills/extra-note.txt'
    Set-Content -LiteralPath $unrelatedSkillNote -Value 'KEEP ME' -NoNewline
    $result = Invoke-InstallerRun -Arguments @('-Action', 'uninstall', '-Components', 'hooks', '-Level', 'repo', '-ProjectRoot', $repoUninstallProject)
    Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains('Done: 3 removed, 0 absent, 0 leftover(s) reported.')) -CaseName 'repo uninstall of hooks summary' -FailMessage $result.Output
    Add-Result -Condition (-not (Test-Path -LiteralPath (Join-Path $repoUninstallProject '.github/hooks/guard-pwsh-continuation.json'))) -CaseName 'repo uninstall removes hook JSON' -FailMessage 'hook JSON survived'
    Add-Result -Condition (-not (Test-Path -LiteralPath (Join-Path $repoUninstallProject '.github/scripts/guard-pwsh-continuation'))) -CaseName 'repo uninstall removes script folder' -FailMessage 'script folder survived'
    Add-Result -Condition (Test-Path -LiteralPath (Join-Path $repoUninstallProject '.github/agents/Capybara.agent.md') -PathType Leaf) -CaseName 'repo uninstall keeps agents' -FailMessage 'agent was removed'
    Add-Result -Condition (Test-Path -LiteralPath $unrelatedSkillNote -PathType Leaf) -CaseName 'repo uninstall keeps unrelated files' -FailMessage 'extra file was removed'

    # Case 13: leftovers from a manual rename are reported, not deleted.
    $leftoverRoot = New-TempRoot
    $null = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'hooks', '-Level', 'user', '-UserRoot', $leftoverRoot)
    $leftoverHook = Join-Path $leftoverRoot 'hooks/guard-pwsh-continuation.json.old.disabled'
    $leftoverScript = Join-Path $leftoverRoot 'scripts/guard-pwsh-continuation.old.disabled'
    Set-Content -LiteralPath $leftoverHook -Value 'OLD' -NoNewline
    Set-Content -LiteralPath $leftoverScript -Value 'OLD' -NoNewline
    $result = Invoke-InstallerRun -Arguments @('-Action', 'uninstall', '-Components', 'hooks', '-Level', 'user', '-UserRoot', $leftoverRoot)
    $disabledSurvives = (Test-Path -LiteralPath $leftoverHook -PathType Leaf) -and (Test-Path -LiteralPath $leftoverScript -PathType Leaf)
    Add-Result -Condition ($disabledSurvives) -CaseName 'leftover .disabled files survive uninstall' -FailMessage 'leftover was deleted'
    Add-Result -Condition ($result.Output.Contains('leftover(s) reported.') -and $result.Output.Contains('guard-pwsh-continuation.json.old.disabled')) -CaseName 'leftover files are listed for manual review' -FailMessage $result.Output

    # Case 14: -WhatIf prints the plan and changes nothing.
    $whatIfRoot = New-TempRoot
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'all', '-Level', 'user', '-UserRoot', $whatIfRoot, '-WhatIf')
    Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains('planned (copied)') -and $result.Output.Contains('What-if run finished. No changes were made.')) -CaseName 'WhatIf prints a plan' -FailMessage $result.Output
    Add-Result -Condition ((Get-InstalledFileCount -Root $whatIfRoot) -eq 0) -CaseName 'WhatIf writes nothing' -FailMessage 'files were created'

    # Case 15: install and uninstall under Windows PowerShell 5.1.
    if (Get-Command powershell.exe -ErrorAction SilentlyContinue) {
        $ps51Root = New-TempRoot
        $result = Invoke-InstallerRun -Runtime windows-powershell -Arguments @('-Action', 'install', '-Components', 'all', '-Level', 'user', '-UserRoot', $ps51Root)
        Add-Result -Condition ($result.ExitCode -eq 0) -CaseName 'installer under Windows PowerShell 5.1 exits 0' -FailMessage $result.Output
        Add-Result -Condition (Test-AllFilesExist -Root $ps51Root -RelativePaths $RelativeLayout) -CaseName 'installer under Windows PowerShell 5.1 file set' -FailMessage 'expected files are missing'
        $ps51Json = Get-Content -LiteralPath (Join-Path $ps51Root 'hooks/guard-pwsh-continuation.json') -Raw
        Add-Result -Condition ($ps51Json.Contains($expectedFileArgument)) -CaseName 'installer under Windows PowerShell 5.1 rewrites the hook path' -FailMessage $ps51Json
        New-Item -Path (Join-Path $ps51Root 'agents') -ItemType Directory -Force | Out-Null
        $unrelated51 = Join-Path $ps51Root 'agents/MyOwn51.agent.md'
        Set-Content -LiteralPath $unrelated51 -Value 'KEEP ME' -NoNewline
        $result = Invoke-InstallerRun -Runtime windows-powershell -Arguments @('-Action', 'uninstall', '-Components', 'all', '-Level', 'user', '-UserRoot', $ps51Root)
        Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains('Done: 11 removed, 0 absent, 0 leftover(s) reported.')) -CaseName 'uninstaller under Windows PowerShell 5.1 removes squad files' -FailMessage $result.Output
        Add-Result -Condition (Test-Path -LiteralPath $unrelated51 -PathType Leaf) -CaseName 'uninstaller under Windows PowerShell 5.1 keeps unrelated files' -FailMessage 'unrelated agent was removed'
    }
    else {
        Write-Output 'SKIP [installer under Windows PowerShell 5.1]: powershell.exe not found'
    }

    # Case 16: a template without the placeholder aborts instead of installing.
    $copyRoot = New-TempRoot
    foreach ($repoFolder in 'agents', 'skills', 'hooks', 'scripts') {
        Copy-Item -LiteralPath (Join-Path $ScriptRoot $repoFolder) -Destination (Join-Path $copyRoot $repoFolder) -Recurse
    }
    Copy-Item -LiteralPath $Installer -Destination $copyRoot
    $mutatedJsonPath = Join-Path $copyRoot 'hooks/guard-pwsh-continuation.json'
    (Get-Content -LiteralPath $mutatedJsonPath -Raw).Replace('C:/Users/YOUR-PROFILE', 'C:/Users/ALREADY-REAL') |
        Set-Content -LiteralPath $mutatedJsonPath -NoNewline
    $abortedUserRoot = New-TempRoot
    $result = Invoke-InstallerRun -ExecutablePath (Join-Path $copyRoot 'install.ps1') -Arguments @('-Action', 'install', '-Components', 'hooks', '-Level', 'user', '-UserRoot', $abortedUserRoot)
    Add-Result -Condition ($result.ExitCode -eq 1 -and $result.Output.Contains('placeholder')) -CaseName 'missing placeholder aborts the install' -FailMessage $result.Output
    Add-Result -Condition ((Get-InstalledFileCount -Root $abortedUserRoot) -eq 0) -CaseName 'missing placeholder writes nothing' -FailMessage 'files were created'

    # Case 17: the interactive menu works with piped answers.
    $menuProject = New-TempRoot
    $menuAnswers = '1', '1', '2', $menuProject, '1'
    $menuOutput = $menuAnswers -join "`r`n" | & pwsh -NoProfile -ExecutionPolicy Bypass -File $Installer 2>&1
    $menuExit = $LASTEXITCODE
    Add-Result -Condition ($menuExit -eq 0) -CaseName 'piped menu install exits 0' -FailMessage (($menuOutput | Out-String))
    Add-Result -Condition (Test-AllFilesExist -Root $menuProject -RelativePaths ($RelativeLayout | ForEach-Object { '.github/' + $_ })) -CaseName 'piped menu install file set' -FailMessage 'expected files are missing'

    # Case 18: the installer is independent of the caller's working directory.
    if ($PSVersionTable.PSVersion -ge [version]'7.2') {
        $cwdRoot = New-TempRoot
        $anywhere = New-TempRoot
        $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $cwdRoot) -WorkingDirectory $anywhere
        Add-Result -Condition ($result.ExitCode -eq 0 -and (Test-AllFilesExist -Root $cwdRoot -RelativePaths $RelativeLayout[0..3])) -CaseName 'installer ignores the caller cwd for sources' -FailMessage $result.Output
    }
    else {
        Write-Output 'SKIP [installer ignores the caller cwd]: pwsh lacks -WorkingDirectory'
    }

    # Case 19: -UserRoot combined with the repo level fails clearly.
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'all', '-Level', 'repo', '-ProjectRoot', (New-TempRoot), '-UserRoot', (New-TempRoot))
    Add-Result -Condition ($result.ExitCode -eq 1 -and $result.Output.Contains('UserRoot applies only')) -CaseName 'repo level with -UserRoot fails' -FailMessage $result.Output

    # Case 20: the piped menu cancels on EOF because Proceed defaults to No.
    $menuAnswers = '1', '1', '1'
    $menuText = $menuAnswers -join "`r`n" | & pwsh -NoProfile -ExecutionPolicy Bypass -File $Installer 2>&1
    $menuExit = $LASTEXITCODE
    Add-Result -Condition ($menuExit -eq 0 -and (($menuText | Out-String)).Contains('Cancelled. No changes were made.')) -CaseName 'piped menu cancels when Proceed is unanswered' -FailMessage (($menuText | Out-String))

    # Case 21: an agents-only uninstall removes the agents and no folders.
    $agentsUninstallRoot = New-TempRoot
    $null = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $agentsUninstallRoot)
    $result = Invoke-InstallerRun -Arguments @('-Action', 'uninstall', '-Components', 'agents', '-Level', 'user', '-UserRoot', $agentsUninstallRoot)
    Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains('Done: 4 removed, 0 absent, 0 leftover(s) reported.')) -CaseName 'agents-only uninstall summary' -FailMessage $result.Output
    Add-Result -Condition (-not (Test-Path -LiteralPath (Join-Path $agentsUninstallRoot 'agents/Capybara.agent.md'))) -CaseName 'agents-only uninstall removes agents' -FailMessage 'agent survived'
    Add-Result -Condition (Test-Path -LiteralPath (Join-Path $agentsUninstallRoot 'agents') -PathType Container) -CaseName 'agents-only uninstall keeps the agents root' -FailMessage 'root folder was removed'

    # Case 22: several selected components install together via a comma list;
    # separate values fail fast at the host.
    $multiRootSeparate = New-TempRoot
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'agents,skills', '-Level', 'user', '-UserRoot', $multiRootSeparate)
    Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains('Components: agents, skills') -and $result.Output.Contains('Done: 8 copied, 0 overwritten.')) -CaseName 'multi component install summary' -FailMessage $result.Output
    Add-Result -Condition (Test-AllFilesExist -Root $multiRootSeparate -RelativePaths $RelativeLayout[0..7]) -CaseName 'multi component install file set' -FailMessage 'agent or skill files are missing'
    Add-Result -Condition (-not (Test-Path -LiteralPath (Join-Path $multiRootSeparate 'hooks/guard-pwsh-continuation.json'))) -CaseName 'multi component install skips hooks' -FailMessage 'hook was installed'
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'agents', 'skills', '-Level', 'user', '-UserRoot', $multiRootSeparate)
    Add-Result -Condition ($result.ExitCode -eq 1) -CaseName 'separate values fail fast at the host' -FailMessage "exit $($result.ExitCode)"

    # Case 23: duplicate component values collapse to one set.
    $dedupeRoot = New-TempRoot
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'agents,agents,skills', '-Level', 'user', '-UserRoot', $dedupeRoot)
    Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains('Done: 8 copied, 0 overwritten.')) -CaseName 'duplicate components deduplicate' -FailMessage $result.Output

    # Case 24: -Components all cannot be combined with named components.
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'all,agents', '-Level', 'user', '-UserRoot', (New-TempRoot))
    Add-Result -Condition ($result.ExitCode -eq 1 -and $result.Output.Contains('cannot be combined')) -CaseName 'all plus named components fails' -FailMessage $result.Output

    # Case 25: an unknown component name fails clearly.
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'agents,mystery', '-Level', 'user', '-UserRoot', (New-TempRoot))
    Add-Result -Condition ($result.ExitCode -eq 1 -and $result.Output.Contains("Unknown component 'mystery'")) -CaseName 'unknown component fails' -FailMessage $result.Output

    # Case 26: uninstall removes every selected component in one run.
    $multiUninstallRoot = New-TempRoot
    $null = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'agents,skills', '-Level', 'user', '-UserRoot', $multiUninstallRoot)
    $result = Invoke-InstallerRun -Arguments @('-Action', 'uninstall', '-Components', 'agents,skills', '-Level', 'user', '-UserRoot', $multiUninstallRoot)
    Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains('Done: 8 removed, 0 absent, 0 leftover(s) reported.')) -CaseName 'multi component uninstall summary' -FailMessage $result.Output
    Add-Result -Condition ((Get-InstalledFileCount -Root (Join-Path $multiUninstallRoot 'skills')) -eq 0) -CaseName 'multi component uninstall empties skills' -FailMessage 'skill files survived'

    # Case 27: the menu accepts a multi-select component answer.
    $menuMultiProject = New-TempRoot
    $multiMenuAnswers = '1', '2,3', '2', $menuMultiProject, '1'
    $multiMenuText = $multiMenuAnswers -join "`r`n" | & pwsh -NoProfile -ExecutionPolicy Bypass -File $Installer 2>&1
    $multiMenuExit = $LASTEXITCODE
    Add-Result -Condition ($multiMenuExit -eq 0) -CaseName 'piped menu multi-select exits 0' -FailMessage (($multiMenuText | Out-String))
    $repoMultiLayout = $RelativeLayout[0..7] | ForEach-Object { '.github/' + $_ }
    Add-Result -Condition (Test-AllFilesExist -Root $menuMultiProject -RelativePaths $repoMultiLayout) -CaseName 'piped menu multi-select file set' -FailMessage 'expected files are missing'
    Add-Result -Condition (-not (Test-Path -LiteralPath (Join-Path $menuMultiProject '.github/hooks/guard-pwsh-continuation.json'))) -CaseName 'piped menu multi-select skips hooks' -FailMessage 'hook was installed'

    # Case 28: a comma-only menu answer re-prompts without consuming the next answer.
    $commaPromptProject = New-TempRoot
    $commaPromptAnswers = '1', ',', '2,3', '2', $commaPromptProject, '1'
    $commaPromptText = $commaPromptAnswers -join "`r`n" | & pwsh -NoProfile -ExecutionPolicy Bypass -File $Installer 2>&1
    $commaPromptExit = $LASTEXITCODE
    Add-Result -Condition ($commaPromptExit -eq 0) -CaseName 'comma-only menu answer re-prompts cleanly' -FailMessage (($commaPromptText | Out-String))
    Add-Result -Condition ((($commaPromptText | Out-String)).Contains('Components: agents, skills')) -CaseName 'comma-only answer recovers to the selection' -FailMessage (($commaPromptText | Out-String))
    Add-Result -Condition (Test-Path -LiteralPath (Join-Path $commaPromptProject '.github/agents/Capybara.agent.md') -PathType Leaf) -CaseName 'prompted answer still installs' -FailMessage 'agent was not installed'
}
finally {
    foreach ($tempRoot in $script:tempRoots) {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($script:caseFailures -gt 0) {
    Write-Output "$($script:caseFailures) case(s) failed."
    exit 1
}
Write-Output 'All cases passed.'
exit 0