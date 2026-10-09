# Decisions

Decisions made while building v1, with the reasoning. Newest information about GitHub's platform was checked on 2026-10-09.

## Platform facts that shaped the design

Verified against GitHub's docs and the `actions/upload-artifact` releases before writing code:

| Fact | Consequence |
|---|---|
| Artifact retention defaults to 90 days. Public repos can't go above 90. Private repos can be configured higher in repo, org or enterprise settings (GitHub Enterprise Server documents up to 400 days). Since 2026-10-01, workflow runs, checks and statuses follow the same retention setting. | We can't promise a build lives as long as its PR. The comment shows "Available until", the sweep updates the comment with rebuild steps when a build expires, and the Mac app library keeps a local copy. |
| The REST download endpoint (`GET …/actions/artifacts/{id}/zip`) **requires authentication even for public repos** and answers with a 302 to a signed URL that **expires after 1 minute**. Classic and OAuth tokens need `repo` for private repos. The browser `artifact-url` works only for signed-in users. | The Mac app always needs a token. The download URL is fetched immediately before downloading and never stored. The no-app path tells users to be signed in to GitHub. |
| `actions/upload-artifact@v7` added `archive: false`: one file, uploaded unzipped, and the **artifact name is the file name** (`name` is ignored). Zipped uploads drop file permissions (files become 644). Artifacts are immutable; names must be unique per run. | We zip the `.app` ourselves with `ditto` (it keeps the executable bit and symlinks) and upload that single zip with `archive: false`. Artifact names therefore end in `.zip`: `simpr-pr-<number>-<contentKey>.zip`. |
| List endpoints accept `name=` (exact match) and up to 100 per page. Artifacts can be deleted with `DELETE …/artifacts/{id}`. | Reuse lookups are one exact-name query. Pruning, cleanup and the sweep scan up to 10 pages (50 for the sweep). |
| The `GITHUB_TOKEN` rate limit is 1,000 requests per hour per repository. | A normal run makes roughly 5 to 15 calls. The sweep makes about 2 per open PR with builds. |
| Device flow needs only a client ID, must be enabled per OAuth app, and has a polling `interval` plus a `slow_down` error. | The Mac app implements it without a secret. The client ID is a build setting, and builds without one fall back to `gh auth token`. |

## Architecture and naming

1. **Name: SimPR.** Repo `dromerobarria/SimPR`, license MIT, URL scheme `simpr://`. The Mac bundle ID is `dev.danielromero.SimPR`, matching the maintainer's other apps.
2. **No SimPR server.** CI builds, GitHub stores, GitHub Pages redirects, and the Mac runs the simulator.
3. **Redirect page:** the hosted default is `https://dromerobarria.github.io/SimPR/`, published from `web/public` by an Actions-based Pages workflow. Branch-based Pages can only serve `/` or `/docs`, so it can't serve `/web` directly. Consumers can host their own copy and set `redirect-base-url`.
4. **Reusable workflows live in `.github/workflows/`** rather than `/action`, because GitHub can only call reusable workflows from that directory. `/action` holds the composite action and three small sub-actions (`publish`, `cleanup`, `sweep`), which the reusable workflows wrap.
5. **Action scripts are dependency-free Node (ESM)** run with the runner's preinstalled Node. There is no `npm install` or bundling step, and the code is easy to audit. Tests use `node --test`.

## Builds

6. **Build the PR head commit, not the merge commit.** The examples check out `github.event.pull_request.head.sha`, so the button runs exactly the commit reviewers see. The manifest records that SHA.
7. **Content key** = SHA-256 (truncated to 16 hex characters) of: the key version; the git object IDs of each `app-paths` entry (`git rev-parse HEAD:<path>`); every tracked `Package.resolved`, `Podfile.lock`, `Cartfile.resolved` and `Mintfile`; and the build settings (project or workspace, scheme, configuration, archs, extra args, salt). The default `app-paths: .` hashes the root tree, so any change rebuilds. That is correct but wasteful, so the examples show how to narrow it. A `key-salt` input forces rebuilds.
8. **Reuse:** if a non-expired artifact with the same name exists, the action downloads only its `simpr.json` (by downloading and unzipping the build) to refresh the comment, and skips `xcodebuild`.
9. **Universal builds by default** (`ARCHS="arm64 x86_64"`). If that fails (often a binary dependency without an x86_64 simulator slice), the action retries arm64-only with a warning. The architectures actually built are read with `lipo` and recorded.
10. **Zip layout:** `<App>-PR<n>-<sha7>/` containing `<App>.app` and `simpr.json`. Safari's auto-unzip gives a tidy folder, and the manifest travels with the build. Resource forks and extended attributes are dropped, so there are no `__MACOSX` entries.
11. **`keep-builds`** (default 1) keeps the current build plus the newest `keep-builds − 1` other unexpired builds of the PR. When a re-run reuses an older build, newer ones count as superseded.

## Comment

12. **One sticky comment per PR**, found by the `<!-- simpr:comment -->` marker *and* written by `github-actions[bot]` (or `comment-author`). Nobody can make SimPR adopt a comment by pasting the marker. A hidden `<!-- simpr:state {...} -->` line records the live artifact, so the sweep can tell when it expired.
13. Text taken from the build (app name and so on) is Markdown and HTML escaped in the comment. Values put into the terminal one-liner are validated or shell-quoted.
14. **Deviation from the brief: the one-liner uses `gh api …/artifacts/<id>/zip` + `ditto` instead of `gh run download`.** With `archive: false` the API serves our zip as-is, and `ditto` restores symlinks and permissions exactly. `gh run download` unzips with its own extractor, which isn't documented to keep symlinks. The command also opens Simulator and waits for a booted device, so `booted` always resolves.

## Forks and cleanup

15. **Fork PRs switch to `mode: build` automatically** (`head.repo.full_name != github.repository`). They upload the build plus `simpr-meta.json`, and the `workflow_run` publisher comments. The publisher never checks out PR code, treats the metadata as untrusted data, and refuses to publish unless the run's head SHA, the PR's current head SHA and the manifest's SHA all match and the artifact really exists in the repo.
16. **Cleanup uses `pull_request_target`**, because on `pull_request` a fork PR's token can't delete artifacts or edit comments. It checks out only the base repo's trusted code (or none, with the reusable workflow) and runs no PR code. The rule "never use `pull_request_target` to build untrusted code" holds.
17. **Sweep** runs weekly and deletes SimPR artifacts whose PR is closed, merged or missing, whose run is gone, that have expired, or that are older than `max-age-days` (default 30; 0 disables). For open PRs whose live build is gone, it rewrites the comment with rebuild instructions. `workflow_dispatch` defaults to a dry run in this repo.

## Storage abstraction

18. `action/src/lib/storage.mjs` defines the storage interface (`findByName`, `list`, `listForRun`, `get`, `delete`, `downloadUrl`), with GitHub artifacts as the only v1 implementation. The upload itself is the `actions/upload-artifact` step. An S3 or R2 backend would add an implementation plus an upload step. On the Mac, `ArtifactFetching` is the matching seam.

## Redirect page

19. It tries `simpr://` immediately. If the page blurs or is hidden within 1.5 seconds, it assumes the app (or the browser's "Open SimPR?" prompt) took over. Otherwise it shows the no-app path. Non-Mac browsers (including iPad) skip straight to the no-app path with a note. `#no-app` forces it, which is handy for docs.
20. It forwards only validated fields to `simpr://`, uses a strict CSP, sets no-referrer, makes no network requests, and inserts text with `textContent` only.

## Mac app

21. **macOS 14+, SwiftUI `MenuBarExtra` (menu style), `LSUIElement`.** Links are handled with `NSAppleEventManager` (registered in `applicationWillFinishLaunching`), so the URL that launches the app isn't lost. The run panel is an `NSPanel`, because it must appear from a URL event with no SwiftUI view in scope.
22. **Logic lives in the `SimPRCore` Swift package** (tested with `swift test`). The app target is thin UI. The Xcode project is generated with XcodeGen and committed.
23. **The library index is a JSON file** (`library.json`) rather than SwiftData. It's small, easy to inspect and fix by hand, trivial to test, and free of schema-migration issues. One stored build per `owner/repo/sha`.
24. **Eviction:** after each download, the library evicts unpinned builds, oldest download first, until it's under the limit. The build just downloaded and pinned builds are never evicted.
25. **Compatibility** also checks the chosen simulator runtime's `supportedArchitectures`. iOS 26+ simulator runtimes on Apple silicon report `arm64` only, so an x86_64-only build can't run there.
26. **Xcode discovery:** if `xcode-select` points at the Command Line Tools (a common setup), SimPR uses the newest `/Applications/Xcode*.app` through `DEVELOPER_DIR`. Settings can pin one.
27. **Auth:** Keychain token from device flow first, then `gh auth token` (on by default). Signing out removes the Keychain item and stops borrowing the CLI token.
28. **Not sandboxed** (it needs `xcrun`), with hardened runtime, Developer ID signing and notarization, and distribution as a DMG plus a Homebrew cask in a `dromerobarria/homebrew-simpr` tap.
29. **Debug-only test hooks:** `-SimPRImport <zip>` and `-SimPROpenURL <link>` launch arguments. They're compiled out of Release builds. "Import Build Zip…" in the Library is a real feature: it adopts builds downloaded through the no-app path.
