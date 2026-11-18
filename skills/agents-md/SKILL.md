---
name: agents-md
description: 'Create a project AGENTS.md from the bundled template, or adapt an existing AGENTS.md to align with it. Use when: setting up a new project, bootstrapping agent guidance where no AGENTS.md exists, or auditing and updating an existing AGENTS.md against the template rules.'
argument-hint: '[create | adapt] [AGENTS.md path, optional]'
license: MIT
---

# AGENTS.md Create and Adapt

Two procedures:

- **create**: copy the bundled template to a new project `AGENTS.md` and fill the copy in place with project-specific content.
- **adapt**: align an existing `AGENTS.md` with the template while preserving deliberate project-specific decisions.

## Template source

The template is bundled in this skill: [assets/AGENTS-template.md](./assets/AGENTS-template.md). It is the canonical template. Read the whole content before running either mode.

## Shared rules (both modes)

- The output is an instruction file for AI coding agents. It is prose, not code, but these writing rules still apply to it: no em-dashes, en-dashes, or other non-ASCII dashes, no ASCII hyphen used as a clause separator, and prefer periods or commas over semicolons and colons.
- The project's deliberate decisions are authoritative. Never silently delete or weaken project-specific content.
- The template holds two kinds of rules, and each kind changes on different evidence:
  - **General rules** are principles that hold for any project, such as the trade-off priority, the ground rules, the design principles, code quality, security, PII, error handling, and test quality. Apart from deleting a rule with nothing to apply to and making the changes the template's own comments ask for, only a deliberate decision or project-wide requirement the user states can change one. A pattern the repo merely shows is not enough, because existing code is not evidence of correctness.
  - **Conventions** are the parts of a rule that pick one of several equally valid options, such as the test name pattern (including the template's advice against `should`/`when` ceremony) and test class grouping, the boolean name form, the file name scheme, log field names, and the layer names. A convention the project's code and config follow consistently replaces the template's convention, and so does one the user states. Replacing a convention also replaces the template lines that only fit it, but never changes a general rule in the same section, such as the ban on generic file names or what a layer must not do.
- Treat a rule that could be either kind as a general rule. The writing rules in the first shared rule are not conventions, and they always apply.
- A template section or rule with nothing to apply to, in the project or in the requirements the file is built from, does not belong in the project's file, such as Layer Rules in a project with no layers or Logging in a project that logs nothing. When unsure whether it applies, keep it.
- The Docs Setup subsection belongs to the `project-docs` skill, whose bootstrap writes it. Create deletes it in every case, and adapt never counts the subsection or any of its fields as missing. When the user asks to set up the docs now, run the `project-docs` bootstrap after the `AGENTS.md` work, and let it write the subsection. Adapt also leaves a Docs Setup already in the file to `project-docs`, including any placeholders still in it.
- A tunable number the user leaves unanswered, such as the coverage minimum, keeps the template's value, and the report lists it as a default to confirm.
- A line needs an answer only when it does not read as complete without one, so a rule with an optional fill-in, such as the secret manager in a security rule, never counts as a line that needs an answer.
- Ask only for facts that neither the repo nor the task request answers. Never request secrets.

## Mode selection

- No `AGENTS.md` at the target location, which defaults to the repo root: use **create**.
- An `AGENTS.md` exists at the target location: use **adapt**.
- Ambiguous (for example a placeholder-only file exists, the user asks to create or "set up" an `AGENTS.md` while one already exists at the target location, or the user asks to adapt while none exists there): ask which mode they want.

## Create mode

1. **Inspect the repo first.** Never ask for facts the code already answers. Collect: runtime and toolchain versions (`pyproject.toml`, `package.json`, `go.mod`, `Dockerfile`, CI configs, etc.), the package manager plus the canonical test/lint/format/build commands, project layout and architectural style, the test framework plus coverage tooling and configured thresholds, migration tooling, external services, and the existing documentation style.
2. **Ask** only for what neither the code nor the task request answers, such as the project purpose one-liner, deliberate decisions and conventions not yet written down, the coverage minimum the team actually enforces, the optional fill-ins the repo does not show (the secret manager, the audit command, the approved identifiers), and any template sections known to be unnecessary for this project.
3. **Copy the template** to the requested path, defaulting to the repo root `AGENTS.md`. For multi-folder or multi-repo workspaces, propose the root file plus the template's Project Map section (and folder-level files where genuinely needed) before writing more than one file. A folder-level file holds only its module's rules, because cross-cutting rules stay in the root file.
   - Copy `assets/AGENTS-template.md`, resolved relative to this `SKILL.md`, byte for byte with a file-copy command, for example `Copy-Item` in PowerShell or `cp` in a POSIX shell. Never copy over an existing file.
   - Do not retype the template into a new file. A long file written from memory tends to come out shortened, paraphrased, or missing whole sections.
   - Only when no tool in the session can copy a file, write the template's full text out unchanged in section-sized parts before any edit. Then confirm the written file has as many lines as the template, so the edits start from a complete copy.
4. **Fill the copy in place** with targeted edits, never by rewriting the whole file.
   - Retitle the copy `# AGENTS.md` and delete the template's opening instruction comment.
   - Act on every template placeholder, meaning each `<!-- ... -->` comment and the sample content a comment asks to replace, such as the `<layer_or_package>` tree or the example test command. Fill it with project content, or make the change the placeholder asks for in the lines it points at. Then remove the comment.
   - If the user does not answer a question, leave out the lines that need that answer, and write no placeholder for them.
   - Delete each section or rule with nothing to apply to, as the shared rules describe, such as linter suppression rules in a project with no linter. The usual candidates include Project Map, Language and Runtime Constraints, Migrations, and the Security subsections for concerns the project does not have. Also delete the sections the user named as unnecessary in step 2. In a folder-level file, also delete the sections the root file covers, as step 3 describes.
   - Delete the Docs Setup subsection, as the shared rules describe.
   - Rewrite language-specific examples to the project's stack while keeping the principle (for example, Ruff commands become the project's linter commands, pytest becomes its test runner).
   - Resolve the tunable numbers where the template comments ask for a choice (currently the coverage minimum), as the shared rules describe when the user leaves one unanswered.
   - Replace each template convention with the project's own when the project's code and config consistently follow a different one, or when the user states a different one. A replaced convention never changes a general rule, as the shared rules describe.
   - Apart from the edits above, change a general rule only where a deliberate decision or project-wide requirement the user states in step 2 or in the task request contradicts it.
   - Add the rules this project needs beyond the template, each in the section it belongs to. Base every added rule on a deliberate decision or project-wide requirement the user states in step 2 or in the task request, or on a convention the repo's code and config consistently follow. Do not add rules that rest on guesswork or general taste, and never add one that contradicts a general rule.
   - Keep the rest of the template exactly as copied, and do not reword, condense, or merge its general rules beyond the edits above.
5. **Validate** each file written, and fix what fails. The commands below check the root `AGENTS.md`. Point them at any other file written, or use the session's search tool when `rg` is unavailable.
   - no template placeholders left (`rg -n '<!--|\(Template\)|<layer_or_package>|path/to/module-a|replace with the project|Example \(a Python' AGENTS.md` finds none, apart from comments the project keeps on purpose, such as a linter directive)
   - no non-ASCII dashes and no ASCII hyphen clause separators (`rg -n '[\p{Pd}&&[^-]]' AGENTS.md` and `rg -n '\S --? ' AGENTS.md` find no violations, where a `\S --? ` hit inside code, or a lone `-` that marks an empty table cell, does not count as one)
   - every recorded command matches what the project provides (verify against its config, such as package scripts, `pyproject.toml`, a Makefile, CI workflows, or wrapper scripts), or, when the file is built before that config exists, what the task's plan sets up
   - internal anchors (for example the Rule of Thumb link) and mentions of other sections still resolve
6. **Report**:
   - sections filled, and tunables chosen or kept at the template's default
   - language-specific examples rewritten for the project's stack
   - sections and rules deleted, each with the reason
   - conventions replaced, each with its source (repo or user)
   - rules added, each with its source (repo, step 2, or task request)
   - general rules changed, each with the user statement behind it
   - repo patterns left out because they contradict a general rule
   - lines left out because their questions went unanswered, which a later adapt run asks about again
   - optional fill-ins left empty, such as the audit command, for the user to add by hand
   - the final file path

## Adapt mode

Each difference between the existing file and the template falls into exactly one of three buckets, each with its own handling:

1. **Outdated pattern** (the template deliberately retired the pattern, and the project does not follow it as its convention): converge to the template wording, keeping the project's own values, such as its coverage minimum. Where the project follows a different convention of its own that the shared rules let replace the template's, converge to that convention instead.
2. **Missing template section or line** that applies to the project: add it, with real project content where the repo supplies it. Ask the user for the facts the repo cannot supply. Template lines that apply but are missing from a section the file already has count here too, such as a line an earlier create or adapt run left out because its question went unanswered. A template placeholder still in the file counts here too, and is filled or acted on as create step 4 describes. In a folder-level file, a section the root file covers is not missing. A template line the file already covers with its own version is not missing, so it is never bucket 2, whether that version is reworded, outdated, or replaced by a project rule. A template line that only fits a convention the project replaced belongs in bucket 3.
3. **Deliberate project-specific choice**, including a convention the project follows and a template section or rule left out because it has nothing to apply to, as the shared rules describe: keep it as is, and report it as an intentional difference. Never "fix" it.

When unsure whether a difference is outdated or deliberate, treat it as deliberate and ask about it in the plan.

Steps:

1. **Read** the existing `AGENTS.md` (the user-supplied path, otherwise the repo root plus any mapped folder files) and the bundled template, and inspect the repo as create step 1 describes.
2. **Produce a gap analysis** with concrete, locatable findings:
   - lines carrying outdated patterns, each paired with the modern equivalent (bucket 1). Typical examples: mechanical numeric thresholds the template dropped, `should_[expected]_when_[condition]` test naming the project's tests do not follow (paired with the pattern they do follow, or with the template's pattern when they follow none), non-ASCII dashes and hyphen clause separators, unconditional word bans such as "and", "or", and "then", and coverage targets stated as both a target and a minimum.
   - template sections that apply to the project and are missing, template lines that apply but are missing from a section the file already has, and template placeholders still in the file, each with the questions for the facts the repo cannot supply (bucket 2)
   - deliberate project-specific decisions, listed under "kept, flagged" (bucket 3, the project rule wins)
   - template sections or rules in the file with nothing to apply to, proposed for removal (outside the buckets, because each sits in both the file and the template)
   - recorded commands that do not match what the project provides, each paired with the project's command, or with a question when the project does not settle it (outside the buckets, because the drift is from the project, not the template)
   - other validation failures from create step 5 that no bucket covers, such as a title still marked `(Template)` or a dead anchor, each paired with its fix
3. **Present the change plan** as add/modify/remove/keep lists with a one-line rationale each, plus the questions from the findings. Apply nothing yet. Mechanical fixes (dash rule violations, dead anchors, a leftover `(Template)` title) can be pre-approved in bulk. Say so explicitly in the plan.
4. **Get confirmation** from the user for the additions, modifications, and removals, and collect the answers to the questions. The keep/flag list needs no approval because it changes nothing. If the user does not answer a question, add the missing section without the lines that need that answer, and write no placeholder for them. A placeholder already in the file whose question goes unanswered stays as it is.
5. **Apply the approved changes only**, as targeted edits to the existing file rather than a whole-file rewrite, then **validate** as in create mode, also allowing the placeholders that stayed because their questions went unanswered. Fix only what the applied changes broke, and report any other failure instead of fixing it.
6. **Report**:
   - the added, modified, removed, and kept-and-flagged lists, so the user can trace every change back to a decision
   - the lines left out and placeholders kept because their questions went unanswered, which the next adapt run asks about again
   - the tunables kept at the template's default
   - optional fill-ins left empty in the lines added, for the user to add by hand
   - any validation failure left unfixed
