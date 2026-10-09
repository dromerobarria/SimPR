# Pull requests from forks

GitHub gives `pull_request` workflows from forks a **read-only** `GITHUB_TOKEN` and no secrets. That's what makes it safe to build fork code, but it also means the build job can't post a comment or delete old builds.

SimPR uses GitHub's recommended split:

```
fork PR ──► "SimPR" workflow (pull_request, read-only)        ──► uploads build + simpr-meta.json
                    │ completes
                    ▼
            "SimPR publish" workflow (workflow_run, write token) ──► validates meta, comments, prunes
```

## Setup

1. Your build workflow (`simpr.yml`) already switches to `mode: build` for forks:
   ```yaml
   mode: ${{ github.event.pull_request.head.repo.full_name == github.repository && 'full' || 'build' }}
   ```
   (`simpr-build.yml` does this automatically.)
2. Add [`examples/workflows/simpr-publish.yml`](../examples/workflows/simpr-publish.yml) and make sure `workflows: [SimPR]` matches your build workflow's `name:`.
3. Cleanup (`simpr-cleanup.yml`) already uses `pull_request_target`, so it can clean up fork PRs too.

`workflow_run` workflows only run from the default branch. Merge `simpr-publish.yml` before testing with a fork.

## Why this is safe

- The publish job never checks out the PR, and never runs anything from the build.
- `simpr-meta.json` is treated as untrusted input. It is size-limited and schema-validated, and its PR number and SHA must match what GitHub reports for the run and for the PR (see [security.md](security.md#forks)).
- **Never** "fix" fork comments by switching the build to `pull_request_target`. That would run fork code with a write token.

## Requiring approval for fork runs

Repository settings › Actions › General › "Fork pull request workflows" lets you require approval before workflows run for first-time contributors. Combined with the Mac app's allowlist prompt, reviewers decide twice before an outside build reaches their Simulator.
