---
name: pr-description
description: 'Write a pull request title and description in Conventional Commits style, from the branch history. Use when: asked for a PR title or description, or a pull request is about to be created or updated. Load this skill before ANY pull request creation or update, including by a built-in PR workflow skill. This skill owns the title and description style.'
argument-hint: '[optional: repo and branch, or a PR template]'
---

# PR Title and Description

Write the PR title and description from the branch's commit history and the actual diff against the base. The title follows the Conventional Commits style, like the commit-message skill's messages.

This skill plays two roles, and both apply the same rules:

- **Style authority**: whenever a pull request is about to be created or updated, by any path, the title and description follow the rules in this skill. That includes creation performed by a built-in PR workflow skill.
- **Procedure**: when the user asks for a PR title or description (or invokes this skill), run the procedure below. Derive the title and description from the branch history, present them, and ask how to proceed.

## Built-in PR workflow skills

A session may provide built-in PR workflow skills (the Agents window on the Copilot SDK does): one that creates a regular pull request, one that creates a draft, and one that updates the session's existing pull request. They own the **act of creating and updating**. That includes pushing the branch, the PR creation command, draft mode, and session bookkeeping, such as linking the PR to the session so later update, merge, and fix-ci workflows see it.

- When the session provides a built-in PR creation skill, that skill performs the creation. Do not call `gh pr create` yourself in that case. Supply the title and description from this skill, verbatim.
- Route by draft preference. When the user asked for a draft, use the draft skill; otherwise use the regular one. Ask only when the user has not said and the choice matters.
- When the session already has a linked pull request (the built-in update workflow), revising its title or description routes through the built-in update skill. This skill supplies the revised text.
- When this skill loads only for style while a built-in skill runs the request (the user said "open a PR", not "write the PR description"), apply the rules below to the title and description the built-in skill writes. Do not force the present-and-ask loop on top of the built-in skill's own flow.
- When the session provides no built-in PR skill (for example Copilot CLI, Codex via Agent Host, or a plain terminal), create the pull request yourself with `gh pr create` as described in Ask how to proceed.

## Procedure

1. **Resolve the repo and branch**: use the ones the user provides. When none is given, use the current repository and branch. Detect the base branch (default branch from `git remote show origin`, or fall back to `main` / `master`) and the merge base: `git merge-base <base> HEAD`.
2. **Collect the material**:
   - `git log --reverse <merge-base>..HEAD --format=full` for every commit message on the branch, in order
   - `git diff <merge-base>...HEAD --stat` for the shape of the change
   - `git diff <merge-base>...HEAD` for the substance when the commits alone do not explain the change
   - the repo's recent PR/commit message style if useful
3. **Title**: a single line in Conventional Commits style, describing the PR as a whole (not a copy of one commit's message). Same rules as commit messages: one of the standard types, optional scope, imperative mood, no trailing period, `!` before the colon for breaking changes, no sentence wrapping. A title is a single line with no body to absorb the tail, so a wrap leaves the sentence broken in two. BAD and GOOD:

   ```text
   BAD:
   feat: move the guard hook install to the user level with an
   absolute script path

   GOOD:
   feat: move the guard hook install to the user level with an absolute script path
   ```
4. **Description**: use the PR template when the user provides one, or the default format below when the repo has none.

## Template handling

- If the user provides a PR template, use it to format the description. Write the result in the response wrapped with a code block, not in the template file, unless the user explicitly asks you to write it there.
- If the user does not provide a template, check for repo-level ones (`.github/PULL_REQUEST_TEMPLATE.md`, `.github/pull_request_template.md`, `docs/`). When one is found, use it: the repo already made the choice by shipping the template. Only fall back to the default format when this repo's PR page shows no template, or when the found template does not fit the change (say which section and why).
- With no template anywhere, use the default format below.

## Default description format

```markdown
## Summary

<!-- Briefly describe the purpose of this PR and any relevant context. -->

## Type of Change

<!-- Keep only the relevant type(s). -->

- New Feature
- Bug Fix
- Refactor
- Documentation
- Test
- Other

## Key Changes

<!-- List the main changes reviewers should know about. -->

-
-

## Notes

<!--
Add breaking changes, migrations, known limitations, screenshots, dependencies,
or anything else reviewers should know. Delete this section if unnecessary.
-->

## How This Has Been Tested

<!--
Optional. Describe automated tests or manual verification when relevant.
Delete this section if unnecessary.
-->
```

Fill the sections: keep only the applicable types, list the key changes reviewers should care about, and delete Notes and Testing when they add nothing. Real content over template comments. When the user's argument carries context (issue number, intent), fold it in. Keep every bullet in the description on a single line and never hard-wrap it, however long the line gets.

## Output

Write the title on its own line, outside the description code block, then the full description in a single fenced block so it can be copied verbatim. The title goes outside so tooling that takes a title and a body reads them cleanly.

## Ask how to proceed

After presenting title and description, ask the user how to proceed, with options to create the PR as-is, create it as a draft when the user has not specified, or leave it as text only, plus a freeform reply for anything else.

- **Create the PR as-is**: create the pull request with the title and description exactly as presented. When the session provides built-in PR workflow skills, use them and pass the title and description verbatim. Otherwise use `gh pr create`. Confirm the pushed branch with the user before creating; never create on the wrong base branch silently.
- **Create as draft**: same as above, in draft mode. Offer this option only when the user has not already chosen between draft and regular.
- **Text only**: report the title and description and stop.
- **Freeform text**: treat it as the requested revision. Apply the changes, present the updated title and description, and ask again.
