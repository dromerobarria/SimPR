# FAQ

**Do I have to install the Mac app?**
No. Every comment has a **Download build** link and drag-and-drop steps, plus a terminal one-liner. The app adds one-click runs, compatibility checks, simulator selection and the local library.

**Why can't I double-click the `.app`?**
It's built for the iOS Simulator, not for macOS. Drag it onto a Simulator window, or use `xcrun simctl install booted <path>`.

**Why does the button go to a web page first?**
GitHub's Markdown removes links with custom schemes like `simpr://`. The page validates the link, opens the app, and shows the no-app path if nothing happens within about 1.5 seconds.

**Why do I need to sign in to download a build from a public repo?**
GitHub requires authentication for artifact downloads, even on public repositories.

**When does a build disappear?**
It's deleted when it's superseded by a build with different app code (default `keep-builds: 1`), when the PR is merged or closed, by the weekly sweep after `max-age-days` (default 30), or when GitHub's artifact retention runs out (90 days by default). Copies in the Mac app's library stay until you delete them or they're evicted by the size limit.

**My PR is older than the retention period.**
The sweep rewrites the comment to say the build expired. Open the latest SimPR workflow run for the PR and click **Re-run all jobs**.

**Docs-only pushes still start a runner.**
Add those paths to `paths-ignore` in `simpr.yml`. Pushes that start a run but don't change `app-paths` reuse the existing build in a few seconds.

**`paths-ignore` and required checks.**
If the SimPR job is a required status check, skipped workflows leave it pending. Either don't make it required, or drop `paths-ignore` and rely on the content key (a reuse run is fast).

**Can I use CocoaPods / SwiftPM private packages / code generation?**
Yes. Use [`simpr-inline.yml`](../examples/workflows/simpr-inline.yml) and add your setup steps before the SimPR step. Include `Pods` or generated sources in `app-paths` if they're committed.

**Can I build Release?**
Set `configuration: Release`. It's still an unsigned simulator build.

**The build fails only for x86_64.**
A binary dependency probably lacks an x86_64 simulator slice. SimPR retries arm64-only automatically. Set `archs: arm64` to skip the attempt. Intel Mac users then can't run the build, and the Mac app tells them why.

**Can I use S3 or R2 instead of artifacts?**
Not in v1. Storage sits behind a small interface (see [architecture.md](architecture.md#adding-another-storage-backend)).

**Does it work with GitHub Enterprise Server?**
The action uses `GITHUB_API_URL` and `GITHUB_SERVER_URL`, so it should, given `actions/upload-artifact@v7` support. The Mac app currently talks to github.com only.
