// Renders the sticky PR comment and the links it contains.

export const COMMENT_MARKER = '<!-- simpr:comment -->';
const STATE_RE = /<!-- simpr:state (\{.*?\}) -->/;

export const MAC_APP_URL = 'https://github.com/dromerobarria/SimPR#install-the-mac-app';

/** Quotes a value for POSIX shells. */
export function shellQuote(value) {
  const s = String(value);
  if (/^[A-Za-z0-9_./:@%+=,-]+$/.test(s)) return s;
  return `'${s.replace(/'/g, `'\\''`)}'`;
}

function baseUrl(redirectBaseUrl) {
  const url = new URL(redirectBaseUrl);
  if (url.protocol !== 'https:' && url.hostname !== 'localhost') {
    throw new Error('redirect-base-url must use https');
  }
  // Treat the base as a directory: ".../simpr" and ".../simpr/" are the same.
  if (url.pathname.endsWith('/index.html')) url.pathname = url.pathname.slice(0, -'index.html'.length);
  if (!url.pathname.endsWith('/')) url.pathname += '/';
  url.search = '';
  url.hash = '';
  return url;
}

export function badgeUrl(redirectBaseUrl) {
  return new URL('badge.svg', baseUrl(redirectBaseUrl)).toString();
}

/** The https link behind the button. The page then opens simpr://run?... */
export function runPageUrl(redirectBaseUrl, { manifest, artifact }) {
  const url = baseUrl(redirectBaseUrl);
  const params = {
    v: '1',
    repo: manifest.repository,
    pr: manifest.prNumber,
    sha: manifest.commitSha,
    run: artifact.runId,
    artifact: artifact.id,
    name: artifact.name,
    app: manifest.appName,
    bundle: manifest.bundleId,
    folder: manifest.folderName,
    appfile: manifest.appBundleName,
    minos: manifest.minimumOSVersion,
    arch: manifest.architectures.join(','),
    key: manifest.contentKey,
    size: artifact.sizeBytes,
  };
  for (const [k, v] of Object.entries(params)) {
    if (v !== undefined && v !== null && v !== '') url.searchParams.set(k, String(v));
  }
  return url.toString();
}

export function artifactPageUrl(serverUrl, repository, runId, artifactId) {
  return `${serverUrl.replace(/\/$/, '')}/${repository}/actions/runs/${runId}/artifacts/${artifactId}`;
}

/** Terminal one-liner for people without the Mac app. Requires the GitHub CLI. */
export function terminalCommand({ manifest, artifact }) {
  const appPath = `"$D"/${shellQuote(manifest.folderName)}/${shellQuote(manifest.appBundleName)}`;
  return [
    'D="$(mktemp -d)" && \\',
    `gh api repos/${manifest.repository}/actions/artifacts/${artifact.id}/zip > "$D/build.zip" && \\`,
    'ditto -x -k "$D/build.zip" "$D" && \\',
    'open -a Simulator && \\',
    'until xcrun simctl list devices booted | grep -q Booted; do sleep 1; done && \\',
    `xcrun simctl install booted ${appPath} && \\`,
    `xcrun simctl launch booted ${shellQuote(manifest.bundleId)}`,
  ].join('\n');
}

export function formatBytes(bytes) {
  if (!Number.isFinite(bytes) || bytes < 0) return 'unknown';
  const units = ['B', 'KB', 'MB', 'GB'];
  let value = bytes;
  let unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  return `${unit === 0 ? value : value.toFixed(1)} ${units[unit]}`;
}

function formatDate(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return 'unknown';
  return `${d.toISOString().slice(0, 16).replace('T', ' ')} UTC`;
}

function escapeMarkdown(text) {
  return String(text)
    .replace(/[\\`*_{}[\]|#!]/g, (c) => `\\${c}`)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

function stateComment(state) {
  // JSON inside an HTML comment: make sure it can't close the comment early.
  return `<!-- simpr:state ${JSON.stringify(state).replace(/--/g, '\\u002d\\u002d')} -->`;
}

export function parseState(body) {
  const match = STATE_RE.exec(body ?? '');
  if (!match) return null;
  try {
    return JSON.parse(match[1]);
  } catch {
    return null;
  }
}

export function renderReadyComment({ manifest, artifact, redirectBaseUrl, serverUrl = 'https://github.com', reused = false }) {
  const runUrl = runPageUrl(redirectBaseUrl, { manifest, artifact });
  const downloadUrl = artifactPageUrl(serverUrl, manifest.repository, artifact.runId, artifact.id);
  const sha7 = manifest.commitSha.slice(0, 7);
  const commitUrl = `${serverUrl}/${manifest.repository}/commit/${manifest.commitSha}`;
  const xcode = manifest.xcodeBuild ? `${manifest.xcodeVersion} (${manifest.xcodeBuild})` : manifest.xcodeVersion;
  // Shown inside code spans, where only backticks are special.
  const appFile = manifest.appBundleName.replace(/`/g, "'");

  const rows = [
    ['Commit', `[\`${sha7}\`](${commitUrl})`],
    ['Built', formatDate(manifest.buildDate)],
    ['Size', `${formatBytes(artifact.sizeBytes)} download, ${formatBytes(manifest.appSizeBytes)} installed`],
    ['Minimum iOS', escapeMarkdown(manifest.minimumOSVersion)],
    ['Xcode', escapeMarkdown(`${xcode ?? 'unknown'}, iOS Simulator SDK ${manifest.sdkVersion ?? 'unknown'}`)],
    ['Architectures', manifest.architectures.join(', ')],
  ];
  if (artifact.expiresAt) rows.push(['Available until', `${formatDate(artifact.expiresAt)}`]);

  return [
    COMMENT_MARKER,
    `### 📱 ${escapeMarkdown(manifest.appName)} is ready to run`,
    '',
    `[![Run in iOS Simulator](${badgeUrl(redirectBaseUrl)})](${runUrl})`,
    '',
    `**[⬇️ Download build](${downloadUrl})** (no app needed: unzip it and drag \`${appFile}\` onto Simulator)`,
    '',
    '| | |',
    '|---|---|',
    ...rows.map(([k, v]) => `| ${k} | ${v} |`),
    '',
    '<details>',
    '<summary><b>Run it without the SimPR app</b></summary>',
    '',
    '1. Click **Download build** above while signed in to GitHub. Safari unzips it automatically; in other browsers, double-click the downloaded zip.',
    '2. Open Simulator: run `open -a Simulator` in Terminal, or in Xcode choose **Xcode › Open Developer Tool › Simulator**.',
    `3. Drag \`${appFile}\` from the unzipped folder onto the Simulator window. Simulator installs and launches it.`,
    '',
    `> [!NOTE]`,
    `> Double-clicking \`${appFile}\` does **not** work. It is an iOS Simulator build, and macOS can't run it directly.`,
    '',
    'Or paste this into Terminal (needs the [GitHub CLI](https://cli.github.com), signed in with `gh auth login`):',
    '',
    '```sh',
    terminalCommand({ manifest, artifact }),
    '```',
    '',
    '</details>',
    '',
    `<sub>${reused ? '♻️ No app changes since the last build, so the existing build was reused. ' : ''}` +
      `Builds are deleted when this PR is merged or closed. If the build has expired, re-run the latest workflow run to rebuild it. ` +
      `💡 Install the [SimPR Mac app](${MAC_APP_URL}) for one-click runs and a local history of builds.</sub>`,
    '',
    stateComment({
      status: 'ready',
      artifactId: artifact.id,
      artifactName: artifact.name,
      runId: artifact.runId,
      contentKey: manifest.contentKey,
      sha: manifest.commitSha,
    }),
  ].join('\n');
}

const EXPIRED_REASONS = {
  merged: 'this pull request was merged',
  closed: 'this pull request was closed',
  retention: 'it passed the artifact retention period',
  maxAge: 'it passed the maximum build age',
};

export function renderExpiredComment({ reason, previousState }) {
  const why = EXPIRED_REASONS[reason] ?? 'it is no longer available';
  const rebuild =
    reason === 'retention' || reason === 'maxAge'
      ? '\n\nTo rebuild it, open the latest run of the SimPR workflow for this PR and click **Re-run all jobs**.'
      : '';
  return [
    COMMENT_MARKER,
    '### 📱 SimPR build expired',
    '',
    `The simulator build for this PR was deleted from GitHub because ${why}.${rebuild}`,
    '',
    `<sub>Builds already downloaded with the [SimPR Mac app](${MAC_APP_URL}) stay in its local library and can still be run.</sub>`,
    '',
    stateComment({ ...(previousState ?? {}), status: 'expired', reason }),
  ].join('\n');
}

export function renderBuildingFailedComment({ runUrl }) {
  return [
    COMMENT_MARKER,
    '### 📱 SimPR build failed',
    '',
    `The simulator build for the latest commit failed. See the [workflow run](${runUrl}) for details.`,
    '',
    stateComment({ status: 'failed' }),
  ].join('\n');
}

/**
 * Picks the sticky comment among a PR's comments.
 * Prefers comments written by GitHub Actions, since those are the ones the
 * workflow token is allowed to edit.
 */
export function findStickyComment(comments, { authorLogin } = {}) {
  const marked = comments.filter((c) => typeof c.body === 'string' && c.body.startsWith(COMMENT_MARKER));
  if (authorLogin) return marked.find((c) => c.user?.login === authorLogin) ?? null;
  return (
    marked.find((c) => c.user?.login === 'github-actions[bot]') ??
    marked.find((c) => c.user?.type === 'Bot') ??
    null
  );
}
