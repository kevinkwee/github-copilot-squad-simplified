---
name: commit-message
description: 'Write a Conventional Commits message for the staged changes, and optionally commit them. Use when: asked for a commit message, documenting staged work, or a commit is about to happen. Load this skill before ANY commit, including one a built-in commit workflow skill performs. This skill owns the message style rules.'
argument-hint: '[optional: context such as an issue number]'
---

# Commit Message

Write a Conventional Commits message for the staged changes, present it, and ask how to proceed. Base the message only on the staged content.

This skill plays two roles, and both apply the same rules:

- **Style authority**: whenever a commit is about to happen, by any path, the message follows the format and rules in this skill. That includes a commit performed by a built-in commit workflow skill, and a commit the user makes after copying the presented message.
- **Procedure**: when the user asks for a commit message (or invokes this skill), run the procedure below. Check the staged changes, draft the message, present it, and ask how to proceed.

## Built-in commit workflow skills

A session may provide a built-in commit workflow skill (the Agents window on the Copilot SDK does). It owns the **act of committing**. That includes staging awareness, the commit command, and session bookkeeping such as the linked pull request.

- When the session provides a built-in commit skill, that skill performs the commit. Do not run `git commit` yourself in that case. Supply the rules from this skill, and the drafted message when this skill produced one, verbatim.
- When this skill loads only for style while the built-in skill runs the request (the user said "commit", not "write me a commit message"), apply the rules below to the message the built-in skill writes. Do not force the present-and-ask loop on top of the built-in skill's own flow.
- When the session provides no built-in commit skill (for example Copilot CLI, Codex via Agent Host, or a plain terminal), commit yourself using the PowerShell rules in the Committing section below.

## Procedure

1. **Check staged changes**: run `git diff --cached --stat`. If nothing is staged, say so and stop. Never stage files yourself; staging is the user's call.
2. **Read the patch**: `git diff --cached` for the full staged diff. Skim `git log --oneline -10` to match the repo's recent message style (type and scope usage, tone, language).
3. **Write the message** following the format and rules below, then present it for review.

## Message format

```text
<type>(<scope>): <description>

<body>

<footer>
```

- `<type>`: one of `feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `perf`, `ci`, `build`, `revert`, `style`.
- `<scope>`: optional, include only if clearly identifiable.
- `<description>`: one line, imperative mood. No trailing period.
- `<body>`: optional, include only if really necessary. Provide additional context or details about the change. Use bullet points for multiple items, in the imperative mood, starting with a capital letter. If the description needs a longer form or explanation, write it as paragraphs before the bullet points. Do not treat paragraphs as a default.
- `<footer>`: optional. For breaking changes, include `BREAKING CHANGE:` followed by a description. For referencing issues, include `Closes #<issue_number>` for each issue closed by the commit.
- Breaking changes: put `!` right before the `:` in the header (`feat!:` or `fix(scope)!:`; `fix!(scope):` is wrong).
- Do not wrap a sentence into multiple lines, keep it as a single line.
- Do not mention any unstaged changes.

## Output

Return the message in a single fenced block so it can be copied verbatim. Do not wrap a sentence into multiple lines, keep it as a single line.

## Ask how to proceed

After presenting the message, ask the user how to proceed, with options to commit it as-is or leave it as message only, plus a freeform reply for anything else.

- **Commit as-is**: commit the staged changes with the presented message exactly as written. When the session provides a built-in commit skill, invoke it and pass the message verbatim. Otherwise commit yourself using the PowerShell rules below.
- **Message only**: report the final message and stop.
- **Freeform text**: treat it as the requested revision. Apply the changes, present the updated message, and ask again.

## Committing without a built-in skill (Windows PowerShell)

Use this section only when the session provides no built-in commit skill.

- Prefer the single-quoted strategy, and double any literal single quote inside it:
  `git commit -m 'fix: resolve ''timeout'' error'`
- Bash-style escaping inside double quotes breaks PowerShell parsing and leaves the message unterminated:
  - BAD: `git commit -m "fix: resolve \"timeout\" error"`
  - GOOD (backtick escape): ``git commit -m "fix: resolve `"timeout`" error"``
- Pass one `-m` per paragraph. Body bullets can ride in the second `-m`, one line per bullet.
- Before committing, re-verify the staged set is unchanged (`git diff --cached --stat`); if it moved since the message was written, regenerate the message first.
