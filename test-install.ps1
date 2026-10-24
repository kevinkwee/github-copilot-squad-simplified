#requires -Version 7
<#
    Out-of-process test battery for install.ps1. Each case builds disposable
    temp roots and runs the installer (or uninstaller) as a child process with
    flags, or through piped menu answers inside a disposable user profile, so
    the real $HOME\.copilot and any real project are never touched. Every
    child run also points git's global config and home folder at a
    disposable sandbox, disables git's system config, and either points
    XDG_CONFIG_HOME at the sandbox or unsets it, so the real git config and
    the real global excludes file are never read or written.
    Results are asserted on the resulting file tree, the rewritten hook JSON
    and agent templates, the installed agent and skill frontmatter, the
    sandboxed git excludes file, exit codes, and the reported summary lines.

    Must run under pwsh 7 like the guard battery, with git 2.32 or newer on
    PATH because older git ignores the GIT_CONFIG_GLOBAL redirect; cases 15
    and 80 additionally cover Windows PowerShell 5.1 by launching
    powershell.exe when it exists.

    Run with:
      pwsh -NoProfile -File test-install.ps1
    Exits with code 1 if any case fails and prints a per-case PASS/FAIL line.
#>

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Installer = Join-Path $ScriptRoot 'install.ps1'
$SubagentFlags = @(
    '-OwlModel', 'piped/GLM 5.3',
    '-OwlReasoningEffort', 'high',
    '-CatModel', 'piped/cat-flash',
    '-CatReasoningEffort', 'low'
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
    'skills/gh-multi-account/SKILL.md',
    'skills/merge-strategy/SKILL.md',
    'skills/pr-description/SKILL.md',
    'hooks/guard-pwsh-continuation.json',
    'scripts/guard-pwsh-continuation/guard-pwsh-continuation.ps1',
    'scripts/guard-pwsh-continuation/test-guard-pwsh-continuation.ps1',
    'hooks/guard-subagent-delegation.json',
    'scripts/guard-subagent-delegation/guard-subagent-delegation.ps1',
    'scripts/guard-subagent-delegation/test-guard-subagent-delegation.ps1'
)
$SubagentGuardLayout = $RelativeLayout[13..15]
$TempReportsPattern = '**/.github/temp_reports/'
$TempReportsMarker = '# Copilot Squad agent reports (managed by the squad install.ps1)'
$GitSandboxVariableNames = 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM', 'XDG_CONFIG_HOME', 'HOME'
$MinimumGitVersion = [version]'2.32'

function New-TempRoot {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('capy-install-' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -Path $path -ItemType Directory -Force | Out-Null
    $script:tempRoots += $path
    return $path
}

# Returns disposable locations for git's global config, git's home folder,
# and git's default excludes file. The Xdg base returns a sandbox
# XDG_CONFIG_HOME. The Home base returns none, so git falls back to its home
# folder, the layout most Windows machines have. Nothing is created up front,
# so a case can assert that a run never wrote the excludes file.
function New-GitSandbox {
    param([ValidateSet('Xdg', 'Home')][string]$DefaultExcludesBase = 'Xdg')
    $root = New-TempRoot
    $homeFolder = Join-Path $root 'home'
    $xdgConfigHome = Join-Path $root 'xdg'
    $defaultExcludesFile = Join-Path (Join-Path $xdgConfigHome 'git') 'ignore'
    if ($DefaultExcludesBase -eq 'Home') {
        $xdgConfigHome = $null
        $defaultExcludesFile = Join-Path (Join-Path (Join-Path $homeFolder '.config') 'git') 'ignore'
    }
    return [pscustomobject]@{
        Root                = $root
        GlobalConfig        = Join-Path $root 'gitconfig'
        HomeFolder          = $homeFolder
        XdgConfigHome       = $xdgConfigHome
        DefaultExcludesFile = $defaultExcludesFile
    }
}

# Runs the script block with git redirected into the sandbox, so neither the
# child installer nor a git probe can reach the real global config or the
# real excludes file. HOME is always sandboxed because git reads it before
# HOMEDRIVE, HOMEPATH, and USERPROFILE.
function Invoke-InGitSandbox {
    param(
        [Parameter(Mandatory)][pscustomobject]$GitSandbox,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    $savedValues = @{}
    foreach ($variableName in $GitSandboxVariableNames) {
        $savedValues[$variableName] = [Environment]::GetEnvironmentVariable($variableName)
    }
    [Environment]::SetEnvironmentVariable('GIT_CONFIG_GLOBAL', $GitSandbox.GlobalConfig)
    [Environment]::SetEnvironmentVariable('GIT_CONFIG_NOSYSTEM', '1')
    [Environment]::SetEnvironmentVariable('XDG_CONFIG_HOME', $GitSandbox.XdgConfigHome)
    [Environment]::SetEnvironmentVariable('HOME', $GitSandbox.HomeFolder)
    try {
        & $ScriptBlock
    }
    finally {
        foreach ($variableName in $GitSandboxVariableNames) {
            [Environment]::SetEnvironmentVariable($variableName, $savedValues[$variableName])
        }
    }
}

function Get-SandboxFileText {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return [System.IO.File]::ReadAllText($Path)
}

function Invoke-InstallerRun {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [ValidateSet('pwsh', 'windows-powershell')][string]$Runtime = 'pwsh',
        [string]$ExecutablePath = '',
        [string]$WorkingDirectory = '',
        [pscustomobject]$GitSandbox
    )
    if (-not $PSBoundParameters.ContainsKey('GitSandbox')) {
        $GitSandbox = New-GitSandbox
    }
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
    Invoke-InGitSandbox -GitSandbox $GitSandbox -ScriptBlock {
        $output = & $command @hostArguments -File $ExecutablePath @Arguments 2>&1
        [pscustomobject]@{
            Output   = ($output | Out-String)
            ExitCode = $LASTEXITCODE
        }
    }
}

# ConciseView wraps long error messages and prefixes continuation lines with a
# `|` gutter, so strip gutters and collapse whitespace before substring checks.
function ConvertTo-ComparableOutput {
    param([string]$Output)
    ($Output -replace '(?m)^\s*\|', '') -replace '\s+', ' '
}

function Invoke-PipedMenuRun {
    param(
        [string[]]$Answers,
        [pscustomobject]$GitSandbox
    )
    if (-not $PSBoundParameters.ContainsKey('GitSandbox')) {
        $GitSandbox = New-GitSandbox
    }
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
        $output = Invoke-InGitSandbox -GitSandbox $GitSandbox -ScriptBlock {
            ($Answers -join "`r`n") | & pwsh -NoProfile -ExecutionPolicy Bypass -File $Installer 2>&1
        }
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

# Returns a prompt file's top-level frontmatter: the key names in file order
# with their casing and any duplicates kept, so a key-set check catches both,
# plus maps of the raw and the unquoted scalar values. The raw map lets a case
# tell a YAML boolean from a quoted string. All are empty when the file lacks
# a fenced frontmatter block. Nested YAML is out of scope because the squad
# files use none.
function Get-Frontmatter {
    param([string]$Text)
    $frontmatter = [pscustomobject]@{ KeyNames = @(); RawValues = [ordered]@{}; Values = [ordered]@{} }
    $lines = $Text -split "`r?`n"
    $closingFenceIndex = [array]::IndexOf($lines, '---', 1)
    if ($lines[0] -ne '---' -or $closingFenceIndex -lt 0) {
        return $frontmatter
    }
    foreach ($line in $lines[1..$closingFenceIndex]) {
        if ($line -notmatch '^([A-Za-z][\w-]*):\s*(.*)$') {
            continue
        }
        $rawValue = $Matches[2].Trim()
        $value = $rawValue
        if ($value.Length -ge 2 -and $value.StartsWith("'") -and $value.EndsWith("'")) {
            $value = $value.Substring(1, $value.Length - 2).Replace("''", "'")
        }
        elseif ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $frontmatter.KeyNames += $Matches[1]
        $frontmatter.RawValues[$Matches[1]] = $rawValue
        $frontmatter.Values[$Matches[1]] = $value
    }
    return $frontmatter
}

function Get-SortedKeyList {
    param([string[]]$KeyNames)
    return (@($KeyNames) | Sort-Object) -join ', '
}

# Older git ignores GIT_CONFIG_GLOBAL, so its child runs would read the real
# global config and could write the real excludes file it names.
$gitVersionText = ''
if (Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue) {
    $gitVersionText = [string](& git --version)
}
if ($gitVersionText -notmatch '(\d+)\.(\d+)' -or [version]"$($Matches[1]).$($Matches[2])" -lt $MinimumGitVersion) {
    Write-Output "FAIL [battery prerequisites]: the installer battery needs git $MinimumGitVersion or newer on PATH, found '$gitVersionText'."
    exit 1
}

try {
    # Case 1: install all to a fresh user-level root.
    $userRoot = New-TempRoot
    $result = Invoke-InstallerRun -Arguments (@('-Action', 'install', '-Components', 'all', '-Level', 'user', '-UserRoot', $userRoot) + $SubagentFlags)
    Add-Result -Condition ($result.ExitCode -eq 0) -CaseName 'install all (user level) exits 0' -FailMessage "exit code $($result.ExitCode)"
    Add-Result -Condition (Test-AllFilesExist -Root $userRoot -RelativePaths $RelativeLayout) -CaseName 'install all (user level) file set' -FailMessage 'expected files are missing'
    Add-Result -Condition ($result.Output.Contains('Done: 16 copied, 0 overwritten.')) -CaseName 'install all (user level) summary' -FailMessage $result.Output

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

    # The subagent delegation hook travels with the agents component (Auto),
    # so case 1's install carries its JSON too, rewritten like the shell
    # guard's but with the guard folder and the 60-second budget.
    $guardJsonPath = Join-Path $userRoot 'hooks/guard-subagent-delegation.json'
    $guardJson = Get-Content -LiteralPath $guardJsonPath -Raw
    $expectedGuardFileArgument = "$profilePrefix/.copilot/scripts/guard-subagent-delegation/guard-subagent-delegation.ps1"
    $guardParsed = $null
    try {
        $guardParsed = $guardJson | ConvertFrom-Json
    }
    catch {
    }
    Add-Result -Condition ($null -ne $guardParsed) -CaseName 'subagent guard JSON parses' -FailMessage 'ConvertFrom-Json failed'
    Add-Result -Condition (-not $guardJson.Contains('C:/Users/YOUR-PROFILE')) -CaseName 'subagent guard JSON has no placeholder' -FailMessage $guardJson
    Add-Result -Condition ($guardJson.Contains($expectedGuardFileArgument)) -CaseName 'subagent guard JSON -File points at the real profile' -FailMessage $guardJson
    Add-Result -Condition ($guardParsed.hooks.PreToolUse[0].timeout -eq 60) -CaseName 'subagent guard JSON keeps the 60-second timeout' -FailMessage $guardJson
    Add-Result -Condition ($guardParsed.hooks.PreToolUse[0].matcher -eq 'Agent') -CaseName 'subagent guard JSON matches the subagent tool' -FailMessage $guardJson
    Add-Result -Condition ($guardParsed.hooks.PreToolUse[0].bash -eq 'exit 0') -CaseName 'subagent guard JSON keeps the bash fallback' -FailMessage $guardJson

    # Case 3: agents only.
    $agentsRoot = New-TempRoot
    $result = Invoke-InstallerRun -Arguments (@('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $agentsRoot) + $SubagentFlags)
    Add-Result -Condition ($result.ExitCode -eq 0) -CaseName 'install agents only exits 0' -FailMessage "exit code $($result.ExitCode)"
    Add-Result -Condition (Test-AllFilesExist -Root $agentsRoot -RelativePaths ($RelativeLayout[0..3] + $SubagentGuardLayout)) -CaseName 'install agents only file set' -FailMessage 'agent or guard files are missing'
    Add-Result -Condition (-not (Test-Path -LiteralPath (Join-Path $agentsRoot 'skills/commit-message/SKILL.md'))) -CaseName 'install agents only skips skills' -FailMessage 'skill was installed'
    Add-Result -Condition (-not (Test-Path -LiteralPath (Join-Path $agentsRoot 'hooks/guard-pwsh-continuation.json'))) -CaseName 'install agents only skips the shell guard hook' -FailMessage 'shell guard hook was installed'
    Add-Result -Condition ($result.Output.Contains('Subagent delegation guard: included')) -CaseName 'install agents only includes the guard' -FailMessage $result.Output

    # Case 4: skills only, including the assets subfolder.
    $skillsRoot = New-TempRoot
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'skills', '-Level', 'user', '-UserRoot', $skillsRoot)
    Add-Result -Condition ($result.ExitCode -eq 0) -CaseName 'install skills only exits 0' -FailMessage "exit code $($result.ExitCode)"
    Add-Result -Condition (Test-AllFilesExist -Root $skillsRoot -RelativePaths $RelativeLayout[4..9]) -CaseName 'install skills only file set incl. assets' -FailMessage 'skill files are missing'
    Add-Result -Condition (Test-Path -LiteralPath (Join-Path $skillsRoot 'skills/gh-multi-account/SKILL.md')) -CaseName 'install skills only includes gh-multi-account' -FailMessage 'gh-multi-account skill file is missing'
    Add-Result -Condition (Test-Path -LiteralPath (Join-Path $skillsRoot 'skills/merge-strategy/SKILL.md')) -CaseName 'install skills only includes merge-strategy' -FailMessage 'merge-strategy skill file is missing'
    Add-Result -Condition (-not (Test-Path -LiteralPath (Join-Path $skillsRoot 'agents/Capybara.agent.md'))) -CaseName 'install skills only skips agents' -FailMessage 'agent was installed'

    # Case 5: hooks only.
    $hooksRoot = New-TempRoot
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'hooks', '-Level', 'user', '-UserRoot', $hooksRoot)
    Add-Result -Condition ($result.ExitCode -eq 0) -CaseName 'install hooks only exits 0' -FailMessage "exit code $($result.ExitCode)"
    Add-Result -Condition (Test-AllFilesExist -Root $hooksRoot -RelativePaths $RelativeLayout[10..12]) -CaseName 'install hooks only file set' -FailMessage 'hook files are missing'
    Add-Result -Condition (-not (Test-Path -LiteralPath (Join-Path $hooksRoot 'agents/Capybara.agent.md'))) -CaseName 'install hooks only skips agents' -FailMessage 'agent was installed'

    # Case 6: a name conflict is overwritten by default.
    $overwriteRoot = New-TempRoot
    $sentinelPath = Join-Path $overwriteRoot 'agents/Capybara.agent.md'
    New-Item -Path (Join-Path $overwriteRoot 'agents') -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath $sentinelPath -Value 'SENTINEL-OLD-CONTENT' -NoNewline
    $result = Invoke-InstallerRun -Arguments (@('-Action', 'install', '-Components', 'all', '-Level', 'user', '-UserRoot', $overwriteRoot) + $SubagentFlags)
    Add-Result -Condition ($result.ExitCode -eq 0) -CaseName 'conflicting install exits 0' -FailMessage "exit code $($result.ExitCode)"
    Add-Result -Condition (((Get-Content -LiteralPath $sentinelPath -Raw).TrimEnd()) -ne 'SENTINEL-OLD-CONTENT') -CaseName 'conflicting install overwrites the file' -FailMessage 'sentinel content survived'
    Add-Result -Condition ($result.Output.Contains('Done: 15 copied, 1 overwritten.')) -CaseName 'conflicting install reports overwrite' -FailMessage $result.Output

    # Case 7: re-running the install is idempotent.
    $result = Invoke-InstallerRun -Arguments (@('-Action', 'install', '-Components', 'all', '-Level', 'user', '-UserRoot', $overwriteRoot) + $SubagentFlags)
    Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains('Done: 0 copied, 16 overwritten.')) -CaseName 're-run reports 16 overwritten' -FailMessage $result.Output

    # Case 8: repo-level install into an existing project folder.
    $repoProject = New-TempRoot
    $result = Invoke-InstallerRun -Arguments (@('-Action', 'install', '-Components', 'all', '-Level', 'repo', '-ProjectRoot', $repoProject) + $SubagentFlags)
    Add-Result -Condition ($result.ExitCode -eq 0) -CaseName 'repo-level install exits 0' -FailMessage "exit code $($result.ExitCode)"
    Add-Result -Condition (Test-AllFilesExist -Root $repoProject -RelativePaths ($RelativeLayout | ForEach-Object { '.github/' + $_ })) -CaseName 'repo-level install file set under .github' -FailMessage 'expected files are missing'
    $repoJsonPath = Join-Path $repoProject '.github/hooks/guard-pwsh-continuation.json'
    $repoJson = Get-Content -LiteralPath $repoJsonPath -Raw
    Add-Result -Condition ($repoJson.Contains('.github/scripts/guard-pwsh-continuation/guard-pwsh-continuation.ps1')) -CaseName 'repo-level hook JSON is repo-relative' -FailMessage $repoJson
    Add-Result -Condition (-not $repoJson.Contains('C:/Users/YOUR-PROFILE')) -CaseName 'repo-level hook JSON has no placeholder' -FailMessage $repoJson
    $repoGuardJsonPath = Join-Path $repoProject '.github/hooks/guard-subagent-delegation.json'
    $repoGuardJson = Get-Content -LiteralPath $repoGuardJsonPath -Raw
    Add-Result -Condition ($repoGuardJson.Contains('.github/scripts/guard-subagent-delegation/guard-subagent-delegation.ps1')) -CaseName 'repo-level guard JSON is repo-relative' -FailMessage $repoGuardJson
    Add-Result -Condition (-not $repoGuardJson.Contains('C:/Users/YOUR-PROFILE')) -CaseName 'repo-level guard JSON has no placeholder' -FailMessage $repoGuardJson

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
    Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains('Done: 16 removed, 0 absent, 0 leftover(s) reported.')) -CaseName 'uninstall all summary' -FailMessage $result.Output
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
    Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains('Done: 6 removed, 0 absent, 0 leftover(s) reported.')) -CaseName 'repo uninstall of hooks summary' -FailMessage $result.Output
    Add-Result -Condition (-not (Test-Path -LiteralPath (Join-Path $repoUninstallProject '.github/hooks/guard-pwsh-continuation.json'))) -CaseName 'repo uninstall removes hook JSON' -FailMessage 'hook JSON survived'
    Add-Result -Condition (-not (Test-Path -LiteralPath (Join-Path $repoUninstallProject '.github/scripts/guard-pwsh-continuation'))) -CaseName 'repo uninstall removes script folder' -FailMessage 'script folder survived'
    Add-Result -Condition (-not (Test-Path -LiteralPath (Join-Path $repoUninstallProject '.github/hooks/guard-subagent-delegation.json'))) -CaseName 'repo uninstall of hooks removes the guard JSON' -FailMessage 'guard JSON survived'
    Add-Result -Condition (-not (Test-Path -LiteralPath (Join-Path $repoUninstallProject '.github/scripts/guard-subagent-delegation'))) -CaseName 'repo uninstall of hooks removes the guard script folder' -FailMessage 'guard script folder survived'
    Add-Result -Condition (Test-Path -LiteralPath (Join-Path $repoUninstallProject '.github/agents/Capybara.agent.md') -PathType Leaf) -CaseName 'repo uninstall keeps agents' -FailMessage 'agent was removed'
    Add-Result -Condition (Test-Path -LiteralPath $unrelatedSkillNote -PathType Leaf) -CaseName 'repo uninstall keeps unrelated files' -FailMessage 'extra file was removed'

    # Case 13: leftovers from a manual rename are reported, not deleted.
    $leftoverRoot = New-TempRoot
    $null = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'hooks', '-Level', 'user', '-UserRoot', $leftoverRoot)
    $leftoverHook = Join-Path $leftoverRoot 'hooks/guard-pwsh-continuation.json.old.disabled'
    $leftoverScript = Join-Path $leftoverRoot 'scripts/guard-pwsh-continuation.old.disabled'
    $leftoverGuardHook = Join-Path $leftoverRoot 'hooks/guard-subagent-delegation.json.old.disabled'
    Set-Content -LiteralPath $leftoverHook -Value 'OLD' -NoNewline
    Set-Content -LiteralPath $leftoverScript -Value 'OLD' -NoNewline
    Set-Content -LiteralPath $leftoverGuardHook -Value 'OLD' -NoNewline
    $result = Invoke-InstallerRun -Arguments @('-Action', 'uninstall', '-Components', 'hooks', '-Level', 'user', '-UserRoot', $leftoverRoot)
    $disabledSurvives = (Test-Path -LiteralPath $leftoverHook -PathType Leaf) -and
        (Test-Path -LiteralPath $leftoverScript -PathType Leaf) -and
        (Test-Path -LiteralPath $leftoverGuardHook -PathType Leaf)
    Add-Result -Condition ($disabledSurvives) -CaseName 'leftover .disabled files survive uninstall' -FailMessage 'leftover was deleted'
    Add-Result -Condition ($result.Output.Contains('leftover(s) reported.') -and
        $result.Output.Contains('guard-pwsh-continuation.json.old.disabled') -and
        $result.Output.Contains('guard-subagent-delegation.json.old.disabled')) -CaseName 'leftover files are listed for manual review' -FailMessage $result.Output

    # Case 14: -WhatIf prints the plan and changes nothing.
    $whatIfRoot = New-TempRoot
    $result = Invoke-InstallerRun -Arguments (@('-Action', 'install', '-Components', 'all', '-Level', 'user', '-UserRoot', $whatIfRoot, '-WhatIf') + $SubagentFlags)
    Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains('planned (copied)') -and $result.Output.Contains('What-if run finished. No changes were made.')) -CaseName 'WhatIf prints a plan' -FailMessage $result.Output
    Add-Result -Condition ((Get-InstalledFileCount -Root $whatIfRoot) -eq 0) -CaseName 'WhatIf writes nothing' -FailMessage 'files were created'

    # Case 15: install and uninstall under Windows PowerShell 5.1. The git
    # sandbox leaves XDG_CONFIG_HOME unset, so the excludes entry follows
    # git's home-folder default.
    if (Get-Command powershell.exe -ErrorAction SilentlyContinue) {
        $ps51Root = New-TempRoot
        $ps51GitSandbox = New-GitSandbox -DefaultExcludesBase Home
        $result = Invoke-InstallerRun -Runtime windows-powershell -GitSandbox $ps51GitSandbox -Arguments (@('-Action', 'install', '-Components', 'all', '-Level', 'user', '-UserRoot', $ps51Root) + $SubagentFlags)
        Add-Result -Condition ($result.ExitCode -eq 0) -CaseName 'installer under Windows PowerShell 5.1 exits 0' -FailMessage $result.Output
        Add-Result -Condition (Test-AllFilesExist -Root $ps51Root -RelativePaths $RelativeLayout) -CaseName 'installer under Windows PowerShell 5.1 file set' -FailMessage 'expected files are missing'
        $ps51Excludes = Get-SandboxFileText -Path $ps51GitSandbox.DefaultExcludesFile
        Add-Result -Condition ($ps51Excludes -ceq ($TempReportsMarker + "`n" + $TempReportsPattern + "`n")) -CaseName 'installer under Windows PowerShell 5.1 adds the temp reports exclude' -FailMessage "excludes file: '$ps51Excludes'"
        $ps51Json = Get-Content -LiteralPath (Join-Path $ps51Root 'hooks/guard-pwsh-continuation.json') -Raw
        Add-Result -Condition ($ps51Json.Contains($expectedFileArgument)) -CaseName 'installer under Windows PowerShell 5.1 rewrites the hook path' -FailMessage $ps51Json
        $ps51GuardJson = Get-Content -LiteralPath (Join-Path $ps51Root 'hooks/guard-subagent-delegation.json') -Raw
        Add-Result -Condition ($ps51GuardJson.Contains($expectedGuardFileArgument)) -CaseName 'installer under Windows PowerShell 5.1 rewrites the guard path' -FailMessage $ps51GuardJson
        New-Item -Path (Join-Path $ps51Root 'agents') -ItemType Directory -Force | Out-Null
        $unrelated51 = Join-Path $ps51Root 'agents/MyOwn51.agent.md'
        Set-Content -LiteralPath $unrelated51 -Value 'KEEP ME' -NoNewline
        $result = Invoke-InstallerRun -Runtime windows-powershell -GitSandbox $ps51GitSandbox -Arguments @('-Action', 'uninstall', '-Components', 'all', '-Level', 'user', '-UserRoot', $ps51Root)
        Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains('Done: 16 removed, 0 absent, 0 leftover(s) reported.')) -CaseName 'uninstaller under Windows PowerShell 5.1 removes squad files' -FailMessage $result.Output
        Add-Result -Condition (Test-Path -LiteralPath $unrelated51 -PathType Leaf) -CaseName 'uninstaller under Windows PowerShell 5.1 keeps unrelated files' -FailMessage 'unrelated agent was removed'
        $ps51ExcludesAfter = Get-SandboxFileText -Path $ps51GitSandbox.DefaultExcludesFile
        Add-Result -Condition ($ps51ExcludesAfter -ceq '') -CaseName 'uninstaller under Windows PowerShell 5.1 removes the temp reports exclude' -FailMessage "excludes file: '$ps51ExcludesAfter'"
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
    $menuRun = Invoke-PipedMenuRun -Answers @('1', '1', '2', $menuProject, 'menu/owl-5.3', '5', 'menu/cat-5.3', '3', '1', '1')
    Add-Result -Condition ($menuRun.ExitCode -eq 0) -CaseName 'piped menu install exits 0' -FailMessage $menuRun.Output
    Add-Result -Condition (Test-AllFilesExist -Root $menuProject -RelativePaths ($RelativeLayout | ForEach-Object { '.github/' + $_ })) -CaseName 'piped menu install file set' -FailMessage 'expected files are missing'
    $pipedCapybara = Get-Content -LiteralPath (Join-Path $menuProject '.github/agents/Capybara.agent.md') -Raw
    $pipedFillOk = $pipedCapybara.Contains('menu/owl-5.3') -and $pipedCapybara.Contains('reasoning effort set to `high`') -and $pipedCapybara.Contains('menu/cat-5.3') -and $pipedCapybara.Contains('reasoning effort set to `low`') -and (-not $pipedCapybara.Contains('__OWL_')) -and (-not $pipedCapybara.Contains('__CAT_'))
    Add-Result -Condition ($pipedFillOk) -CaseName 'piped menu fills the per-subagent placeholders' -FailMessage (($pipedCapybara | Out-String))

    # Case 18: the installer is independent of the caller's working directory.
    if ($PSVersionTable.PSVersion -ge [version]'7.2') {
        $cwdRoot = New-TempRoot
        $anywhere = New-TempRoot
        $result = Invoke-InstallerRun -Arguments (@('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $cwdRoot) + $SubagentFlags) -WorkingDirectory $anywhere
        Add-Result -Condition ($result.ExitCode -eq 0 -and (Test-AllFilesExist -Root $cwdRoot -RelativePaths ($RelativeLayout[0..3] + $SubagentGuardLayout))) -CaseName 'installer ignores the caller cwd for sources' -FailMessage $result.Output
    }
    else {
        Write-Output 'SKIP [installer ignores the caller cwd]: pwsh lacks -WorkingDirectory'
    }

    # Case 19: -UserRoot combined with the repo level fails clearly.
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'all', '-Level', 'repo', '-ProjectRoot', (New-TempRoot), '-UserRoot', (New-TempRoot))
    Add-Result -Condition ($result.ExitCode -eq 1 -and $result.Output.Contains('UserRoot applies only')) -CaseName 'repo level with -UserRoot fails' -FailMessage $result.Output

    # Case 20: the piped menu cancels on EOF because Proceed defaults to No.
    $menuRun = Invoke-PipedMenuRun -Answers @('1', '1', '1', 'menu/owl-5.3', '5', 'menu/cat-5.3', '3', '1')
    Add-Result -Condition ($menuRun.ExitCode -eq 0 -and $menuRun.Output.Contains('Cancelled. No changes were made.')) -CaseName 'piped menu cancels when Proceed is unanswered' -FailMessage $menuRun.Output

    # Case 21: an agents-only uninstall removes the agents and the guard that
    # traveled with them.
    $agentsUninstallRoot = New-TempRoot
    $null = Invoke-InstallerRun -Arguments (@('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $agentsUninstallRoot) + $SubagentFlags)
    $result = Invoke-InstallerRun -Arguments @('-Action', 'uninstall', '-Components', 'agents', '-Level', 'user', '-UserRoot', $agentsUninstallRoot)
    Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains('Done: 7 removed, 0 absent, 0 leftover(s) reported.')) -CaseName 'agents-only uninstall summary' -FailMessage $result.Output
    Add-Result -Condition (-not (Test-Path -LiteralPath (Join-Path $agentsUninstallRoot 'agents/Capybara.agent.md'))) -CaseName 'agents-only uninstall removes agents' -FailMessage 'agent survived'
    Add-Result -Condition (-not (Test-Path -LiteralPath (Join-Path $agentsUninstallRoot 'hooks/guard-subagent-delegation.json'))) -CaseName 'agents-only uninstall removes the guard hook' -FailMessage 'guard hook survived'
    Add-Result -Condition (Test-Path -LiteralPath (Join-Path $agentsUninstallRoot 'agents') -PathType Container) -CaseName 'agents-only uninstall keeps the agents root' -FailMessage 'root folder was removed'

    # Case 22: several selected components install together via a comma list;
    # separate values fail fast at the host.
    $multiRootSeparate = New-TempRoot
    $result = Invoke-InstallerRun -Arguments (@('-Action', 'install', '-Components', 'agents,skills', '-Level', 'user', '-UserRoot', $multiRootSeparate) + $SubagentFlags)
    Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains('Components: agents, skills') -and $result.Output.Contains('Done: 13 copied, 0 overwritten.')) -CaseName 'multi component install summary' -FailMessage $result.Output
    Add-Result -Condition (Test-AllFilesExist -Root $multiRootSeparate -RelativePaths $RelativeLayout[0..9]) -CaseName 'multi component install file set' -FailMessage 'agent or skill files are missing'
    Add-Result -Condition (-not (Test-Path -LiteralPath (Join-Path $multiRootSeparate 'hooks/guard-pwsh-continuation.json'))) -CaseName 'multi component install skips hooks' -FailMessage 'hook was installed'
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'agents', 'skills', '-Level', 'user', '-UserRoot', $multiRootSeparate)
    Add-Result -Condition ($result.ExitCode -eq 1) -CaseName 'separate values fail fast at the host' -FailMessage "exit $($result.ExitCode)"

    # Case 23: duplicate component values collapse to one set.
    $dedupeRoot = New-TempRoot
    $result = Invoke-InstallerRun -Arguments (@('-Action', 'install', '-Components', 'agents,agents,skills', '-Level', 'user', '-UserRoot', $dedupeRoot) + $SubagentFlags)
    Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains('Done: 13 copied, 0 overwritten.')) -CaseName 'duplicate components deduplicate' -FailMessage $result.Output

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
    Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains('Done: 13 removed, 0 absent, 0 leftover(s) reported.')) -CaseName 'multi component uninstall summary' -FailMessage $result.Output
    Add-Result -Condition ((Get-InstalledFileCount -Root (Join-Path $multiUninstallRoot 'skills')) -eq 0) -CaseName 'multi component uninstall empties skills' -FailMessage 'skill files survived'

    # Case 27: the menu accepts a multi-select component answer.
    $menuMultiProject = New-TempRoot
    $multiMenuRun = Invoke-PipedMenuRun -Answers @('1', '2,3', '2', $menuMultiProject, 'menu/owl-5.3', '5', 'menu/cat-5.3', '3', '1', '1')
    Add-Result -Condition ($multiMenuRun.ExitCode -eq 0) -CaseName 'piped menu multi-select exits 0' -FailMessage $multiMenuRun.Output
    $repoMultiLayout = $RelativeLayout[0..9] | ForEach-Object { '.github/' + $_ }
    Add-Result -Condition (Test-AllFilesExist -Root $menuMultiProject -RelativePaths $repoMultiLayout) -CaseName 'piped menu multi-select file set' -FailMessage 'expected files are missing'
    Add-Result -Condition (-not (Test-Path -LiteralPath (Join-Path $menuMultiProject '.github/hooks/guard-pwsh-continuation.json'))) -CaseName 'piped menu multi-select skips hooks' -FailMessage 'hook was installed'

    # Case 28: a comma-only menu answer re-prompts without consuming the next answer.
    $commaPromptProject = New-TempRoot
    $commaPromptRun = Invoke-PipedMenuRun -Answers @('1', ',', '2,3', '2', $commaPromptProject, 'menu/owl-5.3', '5', 'menu/cat-5.3', '3', '1', '1')
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
    Add-Result -Condition ($capybaraInstalled.Contains('piped/GLM 5.3') -and $capybaraInstalled.Contains('reasoning effort set to `high`') -and $capybaraInstalled.Contains('piped/cat-flash') -and $capybaraInstalled.Contains('reasoning effort set to `low`')) -CaseName 'installer fills the Capybara placeholders' -FailMessage $capybaraInstalled
    $duoFillOk = $duoInstalled.Contains('piped/GLM 5.3') -and $duoInstalled.Contains('reasoning effort set to `high`') -and (-not $duoInstalled.Contains('piped/cat-flash')) -and (-not $duoInstalled.Contains('`low`'))
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
    $installedGuardScript = Get-Content -LiteralPath (Join-Path $userRoot 'scripts/guard-subagent-delegation/guard-subagent-delegation.ps1') -Raw
    $installedGuardOk = $installedGuardScript.Contains("`$OwlModel = 'piped/GLM 5.3'") -and
        $installedGuardScript.Contains("`$OwlReasoningEffort = 'high'") -and
        $installedGuardScript.Contains("`$CatModel = 'piped/cat-flash'") -and
        $installedGuardScript.Contains("`$CatReasoningEffort = 'low'")
    Add-Result -Condition ($installedGuardOk) -CaseName 'installer embeds the reviewer values in the guard script' -FailMessage $installedGuardScript
    Add-Result -Condition (-not $installedGuardScript.Contains('__OWL_') -and -not $installedGuardScript.Contains('__CAT_')) -CaseName 'installed guard script has no placeholders' -FailMessage 'a leftover placeholder survived'

    # Case 31: the subagent flags fail fast outside an agents install.
    $skillsOnlyRoot = New-TempRoot
    $result = Invoke-InstallerRun -Arguments (@('-Action', 'install', '-Components', 'skills', '-Level', 'user', '-UserRoot', $skillsOnlyRoot) + $SubagentFlags)
    Add-Result -Condition ($result.ExitCode -eq 1 -and (ConvertTo-ComparableOutput $result.Output).Contains('apply only when installing the agents component or the subagent delegation guard')) -CaseName 'subagent flags fail on a skills-only install' -FailMessage $result.Output
    $result = Invoke-InstallerRun -Arguments (@('-Action', 'uninstall', '-Components', 'agents', '-Level', 'user', '-UserRoot', (New-TempRoot)) + $SubagentFlags)
    Add-Result -Condition ($result.ExitCode -eq 1 -and (ConvertTo-ComparableOutput $result.Output).Contains('apply only when installing the agents component or the subagent delegation guard')) -CaseName 'subagent flags fail on an uninstall run' -FailMessage $result.Output

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
    $retryRun = Invoke-PipedMenuRun -Answers @('1', '1', '2', $retryProject, '', 'menu/owl-5.3', '5', 'menu/cat-5.3', '3', '1', '1')
    Add-Result -Condition ($retryRun.ExitCode -eq 0 -and $retryRun.Output.Contains('Please enter a non-empty value.')) -CaseName 'empty prompt answer re-prompts and exits 0' -FailMessage $retryRun.Output
    $retryCapybara = Get-Content -LiteralPath (Join-Path $retryProject '.github/agents/Capybara.agent.md') -Raw
    $retryFillOk = $retryCapybara.Contains('menu/owl-5.3') -and $retryCapybara.Contains('reasoning effort set to `high`') -and $retryCapybara.Contains('menu/cat-5.3') -and $retryCapybara.Contains('reasoning effort set to `low`') -and (-not $retryCapybara.Contains('__OWL_')) -and (-not $retryCapybara.Contains('__CAT_'))
    Add-Result -Condition ($retryFillOk) -CaseName 'empty prompt answer uses the next piped value' -FailMessage $retryCapybara

    # Case 35: a user-level piped menu install lands in the sandbox profile.
    $userMenuRun = Invoke-PipedMenuRun -Answers @('1', '1', '1', 'menu/owl-5.3', '5', 'menu/cat-5.3', '3', '1', '1')
    Add-Result -Condition ($userMenuRun.ExitCode -eq 0) -CaseName 'user-level piped menu install exits 0' -FailMessage $userMenuRun.Output
    $sandboxCapybara = Get-Content -LiteralPath (Join-Path $userMenuRun.UserProfile '.copilot/agents/Capybara.agent.md') -Raw
    $sandboxFillOk = $sandboxCapybara.Contains('menu/owl-5.3') -and $sandboxCapybara.Contains('reasoning effort set to `high`') -and $sandboxCapybara.Contains('menu/cat-5.3') -and $sandboxCapybara.Contains('reasoning effort set to `low`') -and (-not $sandboxCapybara.Contains('__OWL_')) -and (-not $sandboxCapybara.Contains('__CAT_'))
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
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $partialFlagsRoot, '-OwlModel', 'piped/GLM 5.3', '-OwlReasoningEffort', 'high')
    Add-Result -Condition ($result.ExitCode -eq 1 -and (ConvertTo-ComparableOutput $result.Output).Contains('requires -OwlModel')) -CaseName 'partial subagent flag set fails' -FailMessage $result.Output
    Add-Result -Condition ((Get-InstalledFileCount -Root $partialFlagsRoot) -eq 0) -CaseName 'partial subagent flag set writes nothing' -FailMessage 'files were created'

    # Case 38: a piped menu install whose components exclude agents skips the
    # four subagent questions and installs only the selected component.
    $skillsMenuProject = New-TempRoot
    $skillsMenuRun = Invoke-PipedMenuRun -Answers @('1', '3', '2', $skillsMenuProject, '1')
    Add-Result -Condition ($skillsMenuRun.ExitCode -eq 0 -and (-not $skillsMenuRun.Output.Contains('Which model should Owl run on?'))) -CaseName 'menu without the agents component skips the subagent questions' -FailMessage $skillsMenuRun.Output
    Add-Result -Condition (Test-AllFilesExist -Root $skillsMenuProject -RelativePaths ($RelativeLayout[4..9] | ForEach-Object { '.github/' + $_ })) -CaseName 'skills-only menu install file set' -FailMessage 'skill files are missing'
    Add-Result -Condition (-not (Test-Path -LiteralPath (Join-Path $skillsMenuProject '.github/agents/Capybara.agent.md'))) -CaseName 'skills-only menu install skips agents' -FailMessage 'agent was installed'

    # Case 39: -SubagentGuard Skip installs agents without the guard, and
    # uninstalling agents later still targets the guard files (they report
    # absent instead of erroring).
    $skipRoot = New-TempRoot
    $result = Invoke-InstallerRun -Arguments (@('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $skipRoot, '-SubagentGuard', 'Skip') + $SubagentFlags)
    Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains('Subagent delegation guard: not included')) -CaseName 'SubagentGuard Skip exits 0' -FailMessage $result.Output
    Add-Result -Condition (Test-AllFilesExist -Root $skipRoot -RelativePaths $RelativeLayout[0..3]) -CaseName 'SubagentGuard Skip installs the agents' -FailMessage 'agent files are missing'
    Add-Result -Condition ((Get-InstalledFileCount -Root $skipRoot) -eq 4) -CaseName 'SubagentGuard Skip writes no guard files' -FailMessage 'guard files were created'
    $result = Invoke-InstallerRun -Arguments @('-Action', 'uninstall', '-Components', 'agents', '-Level', 'user', '-UserRoot', $skipRoot)
    Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains('Done: 4 removed, 3 absent, 0 leftover(s) reported.')) -CaseName 'skip installed agents uninstall reports the guard absent' -FailMessage $result.Output

    # Case 40: -SubagentGuard Force installs the guard with the hooks
    # component alone, and uninstalling hooks removes both hooks.
    $forceRoot = New-TempRoot
    $result = Invoke-InstallerRun -Arguments (@('-Action', 'install', '-Components', 'hooks', '-Level', 'user', '-UserRoot', $forceRoot, '-SubagentGuard', 'Force') + $SubagentFlags)
    Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains('Subagent delegation guard: included')) -CaseName 'SubagentGuard Force exits 0' -FailMessage $result.Output
    Add-Result -Condition (Test-AllFilesExist -Root $forceRoot -RelativePaths ($RelativeLayout[10..12] + $SubagentGuardLayout)) -CaseName 'SubagentGuard Force file set' -FailMessage 'hook or guard files are missing'
    Add-Result -Condition (-not (Test-Path -LiteralPath (Join-Path $forceRoot 'agents/Capybara.agent.md'))) -CaseName 'SubagentGuard Force skips agents' -FailMessage 'agent was installed'
    $forceGuardScript = Get-Content -LiteralPath (Join-Path $forceRoot 'scripts/guard-subagent-delegation/guard-subagent-delegation.ps1') -Raw
    $forceGuardOk = $forceGuardScript.Contains("`$OwlModel = 'piped/GLM 5.3'") -and
        $forceGuardScript.Contains("`$OwlReasoningEffort = 'high'") -and
        $forceGuardScript.Contains("`$CatModel = 'piped/cat-flash'") -and
        $forceGuardScript.Contains("`$CatReasoningEffort = 'low'")
    Add-Result -Condition ($forceGuardOk) -CaseName 'hooks-only guard embeds the reviewer values' -FailMessage $forceGuardScript
    $forceSummaryOk = $result.Output.Contains('Owl model: piped/GLM 5.3 (effort: high)') -and
        $result.Output.Contains('Cat model: piped/cat-flash (effort: low)')
    Add-Result -Condition ($forceSummaryOk) -CaseName 'hooks-only guard summary reports the reviewer values' -FailMessage $result.Output
    $result = Invoke-InstallerRun -Arguments @('-Action', 'uninstall', '-Components', 'hooks', '-Level', 'user', '-UserRoot', $forceRoot)
    Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains('Done: 6 removed, 0 absent, 0 leftover(s) reported.')) -CaseName 'forced guard uninstall summary' -FailMessage $result.Output

    # Case 41: the SubagentGuard flag fails fast outside its valid runs.
    $flagsRoot = New-TempRoot
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'skills', '-Level', 'user', '-UserRoot', $flagsRoot, '-SubagentGuard', 'Force')
    Add-Result -Condition ($result.ExitCode -eq 1 -and (ConvertTo-ComparableOutput $result.Output).Contains('requires the agents or hooks component')) -CaseName 'SubagentGuard Force fails on a skills-only install' -FailMessage $result.Output
    Add-Result -Condition ((Get-InstalledFileCount -Root $flagsRoot) -eq 0) -CaseName 'SubagentGuard Force on skills writes nothing' -FailMessage 'files were created'
    $result = Invoke-InstallerRun -Arguments (@('-Action', 'install', '-Components', 'skills', '-Level', 'user', '-UserRoot', (New-TempRoot), '-SubagentGuard', 'Skip') + $SubagentFlags)
    Add-Result -Condition ($result.ExitCode -eq 1) -CaseName 'SubagentGuard Skip fails on a skills-only install' -FailMessage $result.Output
    $result = Invoke-InstallerRun -Arguments (@('-Action', 'uninstall', '-Components', 'agents', '-Level', 'user', '-UserRoot', (New-TempRoot), '-SubagentGuard', 'Force') + $SubagentFlags)
    Add-Result -Condition ($result.ExitCode -eq 1 -and (ConvertTo-ComparableOutput $result.Output).Contains('applies only to install runs')) -CaseName 'SubagentGuard Force fails on an uninstall run' -FailMessage $result.Output

    # Case 42: a piped menu hooks-only install can force the guard in, and the
    # menu collects all four reviewer values for it.
    $menuHooksRun = Invoke-PipedMenuRun -Answers @('1', '4', '1', '2', 'menu/owl-5.3', '5', 'menu/cat-5.3', '3', '1')
    Add-Result -Condition ($menuHooksRun.ExitCode -eq 0 -and $menuHooksRun.Output.Contains('Subagent delegation guard: included')) -CaseName 'piped menu hooks-only includes the guard on demand' -FailMessage $menuHooksRun.Output
    Add-Result -Condition (Test-AllFilesExist -Root (Join-Path $menuHooksRun.UserProfile '.copilot') -RelativePaths ($RelativeLayout[10..12] + $SubagentGuardLayout)) -CaseName 'piped menu guarded hooks file set' -FailMessage 'hook or guard files are missing'
    $menuHooksGuardScript = Get-Content -LiteralPath (Join-Path $menuHooksRun.UserProfile '.copilot/scripts/guard-subagent-delegation/guard-subagent-delegation.ps1') -Raw
    $menuHooksGuardOk = $menuHooksGuardScript.Contains("`$OwlModel = 'menu/owl-5.3'") -and
        $menuHooksGuardScript.Contains("`$OwlReasoningEffort = 'high'") -and
        $menuHooksGuardScript.Contains("`$CatModel = 'menu/cat-5.3'") -and
        $menuHooksGuardScript.Contains("`$CatReasoningEffort = 'low'")
    Add-Result -Condition ($menuHooksGuardOk) -CaseName 'piped menu hooks-only guard embeds the reviewer values' -FailMessage $menuHooksGuardScript

    # Case 43: the same menu run with the default answer leaves the guard out.
    $menuHooksNoGuardRun = Invoke-PipedMenuRun -Answers @('1', '4', '1', '', '1')
    Add-Result -Condition ($menuHooksNoGuardRun.ExitCode -eq 0 -and $menuHooksNoGuardRun.Output.Contains('Subagent delegation guard: not included')) -CaseName 'piped menu hooks-only skips the guard by default' -FailMessage $menuHooksNoGuardRun.Output
    Add-Result -Condition (-not (Test-Path -LiteralPath (Join-Path $menuHooksNoGuardRun.UserProfile '.copilot/hooks/guard-subagent-delegation.json'))) -CaseName 'default menu answer writes no guard JSON' -FailMessage 'guard JSON was created'

    # Case 44: a partial uninstall over a full install must not report intact
    # squad files as leftovers, whatever its own selection planned.
    $partialUninstallRoot = New-TempRoot
    $null = Invoke-InstallerRun -Arguments (@('-Action', 'install', '-Components', 'all', '-Level', 'user', '-UserRoot', $partialUninstallRoot) + $SubagentFlags)
    $result = Invoke-InstallerRun -Arguments @('-Action', 'uninstall', '-Components', 'agents', '-Level', 'user', '-UserRoot', $partialUninstallRoot)
    Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains('Done: 7 removed, 0 absent, 0 leftover(s) reported.')) -CaseName 'agents uninstall over a full install has no leftovers' -FailMessage $result.Output
    Add-Result -Condition (Test-AllFilesExist -Root $partialUninstallRoot -RelativePaths $RelativeLayout[10..12]) -CaseName 'agents uninstall over a full install keeps the shell guard' -FailMessage 'shell guard files were removed'
    Add-Result -Condition (-not (Test-Path -LiteralPath (Join-Path $partialUninstallRoot 'hooks/guard-subagent-delegation.json'))) -CaseName 'agents uninstall over a full install removes the guard' -FailMessage 'guard JSON survived'
    $result = Invoke-InstallerRun -Arguments @('-Action', 'uninstall', '-Components', 'skills', '-Level', 'user', '-UserRoot', $partialUninstallRoot)
    Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains('Done: 6 removed, 0 absent, 0 leftover(s) reported.')) -CaseName 'skills uninstall over the remains has no leftovers' -FailMessage $result.Output
    Add-Result -Condition (-not (Test-Path -LiteralPath (Join-Path $partialUninstallRoot 'skills/gh-multi-account'))) -CaseName 'skills uninstall removes gh-multi-account' -FailMessage 'gh-multi-account folder survived'

    # Case 45: renamed squad skill folders are reported as leftovers and survive.
    # The rename makes the planned skill file report as absent, the same category that
    # a -SubagentGuard Skip uninstall reports for the guard files.
    foreach ($skillName in 'agents-md', 'commit-message', 'gh-multi-account', 'merge-strategy', 'pr-description') {
        $leftoverSkillRoot = New-TempRoot
        $null = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'skills', '-Level', 'user', '-UserRoot', $leftoverSkillRoot)
        $renamedSkillFolder = Join-Path (Join-Path $leftoverSkillRoot 'skills') ($skillName + '.old.disabled')
        Move-Item -LiteralPath (Join-Path $leftoverSkillRoot ('skills/' + $skillName)) -Destination $renamedSkillFolder
        $result = Invoke-InstallerRun -Arguments @('-Action', 'uninstall', '-Components', 'skills', '-Level', 'user', '-UserRoot', $leftoverSkillRoot)
        $expectedSummary = 'Done: 5 removed, 1 absent, 1 leftover(s) reported.'
        if ($skillName -eq 'agents-md') {
            # agents-md ships two planned files (SKILL.md plus the bundled template asset),
            # so renaming its folder reports two absent files instead of one.
            $expectedSummary = 'Done: 4 removed, 2 absent, 1 leftover(s) reported.'
        }
        Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains($expectedSummary)) -CaseName ('renamed ' + $skillName + ' folder is reported as a leftover') -FailMessage $result.Output
        Add-Result -Condition ($result.Output.Contains($renamedSkillFolder) -and (Test-Path -LiteralPath $renamedSkillFolder -PathType Container)) -CaseName ('renamed ' + $skillName + ' folder is listed and survives uninstall') -FailMessage $result.Output
    }

    # Case 46: an effort flag outside the allowed set is rejected before any
    # file is written.
    $invalidEffortRoot = New-TempRoot
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $invalidEffortRoot, '-OwlModel', 'm', '-OwlReasoningEffort', 'ultra', '-CatModel', 'c', '-CatReasoningEffort', 'low')
    Add-Result -Condition ($result.ExitCode -eq 1) -CaseName 'invalid effort flag is rejected' -FailMessage $result.Output
    Add-Result -Condition ((Get-InstalledFileCount -Root $invalidEffortRoot) -eq 0) -CaseName 'invalid effort flag writes nothing' -FailMessage 'files were created'

    # Case 47: an out-of-range effort menu answer re-prompts and the next
    # valid answer is used.
    $effortRetryProject = New-TempRoot
    $effortRetryRun = Invoke-PipedMenuRun -Answers @('1', '1', '2', $effortRetryProject, 'menu/owl-5.3', '99', '5', 'menu/cat-5.3', '3', '1', '1')
    Add-Result -Condition ($effortRetryRun.ExitCode -eq 0 -and $effortRetryRun.Output.Contains('Please enter a number from the list.')) -CaseName 'invalid effort menu answer re-prompts' -FailMessage $effortRetryRun.Output
    $effortRetryCapybara = Get-Content -LiteralPath (Join-Path $effortRetryProject '.github/agents/Capybara.agent.md') -Raw
    Add-Result -Condition ($effortRetryCapybara.Contains('reasoning effort set to `high`')) -CaseName 'invalid effort menu answer uses the next valid choice' -FailMessage $effortRetryCapybara

    # Case 48: a hooks-only guard install needs the model names as well as the
    # efforts, because the guard uses the model to decide when to compare.
    $missingValuesRoot = New-TempRoot
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'hooks', '-Level', 'user', '-UserRoot', $missingValuesRoot, '-SubagentGuard', 'Force', '-OwlModel', 'm', '-CatModel', 'c')
    Add-Result -Condition ($result.ExitCode -eq 1 -and (ConvertTo-ComparableOutput $result.Output).Contains('requires -OwlModel')) -CaseName 'hooks-only guard without reviewer values fails' -FailMessage $result.Output
    Add-Result -Condition ((Get-InstalledFileCount -Root $missingValuesRoot) -eq 0) -CaseName 'hooks-only guard without reviewer values writes nothing' -FailMessage 'files were created'

    # Case 49: reviewer flags remain invalid on a hooks-only install that does
    # not include the guard.
    $hooksNoGuardRoot = New-TempRoot
    $result = Invoke-InstallerRun -Arguments (@('-Action', 'install', '-Components', 'hooks', '-Level', 'user', '-UserRoot', $hooksNoGuardRoot) + $SubagentFlags)
    Add-Result -Condition ($result.ExitCode -eq 1 -and (ConvertTo-ComparableOutput $result.Output).Contains('apply only when installing the agents component or the subagent delegation guard')) -CaseName 'reviewer flags fail without the guard' -FailMessage $result.Output
    Add-Result -Condition ((Get-InstalledFileCount -Root $hooksNoGuardRoot) -eq 0) -CaseName 'reviewer flags without the guard write nothing' -FailMessage 'files were created'

    # Case 50: a guard template missing its model placeholder aborts before
    # any file is written.
    $guardTemplateRoot = New-TempRoot
    foreach ($repoFolder in 'agents', 'skills', 'hooks', 'scripts') {
        Copy-Item -LiteralPath (Join-Path $ScriptRoot $repoFolder) -Destination (Join-Path $guardTemplateRoot $repoFolder) -Recurse
    }
    Copy-Item -LiteralPath $Installer -Destination $guardTemplateRoot
    $mutatedGuardPath = Join-Path $guardTemplateRoot 'scripts/guard-subagent-delegation/guard-subagent-delegation.ps1'
    (Get-Content -LiteralPath $mutatedGuardPath -Raw).Replace('__OWL_MODEL__', '') |
        Set-Content -LiteralPath $mutatedGuardPath -NoNewline
    $abortedGuardRoot = New-TempRoot
    $result = Invoke-InstallerRun -ExecutablePath (Join-Path $guardTemplateRoot 'install.ps1') -Arguments (@('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $abortedGuardRoot) + $SubagentFlags)
    Add-Result -Condition ($result.ExitCode -eq 1 -and (ConvertTo-ComparableOutput $result.Output).Contains('does not contain the expected placeholder')) -CaseName 'guard template without a model placeholder aborts' -FailMessage $result.Output
    Add-Result -Condition ((Get-InstalledFileCount -Root $abortedGuardRoot) -eq 0) -CaseName 'guard template without a model placeholder writes nothing' -FailMessage 'files were created'

    # Case 51: a guard template missing its effort placeholder aborts before
    # any file is written.
    $guardEffortTemplateRoot = New-TempRoot
    foreach ($repoFolder in 'agents', 'skills', 'hooks', 'scripts') {
        Copy-Item -LiteralPath (Join-Path $ScriptRoot $repoFolder) -Destination (Join-Path $guardEffortTemplateRoot $repoFolder) -Recurse
    }
    Copy-Item -LiteralPath $Installer -Destination $guardEffortTemplateRoot
    $mutatedGuardEffortPath = Join-Path $guardEffortTemplateRoot 'scripts/guard-subagent-delegation/guard-subagent-delegation.ps1'
    (Get-Content -LiteralPath $mutatedGuardEffortPath -Raw).Replace('__CAT_REASONING_EFFORT__', '') |
        Set-Content -LiteralPath $mutatedGuardEffortPath -NoNewline
    $abortedGuardEffortRoot = New-TempRoot
    $result = Invoke-InstallerRun -ExecutablePath (Join-Path $guardEffortTemplateRoot 'install.ps1') -Arguments (@('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $abortedGuardEffortRoot) + $SubagentFlags)
    Add-Result -Condition ($result.ExitCode -eq 1 -and (ConvertTo-ComparableOutput $result.Output).Contains('does not contain the expected placeholder')) -CaseName 'guard template without an effort placeholder aborts' -FailMessage $result.Output
    Add-Result -Condition ((Get-InstalledFileCount -Root $abortedGuardEffortRoot) -eq 0) -CaseName 'guard template without an effort placeholder writes nothing' -FailMessage 'files were created'

    # Case 52: reinstalling with different reviewer values updates the guard
    # script rather than leaving the first values in place.
    $reinstallRoot = New-TempRoot
    $firstFlags = @('-OwlModel', 'first/owl', '-OwlReasoningEffort', 'low', '-CatModel', 'first/cat', '-CatReasoningEffort', 'minimal')
    $null = Invoke-InstallerRun -Arguments (@('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $reinstallRoot) + $firstFlags)
    $secondFlags = @('-OwlModel', 'second/owl', '-OwlReasoningEffort', 'max', '-CatModel', 'second/cat', '-CatReasoningEffort', 'xhigh')
    $result = Invoke-InstallerRun -Arguments (@('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $reinstallRoot) + $secondFlags)
    $reinstallGuardScript = Get-Content -LiteralPath (Join-Path $reinstallRoot 'scripts/guard-subagent-delegation/guard-subagent-delegation.ps1') -Raw
    $reinstallGuardOk = $reinstallGuardScript.Contains("`$OwlModel = 'second/owl'") -and
        $reinstallGuardScript.Contains("`$OwlReasoningEffort = 'max'") -and
        $reinstallGuardScript.Contains("`$CatModel = 'second/cat'") -and
        $reinstallGuardScript.Contains("`$CatReasoningEffort = 'xhigh'")
    Add-Result -Condition ($result.ExitCode -eq 0 -and $reinstallGuardOk) -CaseName 'reinstall with new values updates the guard script' -FailMessage $reinstallGuardScript
    Add-Result -Condition (-not $reinstallGuardScript.Contains('__OWL_') -and -not $reinstallGuardScript.Contains('__CAT_')) -CaseName 'reinstalled guard script has no placeholders' -FailMessage 'a leftover placeholder survived'

    # Case 53: effort flags are accepted without regard to case and stored in
    # lowercase.
    $caseEffortRoot = New-TempRoot
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $caseEffortRoot, '-OwlModel', 'm', '-OwlReasoningEffort', 'HIGH', '-CatModel', 'c', '-CatReasoningEffort', 'Low')
    $caseGuardScript = Get-Content -LiteralPath (Join-Path $caseEffortRoot 'scripts/guard-subagent-delegation/guard-subagent-delegation.ps1') -Raw
    $caseGuardOk = $result.ExitCode -eq 0 -and
        $caseGuardScript.Contains("`$OwlReasoningEffort = 'high'") -and
        $caseGuardScript.Contains("`$CatReasoningEffort = 'low'")
    Add-Result -Condition ($caseGuardOk) -CaseName 'effort flags are stored in lowercase' -FailMessage $caseGuardScript

    # Case 54: a model value with a single quote is rejected because the guard
    # embeds model values in single-quoted PowerShell literals.
    $quotedModelRoot = New-TempRoot
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $quotedModelRoot, '-OwlModel', "o'brien", '-OwlReasoningEffort', 'high', '-CatModel', 'c', '-CatReasoningEffort', 'low')
    Add-Result -Condition ($result.ExitCode -eq 1 -and (ConvertTo-ComparableOutput $result.Output).Contains('cannot contain a single quote')) -CaseName 'model with a single quote is rejected' -FailMessage $result.Output
    Add-Result -Condition ((Get-InstalledFileCount -Root $quotedModelRoot) -eq 0) -CaseName 'model with a single quote writes nothing' -FailMessage 'files were created'

    # Case 55: a model value with a line feed is rejected.
    $newlineModelRoot = New-TempRoot
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $newlineModelRoot, '-OwlModel', "line`nbreak", '-OwlReasoningEffort', 'high', '-CatModel', 'c', '-CatReasoningEffort', 'low')
    Add-Result -Condition ($result.ExitCode -eq 1 -and (ConvertTo-ComparableOutput $result.Output).Contains('cannot contain a single quote')) -CaseName 'model with a line feed is rejected' -FailMessage $result.Output
    Add-Result -Condition ((Get-InstalledFileCount -Root $newlineModelRoot) -eq 0) -CaseName 'model with a line feed writes nothing' -FailMessage 'files were created'

    # Case 56: a Cat model value shaped like an installer placeholder is
    # rejected, covering the Cat validation path.
    $placeholderModelRoot = New-TempRoot
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $placeholderModelRoot, '-OwlModel', 'm', '-OwlReasoningEffort', 'high', '-CatModel', '__CAT_MODEL__', '-CatReasoningEffort', 'low')
    Add-Result -Condition ($result.ExitCode -eq 1 -and (ConvertTo-ComparableOutput $result.Output).Contains('cannot be a placeholder')) -CaseName 'placeholder-shaped Cat model is rejected' -FailMessage $result.Output
    Add-Result -Condition ((Get-InstalledFileCount -Root $placeholderModelRoot) -eq 0) -CaseName 'placeholder-shaped Cat model writes nothing' -FailMessage 'files were created'

    # Case 57: the menu path rejects the same model characters.
    $menuQuotedModelRoot = New-TempRoot
    $menuQuotedModelRun = Invoke-PipedMenuRun -Answers @('1', '1', '2', $menuQuotedModelRoot, "o'brien", '5', 'menu/cat-5.3', '3', '1', '1')
    Add-Result -Condition ($menuQuotedModelRun.ExitCode -eq 1 -and (ConvertTo-ComparableOutput $menuQuotedModelRun.Output).Contains('cannot contain a single quote')) -CaseName 'menu model with a single quote is rejected' -FailMessage $menuQuotedModelRun.Output
    Add-Result -Condition ((Get-InstalledFileCount -Root $menuQuotedModelRoot) -eq 0) -CaseName 'menu model with a single quote writes nothing' -FailMessage 'files were created'

    # Case 58: installed agent frontmatter carries exactly the contract keys,
    # compared case-sensitively because YAML keys are. Only the reviewers opt
    # into repository instructions, because the Copilot runtime withholds
    # AGENTS.md from a custom agent running as a subagent. Reuses case 1's
    # user-level install.
    $sessionAgentKeys = @('name', 'description', 'user-invocable', 'disable-model-invocation')
    $reviewerAgentKeys = $sessionAgentKeys + 'include-custom-instructions'
    $expectedAgentKeys = [ordered]@{
        'Capybara.agent.md' = $sessionAgentKeys
        'CapybaraDuo.agent.md' = $sessionAgentKeys
        'Owl.agent.md' = $reviewerAgentKeys
        'Cat.agent.md' = $reviewerAgentKeys
    }
    $agentFrontmatterByFile = [ordered]@{}
    foreach ($agentFileName in $expectedAgentKeys.Keys) {
        $agentFrontmatter = Get-Frontmatter -Text (Get-Content -LiteralPath (Join-Path $userRoot "agents/$agentFileName") -Raw)
        $agentFrontmatterByFile[$agentFileName] = $agentFrontmatter
        $actualKeyList = Get-SortedKeyList -KeyNames $agentFrontmatter.KeyNames
        $expectedKeyList = Get-SortedKeyList -KeyNames $expectedAgentKeys[$agentFileName]
        Add-Result -Condition ($actualKeyList -ceq $expectedKeyList) -CaseName "$agentFileName frontmatter keys match the contract" -FailMessage "found: $actualKeyList"
    }
    foreach ($agentFileName in $expectedAgentKeys.Keys) {
        if ($expectedAgentKeys[$agentFileName] -cnotcontains 'include-custom-instructions') {
            continue
        }
        # A quoted 'true' is a YAML string, which the runtime does not read
        # as the boolean opt-in.
        $optInRawValue = $agentFrontmatterByFile[$agentFileName].RawValues['include-custom-instructions']
        Add-Result -Condition ($optInRawValue -ceq 'true') -CaseName "$agentFileName opts into repository instructions" -FailMessage "include-custom-instructions is '$optInRawValue'"
    }

    # Case 59: installed skill frontmatter carries exactly the contract keys,
    # declares the MIT license, and every skill that shells out to git or gh
    # names each tool it needs in a single-quoted compatibility value within
    # the Agent Skills limit of 500 characters. Reuses case 1's user-level
    # install.
    $compatibilityMaxLength = 500
    $baseSkillKeys = @('name', 'description', 'license')
    $expectedSkills = [ordered]@{
        'agents-md' = @{ KeyNames = $baseSkillKeys + 'argument-hint'; Tools = @() }
        'commit-message' = @{ KeyNames = $baseSkillKeys + @('argument-hint', 'compatibility'); Tools = @('git') }
        'gh-multi-account' = @{ KeyNames = $baseSkillKeys + 'compatibility'; Tools = @('git', 'gh') }
        'merge-strategy' = @{ KeyNames = $baseSkillKeys + @('argument-hint', 'compatibility'); Tools = @('git', 'gh') }
        'pr-description' = @{ KeyNames = $baseSkillKeys + @('argument-hint', 'compatibility'); Tools = @('git', 'gh') }
    }
    foreach ($skillFolder in $expectedSkills.Keys) {
        $expectedSkill = $expectedSkills[$skillFolder]
        $skillFrontmatter = Get-Frontmatter -Text (Get-Content -LiteralPath (Join-Path $userRoot "skills/$skillFolder/SKILL.md") -Raw)
        $actualKeyList = Get-SortedKeyList -KeyNames $skillFrontmatter.KeyNames
        $expectedKeyList = Get-SortedKeyList -KeyNames $expectedSkill.KeyNames
        Add-Result -Condition ($actualKeyList -ceq $expectedKeyList) -CaseName "$skillFolder skill frontmatter keys match the contract" -FailMessage "found: $actualKeyList"
        $license = $skillFrontmatter.Values['license']
        Add-Result -Condition ($license -ceq 'MIT') -CaseName "$skillFolder skill declares the MIT license" -FailMessage "license is '$license'"
        $compatibility = [string]$skillFrontmatter.Values['compatibility']
        if ($expectedSkill.Tools.Count -eq 0) {
            Add-Result -Condition ($compatibility -eq '') -CaseName "$skillFolder skill declares no compatibility" -FailMessage "compatibility is '$compatibility'"
            continue
        }
        $unnamedTools = @($expectedSkill.Tools | Where-Object { $compatibility -notmatch "\b$_\b" })
        $compatibilityOk = $unnamedTools.Count -eq 0 -and $compatibility.Length -le $compatibilityMaxLength
        Add-Result -Condition $compatibilityOk -CaseName "$skillFolder skill names its required tools in compatibility" -FailMessage "compatibility is '$compatibility'"
        $rawCompatibility = [string]$skillFrontmatter.RawValues['compatibility']
        Add-Result -Condition ($rawCompatibility -cmatch '^''.*''$') -CaseName "$skillFolder skill single-quotes its compatibility" -FailMessage "compatibility is written as $rawCompatibility"
    }

    # Case 60: an agents install adds the marked entry to git's default
    # excludes file, and git then ignores report files at a repository root
    # and inside nested project folders, but not unrelated files.
    $expectedExcludeEntry = $TempReportsMarker + "`n" + $TempReportsPattern + "`n"
    $addSandbox = New-GitSandbox
    $addRoot = New-TempRoot
    $addArguments = @('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $addRoot) + $SubagentFlags
    $result = Invoke-InstallerRun -GitSandbox $addSandbox -Arguments $addArguments
    $expectedAddSummary = "Temp reports git exclude: will add $TempReportsPattern to $($addSandbox.DefaultExcludesFile)"
    Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains($expectedAddSummary) -and $result.Output.Contains('entry added')) -CaseName 'agents install reports the temp reports exclude' -FailMessage $result.Output
    $addedExcludes = Get-SandboxFileText -Path $addSandbox.DefaultExcludesFile
    Add-Result -Condition ($addedExcludes -ceq $expectedExcludeEntry) -CaseName 'agents install writes the marked temp reports entry' -FailMessage "excludes file: '$addedExcludes'"
    $probeRepo = New-TempRoot
    $probePaths = @(
        '.github/temp_reports/20260101_000000_probe/implementation_1.md',
        'packages/app/.github/temp_reports/20260101_000000_probe/review_1.md',
        'docs/notes.md'
    )
    foreach ($probePath in $probePaths) {
        $probeFile = Join-Path $probeRepo $probePath
        New-Item -Path (Split-Path -Parent $probeFile) -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath $probeFile -Value 'probe'
    }
    $checkIgnoreExitCodes = @(Invoke-InGitSandbox -GitSandbox $addSandbox -ScriptBlock {
            $null = & git -C $probeRepo init -q
            foreach ($probePath in $probePaths) {
                $null = & git -C $probeRepo check-ignore -q $probePath
                $LASTEXITCODE
            }
        })
    Add-Result -Condition (($checkIgnoreExitCodes -join ',') -eq '0,0,1') -CaseName 'git ignores root and nested report folders through the entry' -FailMessage "check-ignore exit codes: $($checkIgnoreExitCodes -join ',')"

    # Case 61: reinstalling keeps a single entry.
    $result = Invoke-InstallerRun -GitSandbox $addSandbox -Arguments $addArguments
    $reinstalledExcludes = Get-SandboxFileText -Path $addSandbox.DefaultExcludesFile
    $reinstallOk = $result.ExitCode -eq 0 -and $result.Output.Contains("Temp reports git exclude: already covered in $($addSandbox.DefaultExcludesFile)") -and ($reinstalledExcludes -ceq $expectedExcludeEntry)
    Add-Result -Condition $reinstallOk -CaseName 'reinstall keeps a single temp reports entry' -FailMessage "$($result.Output) excludes file: '$reinstalledExcludes'"

    # Case 62: the entry follows the file's CRLF line endings, and an agents
    # uninstall removes only the marked pair, keeping the lines on both sides.
    $crlfSandbox = New-GitSandbox
    New-Item -Path (Split-Path -Parent $crlfSandbox.DefaultExcludesFile) -ItemType Directory -Force | Out-Null
    [System.IO.File]::WriteAllText($crlfSandbox.DefaultExcludesFile, "node_modules/`r`n")
    $crlfRoot = New-TempRoot
    $null = Invoke-InstallerRun -GitSandbox $crlfSandbox -Arguments (@('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $crlfRoot) + $SubagentFlags)
    $crlfExcludes = Get-SandboxFileText -Path $crlfSandbox.DefaultExcludesFile
    Add-Result -Condition ($crlfExcludes -ceq "node_modules/`r`n$TempReportsMarker`r`n$TempReportsPattern`r`n") -CaseName 'temp reports entry follows CRLF line endings' -FailMessage "excludes file: '$crlfExcludes'"
    [System.IO.File]::AppendAllText($crlfSandbox.DefaultExcludesFile, "*.log`r`n")
    $result = Invoke-InstallerRun -GitSandbox $crlfSandbox -Arguments @('-Action', 'uninstall', '-Components', 'agents', '-Level', 'user', '-UserRoot', $crlfRoot)
    $crlfAfterUninstall = Get-SandboxFileText -Path $crlfSandbox.DefaultExcludesFile
    $crlfUninstallOk = $result.ExitCode -eq 0 -and $result.Output.Contains('entry removed') -and ($crlfAfterUninstall -ceq "node_modules/`r`n*.log`r`n")
    Add-Result -Condition $crlfUninstallOk -CaseName 'agents uninstall removes only the marked temp reports entry' -FailMessage "$($result.Output) excludes file: '$crlfAfterUninstall'"

    # Case 63: a file without a trailing newline gets the entry on new lines
    # instead of extending its last pattern.
    $noNewlineSandbox = New-GitSandbox
    New-Item -Path (Split-Path -Parent $noNewlineSandbox.DefaultExcludesFile) -ItemType Directory -Force | Out-Null
    [System.IO.File]::WriteAllText($noNewlineSandbox.DefaultExcludesFile, 'node_modules/')
    $null = Invoke-InstallerRun -GitSandbox $noNewlineSandbox -Arguments (@('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', (New-TempRoot)) + $SubagentFlags)
    $noNewlineExcludes = Get-SandboxFileText -Path $noNewlineSandbox.DefaultExcludesFile
    Add-Result -Condition ($noNewlineExcludes -ceq "node_modules/`n$expectedExcludeEntry") -CaseName 'temp reports entry starts on a new line' -FailMessage "excludes file: '$noNewlineExcludes'"

    # Case 64: a user-written equivalent pattern without the marker, here
    # without the trailing slash, blocks a duplicate, and uninstall leaves it
    # in place because it is not the installer's.
    $userEntrySandbox = New-GitSandbox
    $userEntryContent = "# mine`n**/.github/temp_reports`n"
    New-Item -Path (Split-Path -Parent $userEntrySandbox.DefaultExcludesFile) -ItemType Directory -Force | Out-Null
    [System.IO.File]::WriteAllText($userEntrySandbox.DefaultExcludesFile, $userEntryContent)
    $userEntryRoot = New-TempRoot
    $result = Invoke-InstallerRun -GitSandbox $userEntrySandbox -Arguments (@('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $userEntryRoot) + $SubagentFlags)
    $userEntryAfterInstall = Get-SandboxFileText -Path $userEntrySandbox.DefaultExcludesFile
    Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains('Temp reports git exclude: already covered in') -and ($userEntryAfterInstall -ceq $userEntryContent)) -CaseName 'user temp reports entry blocks a duplicate' -FailMessage "$($result.Output) excludes file: '$userEntryAfterInstall'"
    $result = Invoke-InstallerRun -GitSandbox $userEntrySandbox -Arguments @('-Action', 'uninstall', '-Components', 'agents', '-Level', 'user', '-UserRoot', $userEntryRoot)
    $userEntryAfterUninstall = Get-SandboxFileText -Path $userEntrySandbox.DefaultExcludesFile
    Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains('Temp reports git exclude: no installer entry in') -and ($userEntryAfterUninstall -ceq $userEntryContent)) -CaseName 'uninstall keeps the user temp reports entry' -FailMessage "$($result.Output) excludes file: '$userEntryAfterUninstall'"

    # Case 65: a core.excludesFile setting redirects the entry to that file,
    # and git's default excludes file stays untouched.
    $customSandbox = New-GitSandbox
    $customExcludesFile = Join-Path (Join-Path $customSandbox.Root 'custom') 'global-ignore'
    [System.IO.File]::WriteAllText($customSandbox.GlobalConfig, "[core]`n`texcludesFile = $($customExcludesFile -replace '\\', '/')`n")
    $result = Invoke-InstallerRun -GitSandbox $customSandbox -Arguments (@('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', (New-TempRoot)) + $SubagentFlags)
    $customExcludes = Get-SandboxFileText -Path $customExcludesFile
    Add-Result -Condition ($result.ExitCode -eq 0 -and ($customExcludes -ceq $expectedExcludeEntry)) -CaseName 'core.excludesFile receives the temp reports entry' -FailMessage "$($result.Output) excludes file: '$customExcludes'"
    Add-Result -Condition ($null -eq (Get-SandboxFileText -Path $customSandbox.DefaultExcludesFile)) -CaseName 'core.excludesFile leaves the default excludes file alone' -FailMessage 'the default excludes file was written'

    # Case 66: a relative core.excludesFile is skipped with a warning, because
    # git resolves it per repository, and the agents still install.
    $relativeSandbox = New-GitSandbox
    [System.IO.File]::WriteAllText($relativeSandbox.GlobalConfig, "[core]`n`texcludesFile = relative/ignore`n")
    $relativeRoot = New-TempRoot
    $result = Invoke-InstallerRun -GitSandbox $relativeSandbox -Arguments (@('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $relativeRoot) + $SubagentFlags)
    $relativeOutput = ConvertTo-ComparableOutput $result.Output
    Add-Result -Condition ($result.ExitCode -eq 0 -and $relativeOutput.Contains('WARNING:') -and $relativeOutput.Contains('skipped (core.excludesFile is the relative path')) -CaseName 'relative core.excludesFile warns and skips' -FailMessage $result.Output
    Add-Result -Condition ((Test-AllFilesExist -Root $relativeRoot -RelativePaths $RelativeLayout[0..3]) -and ($null -eq (Get-SandboxFileText -Path $relativeSandbox.DefaultExcludesFile))) -CaseName 'relative core.excludesFile still installs the agents only' -FailMessage 'agents are missing or the default excludes file was written'

    # Case 67: a global git config git cannot parse skips the entry with a
    # warning instead of guessing a path.
    $brokenConfigSandbox = New-GitSandbox
    [System.IO.File]::WriteAllText($brokenConfigSandbox.GlobalConfig, "[core`n")
    $result = Invoke-InstallerRun -GitSandbox $brokenConfigSandbox -Arguments (@('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', (New-TempRoot)) + $SubagentFlags)
    $brokenConfigOutput = ConvertTo-ComparableOutput $result.Output
    Add-Result -Condition ($result.ExitCode -eq 0 -and $brokenConfigOutput.Contains('skipped (git could not read its config') -and ($null -eq (Get-SandboxFileText -Path $brokenConfigSandbox.DefaultExcludesFile))) -CaseName 'unreadable global git config skips the entry' -FailMessage $result.Output

    # Case 68: -TempReportsExclude Skip leaves the file alone on install, and
    # on an uninstall it keeps an entry an earlier install added.
    $skipExcludeSandbox = New-GitSandbox
    $skipExcludeRoot = New-TempRoot
    $result = Invoke-InstallerRun -GitSandbox $skipExcludeSandbox -Arguments (@('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $skipExcludeRoot, '-TempReportsExclude', 'Skip') + $SubagentFlags)
    $skipInstallOk = $result.ExitCode -eq 0 -and $result.Output.Contains('Temp reports git exclude: skipped (opted out)') -and ($null -eq (Get-SandboxFileText -Path $skipExcludeSandbox.DefaultExcludesFile))
    Add-Result -Condition $skipInstallOk -CaseName 'TempReportsExclude Skip install leaves the excludes file alone' -FailMessage $result.Output
    Add-Result -Condition (Test-AllFilesExist -Root $skipExcludeRoot -RelativePaths $RelativeLayout[0..3]) -CaseName 'TempReportsExclude Skip still installs the agents' -FailMessage 'agent files are missing'
    $null = Invoke-InstallerRun -GitSandbox $skipExcludeSandbox -Arguments (@('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $skipExcludeRoot) + $SubagentFlags)
    $result = Invoke-InstallerRun -GitSandbox $skipExcludeSandbox -Arguments @('-Action', 'uninstall', '-Components', 'agents', '-Level', 'user', '-UserRoot', $skipExcludeRoot, '-TempReportsExclude', 'Skip')
    $skipUninstallExcludes = Get-SandboxFileText -Path $skipExcludeSandbox.DefaultExcludesFile
    Add-Result -Condition ($result.ExitCode -eq 0 -and ($skipUninstallExcludes -ceq $expectedExcludeEntry)) -CaseName 'TempReportsExclude Skip uninstall keeps the entry' -FailMessage "$($result.Output) excludes file: '$skipUninstallExcludes'"

    # Case 69: -TempReportsExclude Skip fails fast on a run without the agents
    # component, before writing anything.
    $skipNoAgentsRoot = New-TempRoot
    $result = Invoke-InstallerRun -Arguments @('-Action', 'install', '-Components', 'skills', '-Level', 'user', '-UserRoot', $skipNoAgentsRoot, '-TempReportsExclude', 'Skip')
    Add-Result -Condition ($result.ExitCode -eq 1 -and (ConvertTo-ComparableOutput $result.Output).Contains('applies only when the agents component is selected')) -CaseName 'TempReportsExclude Skip without agents fails' -FailMessage $result.Output
    Add-Result -Condition ((Get-InstalledFileCount -Root $skipNoAgentsRoot) -eq 0) -CaseName 'TempReportsExclude Skip without agents writes nothing' -FailMessage 'files were created'

    # Case 70: installs without the agents component never touch the excludes
    # file and print no exclude summary.
    foreach ($componentName in 'skills', 'hooks') {
        $noAgentsSandbox = New-GitSandbox
        $result = Invoke-InstallerRun -GitSandbox $noAgentsSandbox -Arguments @('-Action', 'install', '-Components', $componentName, '-Level', 'user', '-UserRoot', (New-TempRoot))
        $noAgentsOk = $result.ExitCode -eq 0 -and (-not $result.Output.Contains('Temp reports git exclude')) -and ($null -eq (Get-SandboxFileText -Path $noAgentsSandbox.DefaultExcludesFile))
        Add-Result -Condition $noAgentsOk -CaseName "$componentName-only install leaves the excludes file alone" -FailMessage $result.Output
    }

    # Case 71: a repo-level agents install adds the same global entry, since
    # the agents write reports in that project too.
    $repoExcludeSandbox = New-GitSandbox
    $result = Invoke-InstallerRun -GitSandbox $repoExcludeSandbox -Arguments (@('-Action', 'install', '-Components', 'agents', '-Level', 'repo', '-ProjectRoot', (New-TempRoot)) + $SubagentFlags)
    $repoExcludes = Get-SandboxFileText -Path $repoExcludeSandbox.DefaultExcludesFile
    Add-Result -Condition ($result.ExitCode -eq 0 -and ($repoExcludes -ceq $expectedExcludeEntry)) -CaseName 'repo-level agents install adds the temp reports entry' -FailMessage "$($result.Output) excludes file: '$repoExcludes'"

    # Case 72: without git on PATH the entry is skipped with a warning and the
    # agents still install. The child PATH keeps only the pwsh folder.
    $noGitSandbox = New-GitSandbox
    $noGitRoot = New-TempRoot
    $previousPath = $env:PATH
    $env:PATH = $PSHOME
    try {
        $result = Invoke-InstallerRun -GitSandbox $noGitSandbox -Arguments (@('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $noGitRoot) + $SubagentFlags)
    }
    finally {
        $env:PATH = $previousPath
    }
    $noGitOutput = ConvertTo-ComparableOutput $result.Output
    Add-Result -Condition ($result.ExitCode -eq 0 -and $noGitOutput.Contains('WARNING:') -and $noGitOutput.Contains('skipped (git was not found on PATH)')) -CaseName 'missing git warns and skips the entry' -FailMessage $result.Output
    Add-Result -Condition ((Test-AllFilesExist -Root $noGitRoot -RelativePaths $RelativeLayout[0..3]) -and ($null -eq (Get-SandboxFileText -Path $noGitSandbox.DefaultExcludesFile))) -CaseName 'missing git still installs the agents only' -FailMessage 'agents are missing or the excludes file was written'

    # Case 73: -WhatIf plans the entry and writes no excludes file.
    $whatIfExcludeSandbox = New-GitSandbox
    $result = Invoke-InstallerRun -GitSandbox $whatIfExcludeSandbox -Arguments (@('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', (New-TempRoot), '-WhatIf') + $SubagentFlags)
    $whatIfExcludeOk = $result.ExitCode -eq 0 -and $result.Output.Contains('planned (entry added)') -and ($null -eq (Get-SandboxFileText -Path $whatIfExcludeSandbox.DefaultExcludesFile))
    Add-Result -Condition $whatIfExcludeOk -CaseName 'WhatIf writes no temp reports entry' -FailMessage $result.Output

    # Case 74: the menu asks before adding the entry. Answering no skips it,
    # and the default answer adds it.
    $menuNoSandbox = New-GitSandbox
    $menuNoRun = Invoke-PipedMenuRun -GitSandbox $menuNoSandbox -Answers @('1', '1', '1', 'menu/owl-5.3', '5', 'menu/cat-5.3', '3', '2', '1')
    $menuNoOutput = ConvertTo-ComparableOutput $menuNoRun.Output
    $menuNoOk = $menuNoRun.ExitCode -eq 0 -and $menuNoOutput.Contains("to your global git excludes file ($($menuNoSandbox.DefaultExcludesFile))") -and $menuNoOutput.Contains('skipped (opted out)') -and ($null -eq (Get-SandboxFileText -Path $menuNoSandbox.DefaultExcludesFile))
    Add-Result -Condition $menuNoOk -CaseName 'menu answer no skips the temp reports entry' -FailMessage $menuNoRun.Output
    $menuDefaultSandbox = New-GitSandbox
    $menuDefaultRun = Invoke-PipedMenuRun -GitSandbox $menuDefaultSandbox -Answers @('1', '1', '1', 'menu/owl-5.3', '5', 'menu/cat-5.3', '3', '', '1')
    $menuDefaultExcludes = Get-SandboxFileText -Path $menuDefaultSandbox.DefaultExcludesFile
    Add-Result -Condition ($menuDefaultRun.ExitCode -eq 0 -and ($menuDefaultExcludes -ceq $expectedExcludeEntry)) -CaseName 'menu default answer adds the temp reports entry' -FailMessage "$($menuDefaultRun.Output) excludes file: '$menuDefaultExcludes'"

    # Case 75: a menu uninstall of the agents removes the installer's entry
    # without an extra question, keeping the user's other lines.
    $menuUninstallSandbox = New-GitSandbox
    New-Item -Path (Split-Path -Parent $menuUninstallSandbox.DefaultExcludesFile) -ItemType Directory -Force | Out-Null
    [System.IO.File]::WriteAllText($menuUninstallSandbox.DefaultExcludesFile, "keep/`n$expectedExcludeEntry")
    $menuUninstallRun = Invoke-PipedMenuRun -GitSandbox $menuUninstallSandbox -Answers @('2', '2', '1', '1')
    $menuUninstallExcludes = Get-SandboxFileText -Path $menuUninstallSandbox.DefaultExcludesFile
    $menuUninstallOk = $menuUninstallRun.ExitCode -eq 0 -and $menuUninstallRun.Output.Contains('entry removed') -and (-not $menuUninstallRun.Output.Contains('to your global git excludes file')) -and ($menuUninstallExcludes -ceq "keep/`n")
    Add-Result -Condition $menuUninstallOk -CaseName 'menu uninstall removes the temp reports entry without asking' -FailMessage "$($menuUninstallRun.Output) excludes file: '$menuUninstallExcludes'"

    # Case 76: a root-anchored user line covers only the repository root, so
    # the installer still adds its entry, and uninstall removes only its own
    # pair.
    $anchoredSandbox = New-GitSandbox
    $anchoredContent = ".github/temp_reports/`n"
    New-Item -Path (Split-Path -Parent $anchoredSandbox.DefaultExcludesFile) -ItemType Directory -Force | Out-Null
    [System.IO.File]::WriteAllText($anchoredSandbox.DefaultExcludesFile, $anchoredContent)
    $anchoredRoot = New-TempRoot
    $null = Invoke-InstallerRun -GitSandbox $anchoredSandbox -Arguments (@('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $anchoredRoot) + $SubagentFlags)
    $anchoredAfterInstall = Get-SandboxFileText -Path $anchoredSandbox.DefaultExcludesFile
    Add-Result -Condition ($anchoredAfterInstall -ceq ($anchoredContent + $expectedExcludeEntry)) -CaseName 'root-anchored user line still gets the installer entry' -FailMessage "excludes file: '$anchoredAfterInstall'"
    $null = Invoke-InstallerRun -GitSandbox $anchoredSandbox -Arguments @('-Action', 'uninstall', '-Components', 'agents', '-Level', 'user', '-UserRoot', $anchoredRoot)
    $anchoredAfterUninstall = Get-SandboxFileText -Path $anchoredSandbox.DefaultExcludesFile
    Add-Result -Condition ($anchoredAfterUninstall -ceq $anchoredContent) -CaseName 'uninstall keeps the root-anchored user line' -FailMessage "excludes file: '$anchoredAfterUninstall'"

    # Case 77: a core.excludesFile set in a file the global config includes
    # receives the entry, because git reads the included value.
    $includeSandbox = New-GitSandbox
    $includedConfig = Join-Path $includeSandbox.Root 'included.gitconfig'
    $includedExcludesFile = Join-Path (Join-Path $includeSandbox.Root 'included') 'ignore'
    [System.IO.File]::WriteAllText($includedConfig, "[core]`n`texcludesFile = $($includedExcludesFile -replace '\\', '/')`n")
    [System.IO.File]::WriteAllText($includeSandbox.GlobalConfig, "[include]`n`tpath = $($includedConfig -replace '\\', '/')`n")
    $result = Invoke-InstallerRun -GitSandbox $includeSandbox -Arguments (@('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', (New-TempRoot)) + $SubagentFlags)
    $includedExcludes = Get-SandboxFileText -Path $includedExcludesFile
    $includeOk = $result.ExitCode -eq 0 -and ($includedExcludes -ceq $expectedExcludeEntry) -and ($null -eq (Get-SandboxFileText -Path $includeSandbox.DefaultExcludesFile))
    Add-Result -Condition $includeOk -CaseName 'included core.excludesFile receives the temp reports entry' -FailMessage "$($result.Output) excludes file: '$includedExcludes'"

    # Case 78: a non-ASCII core.excludesFile path lands exactly while the
    # console uses code page 437, which garbles git's UTF-8 output when it is
    # decoded with the console code page.
    $unicodeSandbox = New-GitSandbox
    $unicodeExcludesFile = Join-Path (Join-Path $unicodeSandbox.Root ('J' + [char]0x00FC + 'rgen')) 'ignore'
    [System.IO.File]::WriteAllText($unicodeSandbox.GlobalConfig, "[core]`n`texcludesFile = $($unicodeExcludesFile -replace '\\', '/')`n")
    $savedOutputEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(437)
        $result = Invoke-InstallerRun -GitSandbox $unicodeSandbox -Arguments (@('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', (New-TempRoot)) + $SubagentFlags)
    }
    finally {
        [Console]::OutputEncoding = $savedOutputEncoding
    }
    $unicodeExcludes = Get-SandboxFileText -Path $unicodeExcludesFile
    $unicodeSandboxEntries = @(Get-ChildItem -LiteralPath $unicodeSandbox.Root -Name | Sort-Object) -join ', '
    Add-Result -Condition ($result.ExitCode -eq 0 -and ($unicodeExcludes -ceq $expectedExcludeEntry)) -CaseName 'non-ASCII excludes path survives code page 437' -FailMessage "$($result.Output) sandbox entries: $unicodeSandboxEntries"

    # Case 79: with XDG_CONFIG_HOME unset, the entry follows git's home-folder
    # default, which git resolves through its own ~ expansion.
    $homeSandbox = New-GitSandbox -DefaultExcludesBase Home
    $result = Invoke-InstallerRun -GitSandbox $homeSandbox -Arguments (@('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', (New-TempRoot)) + $SubagentFlags)
    $homeExcludes = Get-SandboxFileText -Path $homeSandbox.DefaultExcludesFile
    Add-Result -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains("will add $TempReportsPattern to $($homeSandbox.DefaultExcludesFile)") -and ($homeExcludes -ceq $expectedExcludeEntry)) -CaseName 'home-folder default receives the temp reports entry' -FailMessage "$($result.Output) excludes file: '$homeExcludes'"

    # Case 80: an unparseable global config skips the entry under Windows
    # PowerShell 5.1 too, where git's error output must not abort the run.
    if (Get-Command powershell.exe -ErrorAction SilentlyContinue) {
        $brokenConfig51Sandbox = New-GitSandbox -DefaultExcludesBase Home
        [System.IO.File]::WriteAllText($brokenConfig51Sandbox.GlobalConfig, "[core`n")
        $brokenConfig51Root = New-TempRoot
        $result = Invoke-InstallerRun -Runtime windows-powershell -GitSandbox $brokenConfig51Sandbox -Arguments (@('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $brokenConfig51Root) + $SubagentFlags)
        $brokenConfig51Output = ConvertTo-ComparableOutput $result.Output
        $brokenConfig51Ok = $result.ExitCode -eq 0 -and $brokenConfig51Output.Contains('skipped (git could not read its config') -and (Test-AllFilesExist -Root $brokenConfig51Root -RelativePaths $RelativeLayout[0..3]) -and ($null -eq (Get-SandboxFileText -Path $brokenConfig51Sandbox.DefaultExcludesFile))
        Add-Result -Condition $brokenConfig51Ok -CaseName 'unreadable global git config skips the entry under Windows PowerShell 5.1' -FailMessage $result.Output
    }
    else {
        Write-Output 'SKIP [unreadable global git config under Windows PowerShell 5.1]: powershell.exe not found'
    }

    # Case 81: an empty core.excludesFile turns off git's global excludes
    # file, so the entry is skipped instead of written to a file git ignores.
    $emptySettingSandbox = New-GitSandbox
    [System.IO.File]::WriteAllText($emptySettingSandbox.GlobalConfig, "[core]`n`texcludesFile =`n")
    $result = Invoke-InstallerRun -GitSandbox $emptySettingSandbox -Arguments (@('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', (New-TempRoot)) + $SubagentFlags)
    $emptySettingOutput = ConvertTo-ComparableOutput $result.Output
    Add-Result -Condition ($result.ExitCode -eq 0 -and $emptySettingOutput.Contains('skipped (core.excludesFile is empty') -and ($null -eq (Get-SandboxFileText -Path $emptySettingSandbox.DefaultExcludesFile))) -CaseName 'empty core.excludesFile skips the entry' -FailMessage $result.Output

    # Case 82: a core.excludesFile that names a folder is skipped while
    # planning, so the run still exits 0 with the agents installed.
    $folderSandbox = New-GitSandbox
    $folderExcludesPath = Join-Path $folderSandbox.Root 'excludes-folder'
    New-Item -Path $folderExcludesPath -ItemType Directory -Force | Out-Null
    [System.IO.File]::WriteAllText($folderSandbox.GlobalConfig, "[core]`n`texcludesFile = $($folderExcludesPath -replace '\\', '/')`n")
    $folderRoot = New-TempRoot
    $result = Invoke-InstallerRun -GitSandbox $folderSandbox -Arguments (@('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', $folderRoot) + $SubagentFlags)
    $folderOutput = ConvertTo-ComparableOutput $result.Output
    $folderOk = $result.ExitCode -eq 0 -and $folderOutput.Contains('is a folder') -and $result.Output.Contains('Done: 7 copied, 0 overwritten.') -and (@(Get-ChildItem -LiteralPath $folderExcludesPath).Count -eq 0)
    Add-Result -Condition $folderOk -CaseName 'excludes path naming a folder skips the entry' -FailMessage $result.Output

    # Case 83: a read-only excludes file is skipped while planning instead of
    # failing after the squad files were copied.
    $readOnlySandbox = New-GitSandbox
    New-Item -Path (Split-Path -Parent $readOnlySandbox.DefaultExcludesFile) -ItemType Directory -Force | Out-Null
    [System.IO.File]::WriteAllText($readOnlySandbox.DefaultExcludesFile, "node_modules/`n")
    (Get-Item -LiteralPath $readOnlySandbox.DefaultExcludesFile).IsReadOnly = $true
    $result = Invoke-InstallerRun -GitSandbox $readOnlySandbox -Arguments (@('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', (New-TempRoot)) + $SubagentFlags)
    $readOnlyOutput = ConvertTo-ComparableOutput $result.Output
    $readOnlyOk = $result.ExitCode -eq 0 -and $readOnlyOutput.Contains('is read-only') -and $result.Output.Contains('Done: 7 copied, 0 overwritten.') -and ((Get-SandboxFileText -Path $readOnlySandbox.DefaultExcludesFile) -ceq "node_modules/`n")
    Add-Result -Condition $readOnlyOk -CaseName 'read-only excludes file skips the entry' -FailMessage $result.Output

    # Case 84: a marker line followed by a line the user edited is no longer
    # the installer's entry, so uninstall leaves both lines.
    $editedSandbox = New-GitSandbox
    $editedContent = "$TempReportsMarker`n.github/temp_reports/`n"
    New-Item -Path (Split-Path -Parent $editedSandbox.DefaultExcludesFile) -ItemType Directory -Force | Out-Null
    [System.IO.File]::WriteAllText($editedSandbox.DefaultExcludesFile, $editedContent)
    $result = Invoke-InstallerRun -GitSandbox $editedSandbox -Arguments @('-Action', 'uninstall', '-Components', 'agents', '-Level', 'user', '-UserRoot', (New-TempRoot))
    $editedAfterUninstall = Get-SandboxFileText -Path $editedSandbox.DefaultExcludesFile
    Add-Result -Condition ($result.ExitCode -eq 0 -and ($editedAfterUninstall -ceq $editedContent)) -CaseName 'uninstall keeps a marker followed by an edited line' -FailMessage "$($result.Output) excludes file: '$editedAfterUninstall'"

    # Case 85: a marked pair at the end of a file without a trailing newline is
    # still removed.
    $endOfFileSandbox = New-GitSandbox
    New-Item -Path (Split-Path -Parent $endOfFileSandbox.DefaultExcludesFile) -ItemType Directory -Force | Out-Null
    [System.IO.File]::WriteAllText($endOfFileSandbox.DefaultExcludesFile, "keep/`n$TempReportsMarker`n$TempReportsPattern")
    $result = Invoke-InstallerRun -GitSandbox $endOfFileSandbox -Arguments @('-Action', 'uninstall', '-Components', 'agents', '-Level', 'user', '-UserRoot', (New-TempRoot))
    $endOfFileAfterUninstall = Get-SandboxFileText -Path $endOfFileSandbox.DefaultExcludesFile
    Add-Result -Condition ($result.ExitCode -eq 0 -and ($endOfFileAfterUninstall -ceq "keep/`n")) -CaseName 'uninstall removes a marked pair without a trailing newline' -FailMessage "$($result.Output) excludes file: '$endOfFileAfterUninstall'"

    # Case 86: git keeps leading spaces, so an indented user line is a
    # different pattern and does not count as covered.
    $indentedSandbox = New-GitSandbox
    $indentedContent = "  **/.github/temp_reports/`n"
    New-Item -Path (Split-Path -Parent $indentedSandbox.DefaultExcludesFile) -ItemType Directory -Force | Out-Null
    [System.IO.File]::WriteAllText($indentedSandbox.DefaultExcludesFile, $indentedContent)
    $null = Invoke-InstallerRun -GitSandbox $indentedSandbox -Arguments (@('-Action', 'install', '-Components', 'agents', '-Level', 'user', '-UserRoot', (New-TempRoot)) + $SubagentFlags)
    $indentedAfterInstall = Get-SandboxFileText -Path $indentedSandbox.DefaultExcludesFile
    Add-Result -Condition ($indentedAfterInstall -ceq ($indentedContent + $expectedExcludeEntry)) -CaseName 'indented user line still gets the installer entry' -FailMessage "excludes file: '$indentedAfterInstall'"
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