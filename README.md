# SimPR

**A "Run in iOS Simulator" button for GitHub pull requests.** Free, open source (MIT), self-hostable.

Reviewers (engineers, QA, designers, PMs with a Mac) click the button on a PR, and the app built from that exact commit opens in iOS Simulator on their own Mac. They don't check out the branch, compile anything, or touch their working copy.

![Run in iOS Simulator](web/public/badge.svg)

```
push to PR ─► GitHub Actions (macOS) ─► unsigned simulator .app ─► artifact + sticky PR comment
                                                                         │
reviewer clicks the button ─► redirect page (GitHub Pages) ─► simpr://run?… ─► SimPR Mac app
                                        │                                   downloads, installs,
                                        └─► no app? "Download build" + drag onto Simulator    launches
```

- **GitHub only compiles. The simulator always runs on your Mac.** No SimPR server; builds are stored as GitHub Actions artifacts.
- **Works without installing anything:** download the build, open Simulator, drag the `.app` in. A pre-filled terminal one-liner is in the comment too.
- **One live build per PR.** Builds are rebuilt only when app code changes, superseded builds are deleted, and every build is deleted when the PR is merged or closed.
- **The Mac app (optional)** gives you one-click runs and a **local library of every build you've run**, so you can still run a build after GitHub deletes it. That makes it easy to compare an old commit with a new one, or to reproduce a bug on a build from a merged PR.

## 5-minute setup

### 1. Add the workflows

Copy these from [`examples/workflows`](examples/workflows) into your app repository's `.github/workflows/`:

| File | What it does |
|---|---|
| [`simpr.yml`](examples/workflows/simpr.yml) | Builds each PR for the simulator and posts the button. **Edit `project`/`workspace`, `scheme` and `app-paths`.** |
| [`simpr-cleanup.yml`](examples/workflows/simpr-cleanup.yml) | Deletes a PR's builds when it's merged or closed. |
| [`simpr-sweep.yml`](examples/workflows/simpr-sweep.yml) | Weekly: deletes orphaned builds and builds older than 30 days. |
| [`simpr-publish.yml`](examples/workflows/simpr-publish.yml) | Only if you accept PRs from forks. Comments for fork PRs safely ([details](docs/forks.md)). |

The core of `simpr.yml`:

```yaml
jobs:
  simpr:
    permissions: { contents: read, actions: write, pull-requests: write }
    uses: dromerobarria/SimPR/.github/workflows/simpr-build.yml@v1
    with:
      project: MyApp.xcodeproj
      scheme: MyApp
      app-paths: |
        MyApp
        MyApp.xcodeproj
```

Need setup steps first (CocoaPods, code generation)? Use the composite action directly: [`simpr-inline.yml`](examples/workflows/simpr-inline.yml). All inputs are listed in [`action/action.yml`](action/action.yml).

### 2. The redirect page

Nothing to do: the button points at the hosted page, `https://dromerobarria.github.io/SimPR/`. It's static HTML with no analytics and no server, and it only sees the query string.

To host your own copy, fork this repo, enable **Settings › Pages › Source: GitHub Actions** (the [`pages.yml`](.github/workflows/pages.yml) workflow publishes `web/public`), and set `redirect-base-url` in your workflow.

### 3. Install the Mac app (optional, recommended)

```sh
brew install --cask dromerobarria/simpr/simpr
```

Or download the DMG from [Releases](https://github.com/dromerobarria/SimPR/releases/latest). You need macOS 14 or later and Xcode with an iOS Simulator runtime. Open SimPR from the menu bar and sign in with GitHub, or reuse your GitHub CLI login (`gh auth login`). <a id="install-the-mac-app"></a>

### 4. Open a PR

The first build takes as long as a normal simulator build on a macOS runner. Then a comment appears:

> 📱 **SimPR Sample is ready to run**
> [Run in iOS Simulator] · ⬇️ Download build · commit, build time, size, minimum iOS, Xcode
> ▸ Run it without the SimPR app

Push again and the same comment updates. If you push only docs, no runner starts (`paths-ignore`). If the push doesn't touch `app-paths`, the existing build is reused in seconds.

## Running a build without the Mac app

1. Click **Download build** in the comment (you must be signed in to GitHub). Safari unzips it automatically.
2. Open Simulator: `open -a Simulator`.
3. Drag the `.app` from the unzipped folder onto the Simulator window. It installs and launches.

> Double-clicking the `.app` does **not** work. It's an iOS Simulator build, and macOS can't run it directly.

Terminal users get a pre-filled command in the comment (it needs the [GitHub CLI](https://cli.github.com)):

```sh
D="$(mktemp -d)" && \
gh api repos/OWNER/REPO/actions/artifacts/ARTIFACT_ID/zip > "$D/build.zip" && \
ditto -x -k "$D/build.zip" "$D" && \
open -a Simulator && \
until xcrun simctl list devices booted | grep -q Booted; do sleep 1; done && \
xcrun simctl install booted "$D"/FOLDER/App.app && \
xcrun simctl launch booted com.example.app
```

## The Mac app

A menu bar app (SwiftUI, macOS 14+) that handles `simpr://` links:

- Asks before running a build from a repository you haven't trusted yet.
- Downloads the build (or reuses it if the commit is already in your library), with progress.
- Checks compatibility first: an installed iOS runtime must be at least the build's minimum iOS, and the build must contain your Mac's architecture. Each failure says what to do.
- Picks your preferred simulator, or asks once. It boots the simulator, opens Simulator, installs the app (optionally after resetting its data), launches it, and notifies you.
- **Library window:** builds grouped by repo and PR, newest commit first, searchable by repo, `#PR`, branch or SHA. For each build: Run, Run on…, Pin, Reveal in Finder, Open PR on GitHub, Delete. A size limit (default 5 GB) evicts the oldest unpinned builds. Pinned builds are never evicted automatically.

More detail: [docs/mac-app.md](docs/mac-app.md).

## Security

- **Token scopes.** CI uses the workflow's `GITHUB_TOKEN` with `actions: write` and `pull-requests: write` only. The Mac app needs a GitHub token because GitHub requires sign-in to download artifacts, even from public repos. It requests no scope for public repos, and `repo` only if you opt into private repos (GitHub has no narrower OAuth scope for artifacts). The token is stored in the Keychain and sent only to `api.github.com`, never to the storage URL a download redirects to.
- **Forks.** Fork PRs build with a read-only token. Comments come from a separate `workflow_run` workflow that never checks out PR code and verifies the claimed PR and SHA against GitHub. SimPR never uses `pull_request_target` to build code. Cleanup uses it only because it runs no PR code.
- **Allowlist.** The Mac app asks "Run build from owner/repo?" until you trust that repository.
- **Nothing from the build is executed on your Mac.** SimPR validates the link, checks that the downloaded `simpr.json` matches the link (repo, commit, bundle ID), and installs the `.app` into the simulator with `simctl`. The app then runs inside the iOS Simulator only. Every external tool is called with an argument array, never through a shell.

Full threat model: [docs/security.md](docs/security.md).

## Limits to know

- GitHub keeps artifacts for 90 days by default (and at most 90 for public repos). If a PR outlives that, the weekly sweep updates the comment with rebuild instructions (re-run the workflow). Builds already in your Mac app's library keep working.
- Builds run on macOS runners, which bill at a higher rate than Linux for private repos. `paths-ignore` and the content key keep that to builds that matter.
- The simulator builds are unsigned Debug builds by default. They can't run on devices, which is intentional.

More: [docs/faq.md](docs/faq.md) · [architecture](docs/architecture.md) · [decisions](docs/decisions.md) · [first end-to-end test](docs/e2e.md)

## Repository layout

```
action/      composite action (+ publish, cleanup, sweep sub-actions), Node scripts, tests
.github/     reusable workflows (simpr-build/-cleanup/-sweep/-publish), CI, Pages, example-app E2E
web/         redirect page + badge (web/public is what gets deployed), tests
mac-app/     SimPRCore Swift package (logic + tests), SimPR app, XcodeGen project, packaging
examples/    SampleApp (used for E2E) and copy-paste consumer workflows
docs/        setup, architecture, security, forks, Mac app, FAQ, decisions
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). SimPR is inspired by the workflow of [Presto](https://usepresto.dev), a commercial product. It shares no code or branding with it.

## License

[MIT](LICENSE)
