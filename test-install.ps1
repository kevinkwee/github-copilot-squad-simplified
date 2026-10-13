#requires -Version 7
<#
    Out-of-process test battery for install.ps1. Each case builds disposable
    temp roots and runs the installer (or uninstaller) as a child process with
    flags, or through piped menu answers inside a disposable user profile, so
    the real $HOME\.copilot and any real project are never touched.
    Results are asserted on the resulting file tree, the rewritten hook JSON
    and agent templates, exit codes, and the reported summary lines.

    Must run under pwsh 7 like the guard battery; case 15 additionally covers
    Windows PowerShell 5.1 by launching powershell.exe when it exists.

    Run with:
      pwsh -NoProfile -File test-install.ps1
    Exits with code 1 if any case fails and prints a per-case PASS/FAIL line.
#>

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Installer = Join-Path $ScriptRoot 'install.ps1'
$SubagentFlags = @(
    '-OwlModel', 'piped/GLM 5.3',
    '-OwlReasoningEffort', 'piped-owl-high',
    '-CatModel', 'piped/cat-flash',
    '-CatReasoningEffort', 'piped-cat-low'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

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

# ConciseView wraps long error messages and prefixes continuation lines with a
# `|` gutter, so strip gutters and collapse whitespace before substring checks.
function ConvertTo-ComparableOutput {
    param([string]$Output)
    ($Output -replace '(?m)^\s*\|', '') -replace '\s+', ' '
}

function Invoke-PipedMenuRun {
    param([string[]]$Answers)
    # Piped menu runs have no flag to redirect the target. The child session
    # gets a disposable user profile, so user-level menu answers land in the
    # sandbox and the real profile is never touched.
    $previousUserProfile = $env:USERPROFILE
    $previousHomeDrive = $env:HOMEDRIVE
    $previousHomePath = $env:HOMEPATH
    $sandboxProfile = New-TempRoot
    $env:USERPROFILE = $sandboxProfile
    $env:HOMEDRIVE = $sandboxProfile.Substring(0, 2)
    $env:HOMEPATH = $sandboxProfile.Substring(2)
    try {
        $output = ($Answers -join "`r`n") | & pwsh -NoProfile -ExecutionPolicy Bypass -File $Installer 2>&1
    }
    finally {
        $env:USERPROFILE = $previousUserProfile
        $env:HOMEDRIVE = $previousHomeDrive
        $env:HOMEPATH = $previousHomePath
    }
    [pscustomobject]@{
        Output      = ($output | Out-String)
        ExitCode    = $LASTEXITCODE
        UserProfile = $sandboxProfile
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
    $result = Invoke-InstallerRun -Arguments (@('-Action', 'install', '-Components', 'all', '-Level', 'user', '-UserRoot', $userRoot) + $SubagentFlags)
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
    $result = Invoke-InstallerRun -Arguments (@('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $agentsRoot) + $SubagentFlags)
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
    $result = Invoke-InstallerRun -Arguments (@('-Action', 'install', '-Components', 'all', '-Level', 'user', '-UserRoot', $overwriteRoot) + $SubagentFlags)
    Add-Result -Condition ($result.ExitCode -eq 0) -CaseName 'conflicting install exits 0' -FailMessage "exit code $($result.ExitCode)"
    Add-Result -Condition (((Get-Content -LiteralPath $sentinelPath -Raw).TrimEnd()) -ne 'SENTINEL-OLD-CONTENT') -CaseName 'conflicting install overwrites the file' -FailMessage 'sentinel content survived'
    Add-Result -Condition ($result.Output.Contains('Done: 10 copied, 1 overwritten.')) -CaseName 'conflicting install reports overwrite' -FailMessage $result.Output

    # Case 7: re-running the install is idempotent.
    $result = Invoke-InstallerRun -Arguments (@('-Action', 'install', '-Components', 'all', '-Level', 'user', '-UserRoot', $overwriteRoot) + $SubagentFlags)
    Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains('Done: 0 copied, 11 overwritten.')) -CaseName 're-run reports 11 overwritten' -FailMessage $result.Output

    # Case 8: repo-level install into an existing project folder.
    $repoProject = New-TempRoot
    $result = Invoke-InstallerRun -Arguments (@('-Action', 'install', '-Components', 'all', '-Level', 'repo', '-ProjectRoot', $repoProject) + $SubagentFlags)
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
    $null = Invoke-InstallerRun -Arguments (@('-Action', 'install', '-Components', 'all', '-Level', 'user', '-UserRoot', $uninstallRoot) + $SubagentFlags)
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
    $null = Invoke-InstallerRun -Arguments (@('-Action', 'install', '-Components', 'all', '-Level', 'repo', '-ProjectRoot', $repoUninstallProject) + $SubagentFlags)
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
    $result = Invoke-InstallerRun -Arguments (@('-Action', 'install', '-Components', 'all', '-Level', 'user', '-UserRoot', $whatIfRoot, '-WhatIf') + $SubagentFlags)
    Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains('planned (copied)') -and $result.Output.Contains('What-if run finished. No changes were made.')) -CaseName 'WhatIf prints a plan' -FailMessage $result.Output
    Add-Result -Condition ((Get-InstalledFileCount -Root $whatIfRoot) -eq 0) -CaseName 'WhatIf writes nothing' -FailMessage 'files were created'

    # Case 15: install and uninstall under Windows PowerShell 5.1.
    if (Get-Command powershell.exe -ErrorAction SilentlyContinue) {
        $ps51Root = New-TempRoot
        $result = Invoke-InstallerRun -Runtime windows-powershell -Arguments (@('-Action', 'install', '-Components', 'all', '-Level', 'user', '-UserRoot', $ps51Root) + $SubagentFlags)
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
    $menuRun = Invoke-PipedMenuRun -Answers @('1', '1', '2', $menuProject, 'menu/owl-5.3', 'menu-owl-high', 'menu/cat-5.3', 'menu-cat-low', '1')
    Add-Result -Condition ($menuRun.ExitCode -eq 0) -CaseName 'piped menu install exits 0' -FailMessage $menuRun.Output
    Add-Result -Condition (Test-AllFilesExist -Root $menuProject -RelativePaths ($RelativeLayout | ForEach-Object { '.github/' + $_ })) -CaseName 'piped menu install file set' -FailMessage 'expected files are missing'
    $pipedCapybara = Get-Content -LiteralPath (Join-Path $menuProject '.github/agents/Capybara.agent.md') -Raw
    $pipedFillOk = $pipedCapybara.Contains('menu/owl-5.3') -and $pipedCapybara.Contains('menu-owl-high') -and $pipedCapybara.Contains('menu/cat-5.3') -and $pipedCapybara.Contains('menu-cat-low') -and (-not $pipedCapybara.Contains('__OWL_')) -and (-not $pipedCapybara.Contains('__CAT_'))
    Add-Result -Condition ($pipedFillOk) -CaseName 'piped menu fills the per-subagent placeholders' -FailMessage (($pipedCapybara | Out-String))

    # Case 18: the installer is independent of the caller's working directory.
    if ($PSVersionTable.PSVersion -ge [version]'7.2') {
        $cwdRoot = New-TempRoot
        $anywhere = New-TempRoot
        $result = Invoke-InstallerRun -Arguments (@('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $cwdRoot) + $SubagentFlags) -WorkingDirectory $anywhere
        Add-Result -Condition ($result.ExitCode -eq 0 -and (Test-AllFilesExist -Root $cwdRoot -RelativePaths $RelativeLayout[0..3])) -CaseName 'installer ignores the caller cwd for sources' -FailMessage $result.Output
    }
    else {
        Write-Output 'SKIP [installer ignores the caller cwd]: pwsh lacks -WorkingDirectory'
    }

    # Case 19: -UserRoot combined with the repo level fails clearly.
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'all', '-Level', 'repo', '-ProjectRoot', (New-TempRoot), '-UserRoot', (New-TempRoot))
    Add-Result -Condition ($result.ExitCode -eq 1 -and $result.Output.Contains('UserRoot applies only')) -CaseName 'repo level with -UserRoot fails' -FailMessage $result.Output

    # Case 20: the piped menu cancels on EOF because Proceed defaults to No.
    $menuRun = Invoke-PipedMenuRun -Answers @('1', '1', '1', 'menu/owl-5.3', 'menu-owl-high', 'menu/cat-5.3', 'menu-cat-low')
    Add-Result -Condition ($menuRun.ExitCode -eq 0 -and $menuRun.Output.Contains('Cancelled. No changes were made.')) -CaseName 'piped menu cancels when Proceed is unanswered' -FailMessage $menuRun.Output

    # Case 21: an agents-only uninstall removes the agents and no folders.
    $agentsUninstallRoot = New-TempRoot
    $null = Invoke-InstallerRun -Arguments (@('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $agentsUninstallRoot) + $SubagentFlags)
    $result = Invoke-InstallerRun -Arguments @('-Action', 'uninstall', '-Components', 'agents', '-Level', 'user', '-UserRoot', $agentsUninstallRoot)
    Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains('Done: 4 removed, 0 absent, 0 leftover(s) reported.')) -CaseName 'agents-only uninstall summary' -FailMessage $result.Output
    Add-Result -Condition (-not (Test-Path -LiteralPath (Join-Path $agentsUninstallRoot 'agents/Capybara.agent.md'))) -CaseName 'agents-only uninstall removes agents' -FailMessage 'agent survived'
    Add-Result -Condition (Test-Path -LiteralPath (Join-Path $agentsUninstallRoot 'agents') -PathType Container) -CaseName 'agents-only uninstall keeps the agents root' -FailMessage 'root folder was removed'

    # Case 22: several selected components install together via a comma list;
    # separate values fail fast at the host.
    $multiRootSeparate = New-TempRoot
    $result = Invoke-InstallerRun -Arguments (@('-Action', 'install', '-Components', 'agents,skills', '-Level', 'user', '-UserRoot', $multiRootSeparate) + $SubagentFlags)
    Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains('Components: agents, skills') -and $result.Output.Contains('Done: 8 copied, 0 overwritten.')) -CaseName 'multi component install summary' -FailMessage $result.Output
    Add-Result -Condition (Test-AllFilesExist -Root $multiRootSeparate -RelativePaths $RelativeLayout[0..7]) -CaseName 'multi component install file set' -FailMessage 'agent or skill files are missing'
    Add-Result -Condition (-not (Test-Path -LiteralPath (Join-Path $multiRootSeparate 'hooks/guard-pwsh-continuation.json'))) -CaseName 'multi component install skips hooks' -FailMessage 'hook was installed'
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'agents', 'skills', '-Level', 'user', '-UserRoot', $multiRootSeparate)
    Add-Result -Condition ($result.ExitCode -eq 1) -CaseName 'separate values fail fast at the host' -FailMessage "exit $($result.ExitCode)"

    # Case 23: duplicate component values collapse to one set.
    $dedupeRoot = New-TempRoot
    $result = Invoke-InstallerRun -Arguments (@('-Action', 'install', '-Components', 'agents,agents,skills', '-Level', 'user', '-UserRoot', $dedupeRoot) + $SubagentFlags)
    Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains('Done: 8 copied, 0 overwritten.')) -CaseName 'duplicate components deduplicate' -FailMessage $result.Output

    # Case 24: -Components all cannot be combined with named components.
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'all,agents', '-Level', 'user', '-UserRoot', (New-TempRoot))
    Add-Result -Condition ($result.ExitCode -eq 1 -and $result.Output.Contains('cannot be combined')) -CaseName 'all plus named components fails' -FailMessage $result.Output

    # Case 25: an unknown component name fails clearly.
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'agents,mystery', '-Level', 'user', '-UserRoot', (New-TempRoot))
    Add-Result -Condition ($result.ExitCode -eq 1 -and $result.Output.Contains("Unknown component 'mystery'")) -CaseName 'unknown component fails' -FailMessage $result.Output

    # Case 26: uninstall removes every selected component in one run.
    $multiUninstallRoot = New-TempRoot
    $null = Invoke-InstallerRun -Arguments (@('-Action', 'install', '-Components', 'agents,skills', '-Level', 'user', '-UserRoot', $multiUninstallRoot) + $SubagentFlags)
    $result = Invoke-InstallerRun -Arguments @('-Action', 'uninstall', '-Components', 'agents,skills', '-Level', 'user', '-UserRoot', $multiUninstallRoot)
    Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains('Done: 8 removed, 0 absent, 0 leftover(s) reported.')) -CaseName 'multi component uninstall summary' -FailMessage $result.Output
    Add-Result -Condition ((Get-InstalledFileCount -Root (Join-Path $multiUninstallRoot 'skills')) -eq 0) -CaseName 'multi component uninstall empties skills' -FailMessage 'skill files survived'

    # Case 27: the menu accepts a multi-select component answer.
    $menuMultiProject = New-TempRoot
    $multiMenuRun = Invoke-PipedMenuRun -Answers @('1', '2,3', '2', $menuMultiProject, 'menu/owl-5.3', 'menu-owl-high', 'menu/cat-5.3', 'menu-cat-low', '1')
    Add-Result -Condition ($multiMenuRun.ExitCode -eq 0) -CaseName 'piped menu multi-select exits 0' -FailMessage $multiMenuRun.Output
    $repoMultiLayout = $RelativeLayout[0..7] | ForEach-Object { '.github/' + $_ }
    Add-Result -Condition (Test-AllFilesExist -Root $menuMultiProject -RelativePaths $repoMultiLayout) -CaseName 'piped menu multi-select file set' -FailMessage 'expected files are missing'
    Add-Result -Condition (-not (Test-Path -LiteralPath (Join-Path $menuMultiProject '.github/hooks/guard-pwsh-continuation.json'))) -CaseName 'piped menu multi-select skips hooks' -FailMessage 'hook was installed'

    # Case 28: a comma-only menu answer re-prompts without consuming the next answer.
    $commaPromptProject = New-TempRoot
    $commaPromptRun = Invoke-PipedMenuRun -Answers @('1', ',', '2,3', '2', $commaPromptProject, 'menu/owl-5.3', 'menu-owl-high', 'menu/cat-5.3', 'menu-cat-low', '1')
    Add-Result -Condition ($commaPromptRun.ExitCode -eq 0) -CaseName 'comma-only menu answer re-prompts cleanly' -FailMessage $commaPromptRun.Output
    Add-Result -Condition ($commaPromptRun.Output.Contains('Components: agents, skills')) -CaseName 'comma-only answer recovers to the selection' -FailMessage $commaPromptRun.Output
    Add-Result -Condition (Test-Path -LiteralPath (Join-Path $commaPromptProject '.github/agents/Capybara.agent.md') -PathType Leaf) -CaseName 'prompted answer still installs' -FailMessage 'agent was not installed'

    # Case 29: a scripted agents install without the subagent flags fails
    # before writing anything.
    $noFlagsRoot = New-TempRoot
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $noFlagsRoot)
    Add-Result -Condition ($result.ExitCode -eq 1 -and (ConvertTo-ComparableOutput $result.Output).Contains('requires -OwlModel')) -CaseName 'agents install without subagent flags fails' -FailMessage $result.Output
    Add-Result -Condition ((Get-InstalledFileCount -Root $noFlagsRoot) -eq 0) -CaseName 'agents install without subagent flags writes nothing' -FailMessage 'files were created'

    # Case 30: the installer fills the placeholders and the agent files keep
    # no model or target frontmatter. Reuses case 1's user-level install.
    $capybaraInstalled = Get-Content -LiteralPath (Join-Path $userRoot 'agents/Capybara.agent.md') -Raw
    $duoInstalled = Get-Content -LiteralPath (Join-Path $userRoot 'agents/CapybaraDuo.agent.md') -Raw
    $owlInstalled = Get-Content -LiteralPath (Join-Path $userRoot 'agents/Owl.agent.md') -Raw
    $catInstalled = Get-Content -LiteralPath (Join-Path $userRoot 'agents/Cat.agent.md') -Raw
    Add-Result -Condition ($capybaraInstalled.Contains('piped/GLM 5.3') -and $capybaraInstalled.Contains('piped-owl-high') -and $capybaraInstalled.Contains('piped/cat-flash') -and $capybaraInstalled.Contains('piped-cat-low')) -CaseName 'installer fills the Capybara placeholders' -FailMessage $capybaraInstalled
    $duoFillOk = $duoInstalled.Contains('piped/GLM 5.3') -and $duoInstalled.Contains('piped-owl-high') -and (-not $duoInstalled.Contains('piped/cat-flash')) -and (-not $duoInstalled.Contains('piped-cat-low'))
    Add-Result -Condition ($duoFillOk) -CaseName 'installer fills the Capybara Duo placeholders with Owl values only' -FailMessage $duoInstalled
    $placeholderLeak = $capybaraInstalled.Contains('__OWL_') -or $capybaraInstalled.Contains('__CAT_') -or $duoInstalled.Contains('__OWL_') -or $duoInstalled.Contains('__CAT_')
    Add-Result -Condition (-not $placeholderLeak) -CaseName 'installed agent files have no placeholders' -FailMessage 'a leftover placeholder survived'
    $staleFrontmatter = @()
    foreach ($installedAgentText in $capybaraInstalled, $duoInstalled, $owlInstalled, $catInstalled) {
        foreach ($line in ($installedAgentText -split "`r?`n")) {
            if ($line -match '^(model|target):') {
                $staleFrontmatter += $line
            }
        }
    }
    Add-Result -Condition ($staleFrontmatter.Count -eq 0) -CaseName 'installed agent files carry no model or target frontmatter' -FailMessage (($staleFrontmatter | Out-String))

    # Case 31: the subagent flags fail fast outside an agents install.
    $skillsOnlyRoot = New-TempRoot
    $result = Invoke-InstallerRun -Arguments (@('-Action', 'install', '-Components', 'skills', '-Level', 'user', '-UserRoot', $skillsOnlyRoot) + $SubagentFlags)
    Add-Result -Condition ($result.ExitCode -eq 1 -and (ConvertTo-ComparableOutput $result.Output).Contains('apply only when installing the agents component')) -CaseName 'subagent flags fail on a skills-only install' -FailMessage $result.Output
    $result = Invoke-InstallerRun -Arguments (@('-Action', 'uninstall', '-Components', 'agents', '-Level', 'user', '-UserRoot', (New-TempRoot)) + $SubagentFlags)
    Add-Result -Condition ($result.ExitCode -eq 1 -and (ConvertTo-ComparableOutput $result.Output).Contains('apply only when installing the agents component')) -CaseName 'subagent flags fail on an uninstall run' -FailMessage $result.Output

    # Case 32: an agents template missing its placeholder aborts the run.
    $agentTemplateRoot = New-TempRoot
    foreach ($repoFolder in 'agents', 'skills', 'hooks', 'scripts') {
        Copy-Item -LiteralPath (Join-Path $ScriptRoot $repoFolder) -Destination (Join-Path $agentTemplateRoot $repoFolder) -Recurse
    }
    Copy-Item -LiteralPath $Installer -Destination $agentTemplateRoot
    $mutatedAgentPath = Join-Path $agentTemplateRoot 'agents/Capybara.agent.md'
    (Get-Content -LiteralPath $mutatedAgentPath -Raw).Replace('__OWL_MODEL__', '') |
        Set-Content -LiteralPath $mutatedAgentPath -NoNewline
    $abortedAgentRoot = New-TempRoot
    $result = Invoke-InstallerRun -ExecutablePath (Join-Path $agentTemplateRoot 'install.ps1') -Arguments (@('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $abortedAgentRoot) + $SubagentFlags)
    Add-Result -Condition ($result.ExitCode -eq 1 -and (ConvertTo-ComparableOutput $result.Output).Contains('does not contain the expected placeholder')) -CaseName 'agents template without the placeholder aborts' -FailMessage $result.Output
    Add-Result -Condition ((Get-InstalledFileCount -Root $abortedAgentRoot) -eq 0) -CaseName 'agents template without the placeholder writes nothing' -FailMessage 'files were created'

    # Case 33: piped input that ends at a subagent prompt fails fast and
    # writes nothing.
    $eofPromptProject = New-TempRoot
    $eofMenuRun = Invoke-PipedMenuRun -Answers @('1', '1', '2', $eofPromptProject)
    Add-Result -Condition ($eofMenuRun.ExitCode -eq 1 -and (ConvertTo-ComparableOutput $eofMenuRun.Output).Contains('No valid value was entered.')) -CaseName 'piped menu EOF at a prompt fails fast' -FailMessage $eofMenuRun.Output
    Add-Result -Condition ((Get-InstalledFileCount -Root $eofPromptProject) -eq 0) -CaseName 'piped menu EOF at a prompt writes nothing' -FailMessage 'files were created'

    # Case 34: an empty answer at a subagent prompt re-prompts, and the next
    # piped value is used.
    $retryProject = New-TempRoot
    $retryRun = Invoke-PipedMenuRun -Answers @('1', '1', '2', $retryProject, '', 'menu/owl-5.3', 'menu-owl-high', 'menu/cat-5.3', 'menu-cat-low', '1')
    Add-Result -Condition ($retryRun.ExitCode -eq 0 -and $retryRun.Output.Contains('Please enter a non-empty value.')) -CaseName 'empty prompt answer re-prompts and exits 0' -FailMessage $retryRun.Output
    $retryCapybara = Get-Content -LiteralPath (Join-Path $retryProject '.github/agents/Capybara.agent.md') -Raw
    $retryFillOk = $retryCapybara.Contains('menu/owl-5.3') -and $retryCapybara.Contains('menu-owl-high') -and $retryCapybara.Contains('menu/cat-5.3') -and $retryCapybara.Contains('menu-cat-low') -and (-not $retryCapybara.Contains('__OWL_')) -and (-not $retryCapybara.Contains('__CAT_'))
    Add-Result -Condition ($retryFillOk) -CaseName 'empty prompt answer uses the next piped value' -FailMessage $retryCapybara

    # Case 35: a user-level piped menu install lands in the sandbox profile.
    $userMenuRun = Invoke-PipedMenuRun -Answers @('1', '1', '1', 'menu/owl-5.3', 'menu-owl-high', 'menu/cat-5.3', 'menu-cat-low', '1')
    Add-Result -Condition ($userMenuRun.ExitCode -eq 0) -CaseName 'user-level piped menu install exits 0' -FailMessage $userMenuRun.Output
    $sandboxCapybara = Get-Content -LiteralPath (Join-Path $userMenuRun.UserProfile '.copilot/agents/Capybara.agent.md') -Raw
    $sandboxFillOk = $sandboxCapybara.Contains('menu/owl-5.3') -and $sandboxCapybara.Contains('menu/cat-5.3') -and (-not $sandboxCapybara.Contains('__OWL_')) -and (-not $sandboxCapybara.Contains('__CAT_'))
    Add-Result -Condition ($sandboxFillOk) -CaseName 'user-level piped menu install lands in the sandbox' -FailMessage $sandboxCapybara

    # Case 36: a Cat token that leaks into the Duo template aborts the rewrite,
    # because a Cat value has no meaning in Duo mode.
    $duoTemplateRoot = New-TempRoot
    foreach ($repoFolder in 'agents', 'skills', 'hooks', 'scripts') {
        Copy-Item -LiteralPath (Join-Path $ScriptRoot $repoFolder) -Destination (Join-Path $duoTemplateRoot $repoFolder) -Recurse
    }
    Copy-Item -LiteralPath $Installer -Destination $duoTemplateRoot
    $mutatedDuoPath = Join-Path $duoTemplateRoot 'agents/CapybaraDuo.agent.md'
    Add-Content -LiteralPath $mutatedDuoPath -Value "`n`nLeaked: __CAT_MODEL__"
    $abortedDuoRoot = New-TempRoot
    $result = Invoke-InstallerRun -ExecutablePath (Join-Path $duoTemplateRoot 'install.ps1') -Arguments (@('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $abortedDuoRoot) + $SubagentFlags)
    Add-Result -Condition ($result.ExitCode -eq 1 -and (ConvertTo-ComparableOutput $result.Output).Contains('still present after rewriting')) -CaseName 'Cat token in the Duo template aborts' -FailMessage $result.Output
    Add-Result -Condition ((Get-InstalledFileCount -Root $abortedDuoRoot) -eq 0) -CaseName 'Cat token in the Duo template writes nothing' -FailMessage 'files were created'

    # Case 37: a partial flag set fails, pinning the all-four-required
    # contract with Owl flags supplied and Cat flags missing.
    $partialFlagsRoot = New-TempRoot
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $partialFlagsRoot, '-OwlModel', 'piped/GLM 5.3', '-OwlReasoningEffort', 'piped-owl-high')
    Add-Result -Condition ($result.ExitCode -eq 1 -and (ConvertTo-ComparableOutput $result.Output).Contains('requires -OwlModel')) -CaseName 'partial subagent flag set fails' -FailMessage $result.Output
    Add-Result -Condition ((Get-InstalledFileCount -Root $partialFlagsRoot) -eq 0) -CaseName 'partial subagent flag set writes nothing' -FailMessage 'files were created'

    # Case 38: a piped menu install whose components exclude agents skips the
    # four subagent questions and installs only the selected component.
    $skillsMenuProject = New-TempRoot
    $skillsMenuRun = Invoke-PipedMenuRun -Answers @('1', '3', '2', $skillsMenuProject, '1')
    Add-Result -Condition ($skillsMenuRun.ExitCode -eq 0 -and (-not $skillsMenuRun.Output.Contains('Which model should Owl run on?'))) -CaseName 'menu without the agents component skips the subagent questions' -FailMessage $skillsMenuRun.Output
    Add-Result -Condition (Test-AllFilesExist -Root $skillsMenuProject -RelativePaths ($RelativeLayout[4..7] | ForEach-Object { '.github/' + $_ })) -CaseName 'skills-only menu install file set' -FailMessage 'skill files are missing'
    Add-Result -Condition (-not (Test-Path -LiteralPath (Join-Path $skillsMenuProject '.github/agents/Capybara.agent.md'))) -CaseName 'skills-only menu install skips agents' -FailMessage 'agent was installed'
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