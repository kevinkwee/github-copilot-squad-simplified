---
name: agents-md
description: 'Create a project AGENTS.md from the bundled template, or adapt an existing AGENTS.md to align with it. Use when: setting up a new project, bootstrapping agent guidance where no AGENTS.md exists, or auditing and updating an existing AGENTS.md against the template rules.'
argument-hint: '[create | adapt] [existing AGENTS.md path, optional]'
---

# AGENTS.md Create and Adapt

Two procedures:

- **create**: produce a new project `AGENTS.md` from the bundled template, filled with project-specific content.
- **adapt**: align an existing `AGENTS.md` with the template while preserving deliberate project-specific decisions.

## Template source

The template is bundled in this skill: [assets/AGENTS-template.md](./assets/AGENTS-template.md). It is the canonical template. Read it before running either mode.

## Shared rules (both modes)

- The output is an instruction file for AI coding agents. It is prose, not code, but the writing rules below still apply to it: no em-dashes or en-dashes, no ASCII hyphen used as a clause separator, and prefer periods or commas over semicolons and colons.
- The project's deliberate decisions are authoritative. Never silently delete or weaken project-specific content.
- A difference between an existing file and the template falls into exactly one of three buckets, each with its own handling:
  1. **Outdated pattern** (the template deliberately retired it): converge to the template wording.
  2. **Missing template section**: add it, with real project content where the repo supplies it and a fill-in placeholder otherwise.
  3. **Deliberate project-specific choice**: keep it as is, and report it as an intentional difference. Never "fix" one.
- Ask only for facts the repo cannot answer, and use the ask tool with `allowFreeformInput` on any question that offers options. Never request secrets.

## Mode selection

- No `AGENTS.md` at the target location, or the user asked to create one: use **create**.
- An existing `AGENTS.md` is given or found: use **adapt**.
- Ambiguous (for example a placeholder-only file exists, or the user says "set up AGENTS.md" while one already exists): ask which mode they want.

## Create mode

1. **Inspect the repo first.** Never ask for facts the code already answers. Collect: runtime and toolchain versions (`pyproject.toml`, `package.json`, `go.mod`, `Dockerfile`, CI configs, etc), the package manager plus the canonical test/lint/format/build commands, project layout and architectural style, the test framework plus coverage tooling and configured thresholds, migration tooling, external services, and existing documentation conventions.
2. **Ask** only for what the code cannot answer: the project purpose one-liner, deliberate conventions not yet written down, the coverage minimum the team actually enforces, and any template sections known to be unnecessary for this project.
3. **Draft from the template.**
   - Fill every `<!-- -->` placeholder with project content.
   - Delete the sections marked delete-if-unused that do not apply (Project Map, Language and Runtime Constraints, and Migrations are the usual candidates).
   - Rewrite language-specific examples to the project's stack while keeping the principle (for example, Ruff commands become the project's linter commands, pytest becomes its test runner).
   - Resolve the tunable numbers where the template comments ask for a choice (currently the coverage minimum).
   - Keep every other rule intact. Do not invent new rules. Do not ship the template untouched; every kept section must carry project-specific content.
4. **Write** to the requested path, defaulting to the repo root `AGENTS.md`. For multi-folder or multi-repo workspaces, propose the root file plus the Project Map pattern (and folder-level files where genuinely needed) before writing more than one file.
5. **Validate**, and fix what fails:
   - no leftover placeholders (`rg -n '<!--' AGENTS.md` returns nothing)
   - no em-dash or en-dash characters, and no ASCII hyphen clause separators (check `rg -n '(—|–)'` and `rg -n ' - '`)
   - every recorded command matches what the project config actually provides (verify against package scripts, `pyproject.toml`, or the Makefile)
   - internal anchors (for example the Rule of Thumb link) still resolve
6. **Report**: sections filled, sections deleted and why, tunables chosen, and the final file path.

## Adapt mode

1. **Read** the existing `AGENTS.md` (the user-supplied path, otherwise the repo root plus any mapped folder files) and the bundled template.
2. **Produce a gap analysis** with concrete, locatable findings, sorted into the three shared-rule buckets:
   - template sections that are missing
   - lines carrying outdated patterns, each paired with the modern template equivalent. Typical examples: mechanical numeric thresholds the template dropped, `should_[expected]_when_[condition]` test naming, em/en dashes and hyphen clause separators, unconditional word bans such as "and/or/then", and coverage targets stated as both a target and a minimum.
   - deliberate project-specific decisions, listed under "kept, flagged" (the project rule wins)
3. **Present the change plan** as add/modify/keep lists with a one-line rationale each. Apply nothing yet. Mechanical fixes (dash rule violations, dead anchors) can be pre-approved in bulk; say so explicitly in the plan.
4. **Get confirmation** through the ask tool (with freeform input) for the wording changes. The keep/flag list needs no approval because it changes nothing.
5. **Apply the approved changes only**, then **validate** as in create mode (placeholders, dashes, commands, anchors), and re-check that section references still resolve after the edits.
6. **Report**: the added list, the modified list, and the kept-and-flagged list, so the user can trace every change back to a decision.
