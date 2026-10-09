# Contributing to SimPR

Thanks for helping. Issues and pull requests are welcome.

## Layout and tests

| Part | Run the tests |
|---|---|
| `action/` (Node 20+, no dependencies) | `cd action && npm test` |
| `web/` (static page) | `cd web && npm test`, then `npm run serve` to view it at http://localhost:8787 |
| `mac-app/` (Swift 6, Xcode 16+) | `mac-app/Scripts/test.sh` |
| Workflows and scripts | `actionlint` and `shellcheck action/scripts/*.sh mac-app/Scripts/*.sh` |

CI runs all of these on every PR (`.github/workflows/ci.yml`). PRs that touch `examples/SampleApp` or `action/` also run the real end-to-end workflow on this repo.

## Guidelines

- All code, comments, docs and UI copy are in English.
- Keep the action dependency-free: no `npm install` at runtime.
- Never interpolate `${{ }}` expressions into `run:` scripts. Pass them through `env:`.
- Never run external tools through a shell in the Mac app. Use `ProcessRunner` with argument arrays.
- Validation rules for links and manifests exist in three places (`action/src/lib/manifest.mjs`, `web/public/params.mjs`, `mac-app/SimPRCore/Sources/SimPRCore/Models.swift`). Change them together, and add tests on each side.
- Record decisions that change behavior in `docs/decisions.md`.

## Releasing

- **Action:** tag `vX.Y.Z` and move the `v1` tag.
- **Mac app:** see [docs/mac-app.md](docs/mac-app.md#releasing).
