# SimPR for Mac

## Install

```sh
brew install --cask dromerobarria/simpr/simpr
```

or download `SimPR-x.y.z.dmg` from [Releases](https://github.com/dromerobarria/SimPR/releases/latest). You need macOS 14+ and Xcode with at least one iOS Simulator runtime (Xcode › Settings › Components).

## Sign in

GitHub requires a token to download build artifacts, even from public repositories.

- **Sign in with GitHub** (Settings › GitHub): SimPR shows a code. Click "Copy Code and Open GitHub", paste the code, and approve. Tick "Include private repositories" to request the `repo` scope.
- **Use GitHub CLI sign-in**: if you've run `gh auth login`, SimPR can reuse that token (`gh auth token`). This is on by default when SimPR has no token of its own.

## Using it

- Click **Run in iOS Simulator** on a PR. The first time, SimPR asks whether to trust the repository.
- The run panel shows progress. If you haven't chosen a simulator yet, it lists compatible ones (booted iPhones first) and can remember your choice.
- **Menu:** the five most recent builds (each with "Run again" and "Run on…"), Open Library…, the **Simulator** picker ("Ask each time" or a fixed default), the **Xcode** picker (shown when more than one Xcode is installed), "Reset App Data Before Launch", and sign-in state.
- **Choosing at run time:** with "Ask each time", the run panel lists compatible simulators, plus an Xcode picker when you have several. Switching Xcode reloads its simulators. Tick "Use this simulator next time" to make the choice your default.
- **Library** (⌘L from the menu): builds grouped by repo and PR, newest commit first. Search accepts `owner/repo`, `#123`, branch names or SHA prefixes. Per build: Run, Run on…, Pin/Unpin, Reveal in Finder, Open PR on GitHub, Copy Commit SHA, Delete. The footer shows the total size and the bulk actions. The toolbar can import a zip you downloaded by hand.
- **Settings › Library:** size limit (default 5 GB). Over the limit, the oldest unpinned builds are deleted. Pinned builds are never deleted automatically.
- **Settings › General › Xcode:** which Xcode's `simctl` to use. "Automatic" uses `xcode-select`, or, if that points at the Command Line Tools, the newest *release* `/Applications/Xcode*.app` (betas only if nothing else is installed). Xcode 27 betas don't include Simulator.app, so SimPR falls back to any installed Simulator, or to DeviceHub, to show the window.

## Error messages

| Message | What to do |
|---|---|
| "This build needs iOS X or later…" | Install a newer iOS Simulator runtime in Xcode › Settings › Components. |
| "This build only contains x86_64, but this Mac needs arm64…" | Ask the team to build universal binaries (the action's default `archs`). |
| "This build has expired on GitHub…" | Click "Open Workflow Run" and **Re-run all jobs**. |
| "The build or repository wasn't found…" | Sign in with private-repo access, or ask your org to approve the SimPR OAuth app (or use the `gh` sign-in). |
| "Xcode isn't selected…" | Install Xcode, or pick one in Settings › General. |

## Building from source

```sh
brew install xcodegen
cd mac-app
xcodegen generate
open SimPR.xcodeproj         # or: Scripts/test.sh
```

`Scripts/test.sh` runs the `SimPRCore` tests and builds the app unsigned.

### Your own OAuth app (for "Sign in with GitHub")

1. GitHub › Settings › Developer settings › **OAuth Apps** › New OAuth App. The homepage and callback URL can both be the repo URL (device flow doesn't use the callback).
2. Tick **Enable Device Flow**.
3. Put the client ID in `project.yml` (`SIMPR_GITHUB_CLIENT_ID`), or pass it to `Scripts/package.sh` as an environment variable. Client IDs aren't secret, and no client secret is needed.

### Releasing

```sh
DEVELOPMENT_TEAM=ABCDE12345 SIMPR_GITHUB_CLIENT_ID=Ov23li... mac-app/Scripts/package.sh
```

This archives a universal Release build, signs it with Developer ID, builds a DMG, notarizes and staples it, and prints the SHA-256. Upload the DMG to a release tagged `mac-vX.Y.Z`, then update `mac-app/Packaging/simpr.rb` in the `dromerobarria/homebrew-simpr` tap.

### Debug test hooks

Debug builds accept `-SimPRImport /path/build.zip` and `-SimPROpenURL 'simpr://run?…'` launch arguments. Release builds compile them out.
