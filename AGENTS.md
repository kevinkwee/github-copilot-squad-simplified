# AGENTS.md

This file provides guidance to AI coding agents when working with code in this repository.

## Project Overview

This repository ships a simplified Copilot Squad for VS Code Copilot custom agents: the agent prompt files under `agents/`, the squad skills under `skills/`, the two PreToolUse hooks (`guard-pwsh-continuation` and `guard-subagent-delegation`) with their companion scripts under `hooks/` and `scripts/`, and the installer `install.ps1` with its test battery `test-install.ps1`. The installed squad runs Capybara (entry point and implementer) that loops with Owl (code review) and, in Trio mode, Cat (comment and docstring review).

`README.md` is the product documentation and the authority on the squad's runtime flow. Keep it in sync with behavior changes.

## Prerequisites

- Windows PowerShell 5.1 or newer runs `install.ps1`. pwsh 7 runs the test batteries and the guard scripts.
- No package manager, external services, or database. The batteries need only pwsh 7 on Windows.
- VS Code with Copilot custom agents support matters only for running the installed squad, not for developing it.

## Language and Runtime Constraints

The project is pinned to two PowerShell tiers. Check the `#Requires` line before using newer syntax.

- `install.ps1` must stay compatible with Windows PowerShell 5.1 (`#Requires -Version 5.1`). Unavailable there, among others: the ternary operator (7.0), the null-coalescing operators `??` and `??=` (7.0), chain operators as statement separators (`&&` and `||` between PowerShell statements, 7.0), and `ForEach-Object -Parallel` (7.0). Use `if`, explicit `$null` checks, and sequential statements instead.
- The guard scripts and all test batteries pin pwsh 7 (`#requires -Version 7`) and may use 7-only syntax.

Windows shell rules for generated terminal commands:

- The escape character is a backtick. Prefer single-quoted strings for regex and anything containing double quotes, and double the single quote to embed one.
- Never suggest a command that would leave the terminal at the `>>` continuation prompt. The guard hook denies such fresh-shell commands and the session stalls.
- Address Windows paths to tools and users with backslash separators. Inside scripts, build paths with `Join-Path` and `[System.IO.Path]` members instead of string concatenation.

## Core Philosophy

### Trade-off Priority (when conflicts arise)

1. **Correctness**: code does what it should
2. **Simplicity and readability**: code is easy to understand
3. **Testability**: code is easy to test
4. **Performance**: code is fast enough
5. **Abstraction and reuse**: code is DRY

### Ground Rules

- Read and understand existing code before modifying it.
- Treat the project's existing patterns and code as a starting point, not as evidence of correctness. Legacy code can carry bad practices, over-complex code, and code smells. If something looks wrong, speak up and write new code the right way (correct, secure, performant, readable, maintainable) instead of propagating the problem, even if that means departing from the existing code.
- Isolate new code from legacy where possible, and never copy legacy code into new code without reviewing its quality.
- If a requirement is ambiguous, ask before writing code.
- Prefer incremental delivery: core logic first, then edge cases, then refinements.
- Do not overengineer. Build for today's requirements, not hypothetical future ones.
- Do not break foundation code. Changes to widely-depended-on modules ripple into every dependent, so verify dependents before changing a shared field, method, or contract.

## Design Principles

### SOLID

| Principle | Rule | Common Mistake |
|-----------|------|----------------|
| **SRP** (Single Responsibility) | Each class/function/file has ONE reason to change. If you need "and" or "or" to describe it, split it. | Interpreting SRP as "one function per class." SRP means one *axis of change*. |
| **OCP** (Open/Closed) | Add new behavior by writing new code, not modifying existing code. Use polymorphism or strategy patterns where change is expected. | Over-engineering with premature abstractions. Apply OCP where you have *evidence* of changing requirements. |
| **LSP** (Liskov Substitution) | Subclasses must honor the contract of their parent. Prefer composition over inheritance when "is-a" is not strict. | Overriding a method to throw `NotImplementedError` or do nothing. |
| **ISP** (Interface Segregation) | Define small, role-specific interfaces. Clients depend only on methods they use. | Creating one "service" interface stuffed with methods for many unrelated roles. |
| **DIP** (Dependency Inversion) | Depend on abstractions at module boundaries, not concrete implementations. | Confusing DIP with "just use dependency injection." DIP is about inverting the *direction of source-code dependency*. |

### DRY (Don't Repeat Yourself)

- Extract duplicated logic when the copies are the same business rule and the duplication already costs more than a shared implementation would.
- Single source of truth for configuration, constants, and schema definitions.
- **Prefer duplication over wrong abstraction.** Two pieces of code that look similar but serve different business purposes are NOT duplication, because merging them creates accidental coupling.
- "Wrong abstraction" means: premature generalization, unclear purpose, or coupling unrelated concerns.

### KISS (Keep It Simple)

- Choose the simplest implementation that satisfies current requirements.
- Prefer standard library solutions over custom implementations.
- A plain function call beats metaprogramming. A hashtable beats a class when all you need is data grouping.
- Do not add design patterns, abstractions, or frameworks "just in case."

### YAGNI (You Aren't Gonna Need It)

- Implement features only when there is a concrete, current requirement.
- Do not build generic/extensible frameworks before you have at least two concrete use cases.
- Delete speculative code and unused feature flags regularly.
- Three similar lines of code is better than a premature abstraction.

## Code Quality

Scripts start with `Set-StrictMode -Version 2.0` and `$ErrorActionPreference = 'Stop'`, and bind parameters with `[CmdletBinding()]` plus typed, validated `param()` entries (`ValidateSet`, `Parameter(Mandatory)`). PowerShell is dynamically typed, so declarations and early validation are the substitute for static typing.

### Naming and Structure

- Function names use approved PowerShell verbs and noun singulars (`Get-RewrittenHookJson`, `Invoke-InstallPlan`).
- One function does one thing. Guard clauses and early returns keep the happy path at the lowest nesting level.
- No generic names. Repeated strings and numbers become named constants at the top of the script (see `$AgentFiles`, `$HookUserPlaceholder`).
- Prefer immutable hashtables for plans. Mutate only local variables.

### Writing Rules

- No em-dashes, en-dashes, or other non-ASCII dash characters in code, comments, prompt files, README, or report files.
- The ASCII hyphen is for compound words, prefixes, and numeric ranges only, never a clause separator. When a dash would separate clauses, end the sentence with a period or comma, or rephrase.
- Prefer periods and commas over semicolons and colons unless genuinely needed.
- Comments explain WHY, never WHAT. Prefer self-explanatory code and names over comments. No section separator comments, no commented-out code, no TODO comments without a findable reference, and no change narration ("previously", "moved to", "was removed").
- Every comment, docstring, and prompt-file paragraph must make sense to a cold reader with no prior context. State constraints directly instead of referencing unavailable documents.

### Linting and Formatting

- No lint or format tool is configured. Do not add one as a side effect of another task.
- The quality gate is the two test batteries (see Testing). Run the battery that covers the touched script.

## Architecture

```
github-copilot-squad-simplified/
├── agents/                            # agent prompt files: Capybara, CapybaraDuo, Owl, Cat
├── skills/                            # squad skills: agents-md, commit-message, pr-description
├── hooks/                             # hook config templates: guard-pwsh-continuation, guard-subagent-delegation
├── scripts/                           # hook companion scripts and batteries, one folder per hook
├── install.ps1                        # interactive menu or flags, install and uninstall
├── test-install.ps1                   # installer test battery
└── README.md                          # product documentation
```

### Prompt File Frontmatter Contract

- Agent files carry `name`, `description`, `user-invocable`, and `disable-model-invocation` and nothing else. They never pin `model:` or `target:` frontmatter: the Agents window ignores `target:` and mishandles a pinned `model:` that comes from an extension, and subagents instead run on the model and reasoning effort the delegation rule sets when the calling tool supports choosing both, and otherwise on the tool's defaults.
- `Capybara.agent.md` and `CapybaraDuo.agent.md` carry per-subagent placeholders inside their Subagent Delegation Rules: `__OWL_MODEL__` and `__OWL_REASONING_EFFORT__` for Owl, plus `__CAT_MODEL__` and `__CAT_REASONING_EFFORT__` for Cat in `Capybara.agent.md` only. The model values may be the full id or a distinctive part of the name, for example `GLM-5.3`, and they do not have to match exactly. The delegation rule runs each reviewer on the first available model that matches its value, and asks the user how to proceed when nothing available matches. The repo always ships the placeholders. The installer fills them (flags `-OwlModel`, `-OwlReasoningEffort`, `-CatModel`, `-CatReasoningEffort`). An installed copy with a placeholder left in place is a broken install.

## Error Handling

- Scripts set `$ErrorActionPreference = 'Stop'`, catch errors at the top level, print them via `Write-Error`, and exit 1. Failures abort the run before misleading the user, and template rewrites resolve during planning so a broken template aborts before any file is written.
- The guard scripts invert the exit-code contract on purpose: the Copilot SDK harness deny-fails on a non-zero hook exit, so each script exits 0 on every path and communicates a deny only through its JSON output.
- Do not swallow exceptions silently, and do not catch the generic `Exception` where a specific condition is meant. Rethrow with context when a lower layer detects a broken assumption.

## Observability

- User-facing progress goes through `Write-Host`, with `Write-Warning` for degraded states and `Write-Error` for top-level failures.
- Each guard script's stdout is contract JSON read by the harness. Never write diagnostics to it.
- Never echo secrets, tokens, or personal data into any output.

## Testing

> **Test code is production code.** It receives the same care, review, and quality standards.

### How to Run Tests

Three out-of-process batteries exist, all run from the repo root:

```powershell
# Installer battery: install.ps1 and uninstall flows against disposable temp roots
pwsh -NoProfile -File test-install.ps1

# Shell guard battery: guard-pwsh-continuation.ps1 parse and deny decisions
pwsh -NoProfile -File scripts/guard-pwsh-continuation/test-guard-pwsh-continuation.ps1

# Delegation guard battery: guard-subagent-delegation.ps1 deny and allow decisions
pwsh -NoProfile -File scripts/guard-subagent-delegation/test-guard-subagent-delegation.ps1
```

- Run the whole battery that covers the touched script. Never cherry-pick single cases, because the batteries are cheap and cases share setup.
- Each battery prints per-case `PASS`/`FAIL` lines and exits 1 when any case fails. Zero failures is the gate. There is no coverage tooling and no coverage threshold.
- Add a new `# Case N: purpose` block for every behavior change. Assert on observable outcomes (exit codes, reported summary lines, resulting file trees, rewritten content), not on internals of the script under test.

### Case Quality

- Cover both the happy path and adversarial cases: unexpected input values, boundary values, malformed answers at prompts, error states, and states that must not happen.
- When a case fails, ask first whether the production code is wrong, not the test. Do not loosen an assertion to make a case pass without understanding why it failed.
- Batteries run child processes with clean inputs and never touch the real `$HOME`, the real project, or anything outside their disposable roots. Keep that isolation intact.

## Code Review

### Priority (blockers first)

1. **Security & PII**: no PII in output, no hardcoded secrets, input validation at boundaries
2. **DRY**: no duplicated logic the same business rule would force to change together
3. **File Structure**: single responsibility per file, naming respected
4. **Contract fidelity**: exit codes, JSON stdout, placeholder rewrites, and 5.1 compatibility hold
5. **Code Quality**: SOLID, strong validation, error handling
6. **Testing**: both happy path and adversarial cases in the batteries

### Review Questions for Tests

1. "Are there BOTH happy path AND adversarial cases?"
2. "Would these cases catch a regression if someone broke the logic?"
3. "Are there edge cases or failure modes that aren't being tested?"
4. "If I remove a line of installer or guard logic, will at least one case fail?"

### Legacy Code

- Do NOT prolong bad patterns. Even if the surrounding code is bad, write good code.
- Do NOT copy-paste from legacy code without reviewing quality.
- Isolate new code from legacy where possible.

## Documentation

Update `README.md` when you add or change installer flags, menu prompts, placeholders, frontmatter rules, or the hook contract. Update this file when you add scripts, change architecture, or change repo-wide conventions. Both must stay in sync with the codebase.

## Key Concepts

1. **Squad runtime flow.** Capybara implements, runs the Owl code review loop, then the Cat comment/docstring loop (Trio), each with its own 5-iteration cap, and writes `implementation_{n}.md` reports under `.github/temp_reports/{timestamp}_{objective}/`. Owl writes `review_{n}.md`, Cat writes `docstring_review_{n}.md`. See README "How the flow works" and `agents/Capybara.agent.md`.
2. **Installer plan.** `install.ps1` runs a menu (no arguments) or acts on flags, builds a plan of file operations with optional rewritten content (`RewrittenContent`), and writes only after the plan resolves. Rewrites resolve during planning so a broken template aborts before anything is written. The subagent delegation hook travels with the agents component by default, or per `-SubagentGuard Skip` and `Force`, so an agents-only plan also carries its file operations. Uninstall maps fixed squad paths, removes only those, and reports name-matching leftovers. See `install.ps1`.
3. **Placeholder contracts.** Each hook JSON's `C:/Users/YOUR-PROFILE` (user level) or `C:/Users/YOUR-PROFILE/.copilot/scripts` (repo level) becomes the real profile or `.github/scripts` path. The agent files' `__OWL_MODEL__` and `__OWL_REASONING_EFFORT__` (both Capybara files) plus `__CAT_MODEL__` and `__CAT_REASONING_EFFORT__` (`Capybara.agent.md` only) become the per-subagent values the installer prompts for, or takes via `-OwlModel`, `-OwlReasoningEffort`, `-CatModel`, and `-CatReasoningEffort`. Every rewrite must leave no placeholder behind, and a template missing its expected placeholder aborts the run.
4. **Shell guard contract.** The hook fails closed in the harness, so the companion script always exits 0 and denies only via `permissionDecision` JSON. It checks only fresh shell PowerShell commands from the Copilot SDK harness, uses the PowerShell parser's incomplete-input signal to detect `>>` continuation, and lets non-Windows sessions and already-running-process tools pass without parsing. See `scripts/guard-pwsh-continuation/guard-pwsh-continuation.ps1`.
5. **Subagent delegation guard contract.** The same exit-code contract applies, and the script denies a subagent tool call (reported as `Agent`, with `Task` and `task` fallbacks) whose `agent_type` names a squad reviewer (Owl, Cat, case-insensitive) when `model` or `reasoning_effort` is missing. Enforcement is presence only, non-reviewer and unclassifiable calls pass through, the deny reason instructs a retry with both fields or surfacing the limitation to the user, and the hook JSON budgets a 60-second timeout because a harness-side timeout fails open. See `scripts/guard-subagent-delegation/guard-subagent-delegation.ps1`.

## Rule of Thumb

**When in doubt, choose simplicity. When trade-offs arise, follow the priority order in [Core Philosophy](#core-philosophy).**
**Build for correctness first. Optimize later. Test always.**