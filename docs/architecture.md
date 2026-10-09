# Architecture

```
┌──────────────── GitHub ────────────────┐            ┌──────────── Reviewer's Mac ────────────┐
│                                        │            │                                        │
│  pull_request ─► simpr-build (macOS)   │            │  Browser: PR comment                   │
│    1. content key (git object IDs)     │            │    │ click button (https link)         │
│    2. same key live? ─yes─► reuse      │            │    ▼                                   │
│    3. xcodebuild iphonesimulator,      │            │  Redirect page (GitHub Pages)          │
│       unsigned, arm64+x86_64           │            │    │ validate params                   │
│    4. ditto zip + simpr.json           │            │    ├─► simpr://run?…  ─► SimPR app ─┐  │
│    5. upload-artifact (archive:false)  │            │    └─► 1.5 s, no app: Download build │  │
│    6. sticky comment, prune old builds │            │         + drag onto Simulator        │  │
│                                        │            │                                      ▼  │
│  pull_request_target: closed           │  REST API  │  SimPR: allowlist ─► library hit? ──┐   │
│    ─► simpr-cleanup: delete builds,    │◄──────────►│     no ─► GET artifact, download    │   │
│       mark comment expired             │  (token)   │           (token stripped on 302)   │   │
│                                        │            │         ─► unzip, verify simpr.json │   │
│  schedule ─► simpr-sweep               │            │         ─► store in library ◄───────┘   │
│                                        │            │  compatibility ─► pick simulator ─►     │
│  workflow_run ─► simpr-publish (forks) │            │  simctl boot/install/launch             │
└────────────────────────────────────────┘            └────────────────────────────────────────┘
```

## Components

### `/action`: composite action (`action.yml`)

Steps: check environment → `simpr.mjs key` → `simpr.mjs find-existing` → (if needed) `scripts/build.sh` → `simpr.mjs package` → `actions/upload-artifact@v7` (`archive: false`) → `simpr.mjs write-meta` → `simpr.mjs publish` (full mode), or upload `simpr-meta.json` (build mode).

| Module | Responsibility |
|---|---|
| `src/lib/contentKey.mjs` | Content key from git object IDs, lockfiles and settings |
| `src/lib/naming.mjs` | `simpr-pr-<n>-<key>.zip` naming and parsing |
| `src/lib/manifest.mjs` | `simpr.json` schema validation |
| `src/lib/comment.mjs` | Sticky comment, links, terminal one-liner, state marker |
| `src/lib/prune.mjs` | Which builds to delete (superseded, sweep). Pure functions |
| `src/lib/storage.mjs` | Storage interface; GitHub artifacts implementation |
| `src/lib/github.mjs` | Minimal REST client |
| `src/simpr.mjs` | CLI entry point used by the action steps |

Inputs reach scripts only through environment variables, never through `${{ }}` inside shell code.

### `/web`: redirect page

Static files in `web/public`: `index.html`, `app.js`, `params.mjs` (pure validation and link building, shared with tests), `style.css`, `badge.svg`, `icon.svg`.

### `/mac-app`

- `SimPRCore` (Swift package): `RunRequest` (link parsing), `BuildManifest`, `Compatibility`, `Simctl` + `SimctlParser`, `ProcessRunner`, `GitHubClient` + `Downloader`, `DeviceFlow`, `KeychainTokenStore`, `BuildLibrary` (actor) + `EvictionPolicy`, `BuildExtractor`, `RunPipeline`.
- `SimPR` (app): `AppModel` (state and orchestration), `AuthModel`, `Preferences`, `RunPanelController`, and the views (`MenuContent`, `LibraryView`, `SettingsView`).

## Data formats

### `simpr.json` (inside the zip, next to the `.app`)

```json
{
  "schemaVersion": 1,
  "bundleId": "dev.simpr.example.SampleApp",
  "appName": "SimPR Sample",
  "appBundleName": "SampleApp.app",
  "folderName": "SimPR-Sample-PR1-41d6344",
  "version": "1.0",
  "buildNumber": "1",
  "minimumOSVersion": "17.0",
  "architectures": ["x86_64", "arm64"],
  "xcodeVersion": "26.6",
  "xcodeBuild": "17F113",
  "sdkVersion": "26.5",
  "configuration": "Debug",
  "scheme": "SampleApp",
  "repository": "dromerobarria/SimPR",
  "prNumber": 1,
  "commitSha": "41d6344b60f778f78d0719df47e5c6439303b080",
  "contentKey": "1c68d46805d32494",
  "buildDate": "2026-10-09T18:52:47.263Z",
  "appSizeBytes": 364544
}
```

The zip's size isn't in the manifest (it can't contain itself). The comment takes it from the artifact.

### Run link

`https://<pages>/?v=1&repo=&pr=&sha=&run=&artifact=&name=&app=&bundle=&folder=&appfile=&minos=&arch=&key=&size=` → `simpr://run?<same validated fields>`.

`repo`, `pr`, `sha`, `run` and `artifact` are required. The rest let the page build the one-liner and let the Mac app fail fast (minimum iOS, architecture) before downloading. The downloaded `simpr.json` is authoritative and must match `repo`, `sha`, `pr`, `bundle` and `key`.

### Mac library

```
~/Library/Application Support/SimPR/
  library.json                     index: one record per owner/repo/sha
  Builds/<owner>/<repo>/<sha>/
    <App>.app
    simpr.json
```

## Adding another storage backend

1. Implement the interface in `action/src/lib/storage.mjs` (for example `s3Storage(config)`).
2. Replace the `Upload build` step with an upload to that backend, and give it a stable `id` and `name`.
3. On the Mac, implement `ArtifactFetching` for the backend and choose it from the link (a new `store=` parameter, bumping `v`).
