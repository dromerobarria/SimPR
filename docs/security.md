# Security

## What runs where

| Where | What runs | With what privileges |
|---|---|---|
| GitHub Actions (macOS runner) | The PR's code, compiled by `xcodebuild` | The workflow's `GITHUB_TOKEN`: `contents: read`, `actions: write`, `pull-requests: write`. Fork PRs get a read-only token. |
| GitHub Actions (`workflow_run`, cleanup, sweep) | SimPR's own scripts only, never PR code | `actions: write`, `pull-requests: write` |
| Redirect page | Static JS from `web/public` | None: no cookies, no network requests, strict CSP |
| Your Mac (SimPR app) | `ditto` (unzip), `xcrun simctl`, `open` | Your user account |
| iOS Simulator | The PR's app | Simulator sandbox |

**SimPR never executes anything from a build on your Mac.** It unzips the archive, reads `simpr.json` as data, and passes the `.app` path to `simctl install`. The app only runs inside the Simulator, the same as when you press Run in Xcode on that branch. Treat a PR build like the PR's code: run builds only from repositories you trust.

## Tokens and scopes

- **CI** uses `GITHUB_TOKEN` with the minimum permissions above. It doesn't need `contents: write`.
- **Mac app, device flow** ("Sign in with GitHub"): no scope for public repos, or `repo` if you tick "Include private repositories". GitHub's OAuth apps have no narrower scope that can download Actions artifacts from private repos. The token is stored in the login Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) and can be revoked anytime at <https://github.com/settings/applications>.
- **Mac app, GitHub CLI fallback:** `gh auth token` is read when SimPR has no token of its own. It has whatever scopes your `gh` login has. Turn it off by signing out of SimPR.
- The token is only sent to `api.github.com`. Downloads redirect to a short-lived signed URL on GitHub's blob storage, and SimPR **removes the `Authorization` header** before following that redirect (`Downloader.willPerformHTTPRedirection`). There's a test for the same behavior in the action (`token never sent to blob storage`).
- Organizations that restrict OAuth app access must approve the SimPR OAuth app, or members can use the `gh` fallback.

## Forks

Fork PRs are where untrusted code meets CI. SimPR's rules:

1. **Build with `pull_request`, never `pull_request_target`.** The build job runs fork code, so it must not have a write token or secrets.
2. Fork builds run in `mode: build`. They upload the build and `simpr-meta.json`, and they can't comment.
3. A separate `workflow_run` workflow comments. It **doesn't check out or run any PR code**. It downloads `simpr-meta.json` from the build run, size-limits and schema-validates it, and checks it against GitHub:
   - the run concluded `success`,
   - the run's `head_sha`, the PR's current head SHA, and the manifest's `commitSha` are equal,
   - the PR is open,
   - the artifact ID and name exist in this repository and the name encodes the same PR number.

   A fork therefore can't make SimPR comment on another PR or point the button at another repository's build.
4. Cleanup uses `pull_request_target` only to get a token that can delete artifacts on fork PRs. It runs SimPR's code from the base branch, or the reusable workflow, and never the PR's.

## Link validation

Every field in the redirect page and in the Mac app is validated against strict patterns (repo `owner/name`, a 40-hex SHA, positive integer IDs, a reverse-DNS bundle ID, single-component folder and `.app` names). Unknown fields are dropped. Paths built from link data are checked to stay inside the library directory. The Mac app rejects a download whose `simpr.json` doesn't match the link (repo, commit, PR, bundle ID, content key).

## Allowlist

The first time a repository's link is opened, SimPR asks **"Run build from owner/repo?"**. Choosing "Always allow" adds it to Settings › Trusted Repos, where it can be removed.

## Process execution

All external tools are run through `ProcessRunner` with an executable URL and an argument array. There is no `/bin/sh -c` and no string interpolation into commands. A test passes `$(whoami)`, `; rm -rf /` and quotes as arguments and checks they arrive literally. The action's `build.sh` splits `extra-xcodebuild-args` with Python's `shlex`, without expansion or globbing.

## Reporting a vulnerability

Please open a private security advisory on the repository (**Security › Report a vulnerability**) instead of a public issue.
