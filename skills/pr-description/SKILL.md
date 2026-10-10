---
name: pr-description
description: 'Write a pull request title and description in Conventional Commits style, from the branch history. Use when: asked for a PR title or description, preparing a pull request, or opening a PR.'
argument-hint: '[optional: repo and branch, or a PR template]'
---

# PR Title and Description

Write the PR title and description from the branch's commit history and the actual diff against the base. The title follows the Conventional Commits style, like the commit-message skill's messages.

## Procedure

1. **Resolve the repo and branch**: use the ones the user provides. When none is given, use the current repository and branch. Detect the base branch (default branch from `git remote show origin`, or fall back to `main` / `master`) and the merge base: `git merge-base <base> HEAD`.
2. **Collect the material**:
   - `git log --reverse <merge-base>..HEAD --format=full` for every commit message on the branch, in order
   - `git diff <merge-base>...HEAD --stat` for the shape of the change
   - `git diff <merge-base>...HEAD` for the substance when the commits alone do not explain the change
   - the repo's recent PR/commit message style if useful
3. **Title**: a single line in Conventional Commits style, describing the PR as a whole (not a copy of one commit's message). Same rules as commit messages: one of the standard types, optional scope, imperative mood, no trailing period, `!` before the colon for breaking changes, no sentence wrapping.
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

Fill the sections: keep only the applicable types, list the key changes reviewers should care about, and delete Notes and Testing when they add nothing. Real content over template comments; when the user's argument carries context (issue number, intent), fold it in.

## Output

Write the title on its own line, outside the description code block, then the full description in a single fenced block so it can be copied verbatim. The title goes outside so tooling that takes a title and a body reads them cleanly.

## Ask how to proceed

After presenting title and description, use the ask tool (#tool:vscode/askQuestions with `allowFreeformInput: true`) with options to create the PR as-is, or leave it as text only, plus freeform input for anything else.

- **Create the PR as-is**: use the GitHub PR tool `github-pull-request_create_pull_request` when available, otherwise `gh pr create`, with the title and description exactly as presented. Confirm the pushed branch with the user before creating; never create on the wrong base branch silently.
- **Text only**: report the title and description and stop.
- **Freeform text**: treat it as the requested revision. Apply the changes, present the updated title and description, and ask again.
