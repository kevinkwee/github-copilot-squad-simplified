---
name: merge-strategy
description: 'Decide the merge strategy for a pull request or local branch merge. Use when: asked to merge, a merge is about to happen, or the strategy choice is unclear. Load this skill before ANY merge, including one a built-in merge workflow skill performs. This skill owns the strategy rules. Not for sync flows that only bring a branch up to date with its upstream.'
argument-hint: '[optional: strategy such as merge, squash, or rebase, or a PR number]'
license: MIT
compatibility: 'Requires git, plus the GitHub CLI (gh) for pull request merges.'
---

# Merge Strategy

Pick the strategy by the first match. Never infer the strategy from history. The absence of merge commits is not a squash or rebase signal.

1. **User request**: the strategy the user names for this merge.
2. **Repository convention**: a strategy the repository documents or enforces (CONTRIBUTING.md, branch protection). Follow it and say why.
3. **Default**: a squash merge.

## Merging

A built-in merge skill performs the merge when present, so hand it the pick. Without a built-in merge skill, a squash merge is `gh pr merge <number> --squash` for a pull request. For a local branch it is `git merge --squash <branch>` from the base, then `git commit -m "<message>"` with a message from the `commit-message` skill. For a merge commit pick, use `gh pr merge <number> --merge`, or `git merge --no-ff <branch>` from the base so a fast-forward never skips the merge commit. For a rebase pick, use `gh pr merge <number> --rebase`, or rebase then fast-forward locally. Confirm the base before merging, and never merge into the wrong base silently. Say the pick in the reply.

## Conflicts

Conflicts stop the merge. Resolve them as implementation work, reviewed like any other change, then complete the merge with the picked strategy. Never resolve conflicts silently to get a merge through.