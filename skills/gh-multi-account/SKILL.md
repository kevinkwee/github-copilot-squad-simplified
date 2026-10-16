---
name: gh-multi-account
description: 'Run gh and gh-authenticated git commands as a specific logged-in GitHub account without changing the active account. Use when: a gh or git command must act as an account other than the currently active one, gh returns permission errors or wrong-account data on repositories another logged-in account owns, an agent is about to run gh auth switch, or any multi-account gh question comes up. Discover the logged-in accounts with gh auth status.'
---

# Multi-Account gh

gh keeps multiple GitHub accounts logged in per host, and commands always run as the active
account for that host. Never use `gh auth switch` inside an agent session. It permanently
changes the active account, so the change outlives the session and affects unrelated work.

## Scoped export pattern

Export the target account's token for the duration of the commands and clear it afterward.
`work-account` below stands for the target account from `gh auth status`:

```powershell
$env:GH_TOKEN = gh auth token --user work-account
try {
    if ($LASTEXITCODE -ne 0) { throw 'gh auth token failed. Check the account name.' }
    gh pr list -R OWNER/REPO
}
finally {
    Remove-Item Env:\GH_TOKEN
}
```

## Verified behavior (gh 2.86.0)

- `gh auth token --user <account>` reads the stored credential for the named account even
  while `GH_TOKEN` is already set, so exporting a second account always returns that
  account's own stored credential.
- With `GH_TOKEN` set, every gh command targeting github.com authenticates as that account,
  and the gh credential helper emits that token for git over https.
- Removing `GH_TOKEN` restores the stored active account with no persistent change.

## Caveats

- The export applies to the whole shell session and every child process until removed, not
  one command. Clear it in `finally`, and re-export when the account changes.
- ssh-protocol git remotes use ssh keys and bypass the gh credential helper, so `GH_TOKEN`
  scopes gh API calls and https git authentication only. Per-account git authentication
  needs https remotes.
- Token scopes are those granted by that account's `gh auth login`. A 403 or 404 under an
  exported token reflects real account permissions.
- While `GH_TOKEN` is set, `gh auth status` lists the exported token as the active account
  and marks every keyring account inactive, so the active account shown there is no longer
  the stored one. Clear it before diagnosing authentication problems.
- For GitHub Enterprise Server hosts, export `GH_ENTERPRISE_TOKEN` in the same pattern.
  `GH_TOKEN` already covers github.com and ghe.com subdomains.