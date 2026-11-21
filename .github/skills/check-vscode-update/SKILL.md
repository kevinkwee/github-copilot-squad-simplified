---
name: check-vscode-update
description: 'Decide whether a VS Code release breaks the squad. Use when: a VS Code update is announced or has just been installed, or the squad stops behaving as the README documents.'
argument-hint: '[optional: target VS Code version, for example v1.147 or v1.148]'
license: MIT
compatibility: 'Requires the GitHub CLI (gh), git, network access to raw.githubusercontent.com, and the public VS Code release and update endpoints.'
---

# Check a VS Code update

Development aid for this repository, not a shipped squad skill. Run it from the repository root. Read-only unless the user asks for a fix. Fetch the files into a folder under `$env:TEMP`, delete that folder afterwards, and confirm the check leaves `git status` unchanged.

## 1. Establish the versions

- **Target**: the version named in the request. Without one, it is the installed build when the user says the update is already applied, and otherwise the first entry of `https://update.code.visualstudio.com/api/releases/stable`. A request naming only a minor, such as `v1.147`, takes the newest `1.147.x` entry of that list, or `1.<minor>.0` when that minor has not shipped.
- **Installed**: first line of `code --version`.

`<install>` is the VS Code installation folder. On Windows, when `code` is not on `PATH`, read the version from `resources/app/package.json` inside the commit folder that `<install>/bin/code.cmd` references. The update is pending when the installed build is older than the target. A staged update that has not been applied is pending too, with `<install>/updating_version` holding its commit.

## 2. Resolve the two refs

**Head** is the target. When its tag does not exist yet, use `release/1.<minor>` and then `main`, and say which ref resolved.

**Base** is always older than head. It is the installed build when that build is older than head. Otherwise it is the release the user says they upgraded from, when that release is older than head. Otherwise it is the newest release of the minor before head's minor, for example `1.146.x` for head `1.147.0`. State that assumption in the report.

## 3. Diff the surfaces the squad runs on

The squad runs under two harnesses, and each owns a different part of the contract. The Copilot runtime harness covers sessions whose picker label is Copilot. Those sessions run on the Agent Host in the Agents window and in the editor's Chat view. Sessions on another harness, such as Claude or Codex, and Copilot CLI or Copilot Cloud sessions, are out of scope. The local harness covers a Local session in the editor's Chat view.

Fetch each path at base and at head from `https://raw.githubusercontent.com/microsoft/vscode/<ref>/<path>`. A 404 means the path moved, so list the folder at that ref with `gh api repos/microsoft/vscode/contents/<folder>?ref=<ref>` before going further, and retry any other failure. A folder cannot be fetched directly, so fetch each file it holds. Diff each pair with `git --no-pager diff --no-index --unified=4` and read every hunk.

**Copilot runtime harness**:

- `src/vs/platform/agentHost/node/copilot/sessionCustomizationDiscovery.ts`: asks the runtime where the agents, skills and instructions live and which hook files apply. The agent host watches the hook folders in the workspace and in the user home.
- `src/vs/platform/agentPlugins/common/pluginParsers.ts`, `src/vs/platform/agentHost/node/copilot/copilotPluginConverters.ts` and `src/vs/platform/agentHost/node/copilot/copilotSessionLauncher.ts`: the agent host parses the files and converts them into runtime configuration, including whether `include-custom-instructions` reaches the runtime.
- `package.json`: `copilotRuntimeVersion`, and the Copilot SDK dependency line, which is `@microsoft/copilot-sdk` on current `main` and `@github/copilot-sdk` at older refs.

**Local harness and editor**:

- `src/vs/workbench/contrib/chat/common/promptSyntax/config/promptFileLocations.ts`: the discovery folders.
- `src/vs/workbench/contrib/chat/common/promptSyntax/languageProviders/promptValidator.ts`: the frontmatter keys the editor validates.
- `src/vs/workbench/contrib/chat/common/promptSyntax/hookTypes.ts`, `hookSchema.ts` and `hookCompatibility.ts`: the hook documents the editor accepts.
- `src/vs/workbench/contrib/chat/common/promptSyntax/computeAutomaticInstructions.ts`: how `AGENTS.md` reaches a request.

**Agents window only**: `src/vs/sessions/skills/<name>/SKILL.md` for `commit`, `create-pr`, `create-draft-pr`, `update-pr` and `merge`.

**File formats only**: `extensions/copilot/assets/prompts/skills/agent-customization/references/`. Its hooks page describes the older Local hook document, so never report the squad's flat `permissionDecision` as broken on that page alone.

List `src/vs/workbench/contrib/chat/common/promptSyntax`, its `config`, `service` and `languageProviders` subfolders, `src/vs/platform/agentPlugins/common` and `src/vs/platform/agentHost/node/copilot` at both refs. Add every file whose name contains `prompt`, `hook`, `customization` or `agent`, ignoring case, and follow every import a diff adds into another file.

Handle the files with no copy at the other ref before classifying the rest. A file only at head is new, so diff `/dev/null` against it and read it whole. A file only at base was renamed, moved or removed, so find the commit with `gh api "repos/microsoft/vscode/commits?sha=<head>&path=<path>&per_page=1"` and read its entry in `gh api --paginate repos/microsoft/vscode/commits/<sha> --jq '.files[]'`, under `previous_filename` for a rename and `filename` otherwise. Diff the base copy against the renamed path, and repeat the lookup when that path is missing at head too. For a removal, diff it against the file the commit added or changed that received the removed file's exports, or record the removal itself when no file did.

Then classify every difference as additive, behavior-only or contract-breaking, and compare the contract with what this repository ships.

- Discovery folders: the installer writes `.github/agents`, `.github/skills`, `.github/hooks` and `.github/scripts` at repo level, or the same four under `%USERPROFILE%\.copilot\`. Agents, skills and hooks are the ones discovered there.
- Agent frontmatter in `agents/*.agent.md`: `name`, `description`, `user-invocable` and `disable-model-invocation`, plus `include-custom-instructions` on Owl and Cat. The editor flags that key for an agent with no target, which is expected, so do not treat it as a break.
- Skill frontmatter in `skills/*/SKILL.md`: `name`, `description`, `argument-hint`, `license` and `compatibility`.
- Hook JSON in `hooks/*.json`: `version`, `hooks.PreToolUse`, `type`, `matcher`, `powershell`, `bash` and `timeout`, with the matcher names `Bash` and `Agent`. The workbench schema reads a file with `version` as the Copilot CLI format and deprecates the form without it, so never report the squad's `PreToolUse` and `timeout`, which the squad keeps on purpose, as a break on that schema alone.
- Deny contract in `scripts/guard-*/guard-*.ps1`: exit 0 on every path, and the flat `permissionDecision` with `permissionDecisionReason` on stdout.

## 4. Read the release notes and the runtime changelog

Fetch `https://raw.githubusercontent.com/microsoft/vscode-docs/main/release-notes/v1_<minor>.md` for every minor from base's to head's, and search each for `agent`, `skill`, `hook`, `customization`, `instruction` and `prompt`.

Fetch `https://raw.githubusercontent.com/github/copilot-cli/main/changelog.md`, and read every entry after base's `copilotRuntimeVersion`, up to and including head's, matching the changelog heading to the release number without its suffix, so `1.0.111-0` reads as `1.0.111`. Treat the changelog as intent, never as proof.

## 5. Report

Report one table with a row per check and per harness, then the verdict, then what the squad does on any behavior the release changed. When no break is found and the Copilot runtime harness row is unverified, the verdict reads "no break found in the VS Code sources, runtime unverified".

Close with the next action:

- no break, additive, or behavior-only with nothing the squad relies on: say what changed and keep the squad as it is.
- a discovery folder, frontmatter key, hook field, matcher name or deny shape changed: update the file that carries it, which is an agent file, a skill file, a hook JSON or a guard script.
- a VS Code source file changes behavior the squad relies on without changing a format, such as the option `copilotSessionLauncher.ts` passes to decide whether repository hooks load: treat it as contract-breaking even when the changelog is silent, and name the squad file that depends on that behavior.
- a built-in workflow skill changed: update the squad skill that composes with it, which the README section "Working with the built-in workflow skills" lists in its table.
- `copilotRuntimeVersion` moved, or the Copilot SDK dependency line moved or was renamed: mark the Copilot runtime harness row unverified, whether the update is pending or installed, because nothing in this check runs the runtime. Give the changelog range and the source diff as the basis for the risk, and tell the user that what verifies that row is a Copilot session on the new build in which each installed guard still denies one call that breaks its rule.
- when `include-custom-instructions` starts reaching the runtime: correct the claim in the "Prompt File Frontmatter Contract" section of `AGENTS.md` and in the "Reviewers read `AGENTS.md` themselves" section of `README.md`, and keep the reviewers' own read of `AGENTS.md`, because other harnesses still withhold it.

When the user asks for a fix, also update `README.md`, `AGENTS.md` and any `test-install.ps1` case that asserts the installed layout, frontmatter or counts, plus `install.ps1` when the change moves an installed path. Then run `pwsh -NoProfile -File test-install.ps1` and the battery for each guard script touched.

Never run `install.ps1` against the user's real profile as part of the check. The installer battery already covers install and uninstall against disposable roots.