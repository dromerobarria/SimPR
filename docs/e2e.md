# First end-to-end test

The end-to-end path uses this repository itself: `.github/workflows/example-app.yml` builds `examples/SampleApp` for every PR that touches it.

## 1. Publish the repository

```sh
cd SimPR
gh repo create dromerobarria/SimPR --public --source . --push
git tag v1 && git push origin v1          # the reusable workflows reference @v1
```

## 2. Enable GitHub Pages

Settings › Pages › Build and deployment › Source: **GitHub Actions**. Then run the **Pages** workflow (Actions › Pages › Run workflow). Check that `https://dromerobarria.github.io/SimPR/` shows the landing page and `…/badge.svg` loads.

## 3. Install the Mac app locally

```sh
cd mac-app && Scripts/test.sh
open ~/Library/Developer/Xcode/DerivedData/SimPR-cli/Build/Products/Debug/SimPR.app
```

Sign in through the menu bar icon (Settings › GitHub › Use GitHub CLI Sign-in works without an OAuth app).

## 4. Open a PR

```sh
git switch -c try-simpr
# edit any text in examples/SampleApp/SampleApp/SampleApp.swift, then:
git commit -am "Try SimPR" && git push -u origin try-simpr
gh pr create --fill
```

Wait for the **SimPR** workflow (about 3 to 6 minutes on `macos-latest`). Then check:

- [ ] One comment with the badge, Download build, commit/size/minimum iOS/Xcode, the `<details>` steps and the one-liner.
- [ ] **Run in iOS Simulator** → the page → SimPR asks "Run build from dromerobarria/SimPR?" → the sample app launches in Simulator.
- [ ] Library shows the build under `dromerobarria/SimPR › #<PR>`.
- [ ] Open the page with `#no-app` appended: Download build gives a folder with `SampleApp.app`, and dragging it onto Simulator launches it.
- [ ] The one-liner from the comment works in Terminal.

## 5. Lifecycle

- [ ] Push a README-only change: the workflow doesn't start (paths filter).
- [ ] Re-run the workflow: the log says "Reusing build…", and the comment notes the reuse.
- [ ] Change `SampleApp.swift` again: a new build appears, the comment updates in place, and the old artifact is gone from the run page.
- [ ] Merge or close the PR: **SimPR cleanup** deletes the artifacts, and the comment says the build expired. The build is still runnable from the Mac app's Library.
- [ ] Actions › SimPR sweep › Run workflow (dry run): the log lists what it would delete.

## 6. Fork path (optional)

From a second account, fork the repo, change the sample app, and open a PR. The build runs in `build` mode, and **SimPR publish** posts the comment.
