---
name: merge-strategy
description: 'Decide the merge strategy for a pull request or local branch merge. Use when: asked to merge, a merge is about to happen, or the strategy choice is unclear. Load this skill before ANY merge, including one a built-in merge workflow skill performs. This skill owns the strategy rules. Not for sync flows that only bring a branch up to date with its upstream.'
argument-hint: '[optional: strategy such as merge, squash, or rebase, or a PR number]'
---

# Merge Strategy

Pick the strategy by the first match. Never infer the strategy from history. The absence of merge commits is not a squash or rebase signal.

1. **User request**: the strategy the user names for this merge.
2. **Repository convention**: a strategy the repository documents or enforces (CONTRIBUTING.md, branch protection). Follow it and say why.
3. **Default**: a merge commit.

## Merging

A built-in merge skill performs the merge when present, so hand it the pick. Without one: `gh pr merge <number> --merge` for a pull request, or `git merge --no-ff <branch>` from the base for a local branch, `--no-ff` so a fast-forward never skips the merge commit. Confirm the target before merging. Never merge into the wrong base silently. A squash or rebase pick swaps the mode (`--squash` or `--rebase` on `gh pr merge`, `git merge --squash` plus a commit, or rebase then fast-forward, locally). Say the pick in the reply.

## Conflicts

Conflicts stop the merge. Resolve them as implementation work, reviewed like any other change, then complete the merge with the picked strategy. Never resolve conflicts silently to get a merge through.