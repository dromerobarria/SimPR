// Parameter validation and link building for the SimPR redirect page.
// Pure functions, shared by the page and its tests.

export const MAC_APP = Object.freeze({
  releases: 'https://github.com/dromerobarria/SimPR/releases/latest',
  brew: 'brew install --cask dromerobarria/simpr/simpr',
  docs: 'https://github.com/dromerobarria/SimPR#readme',
});

const RE = {
  repo: /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\/[A-Za-z0-9._-]{1,100}$/,
  int: /^[1-9][0-9]{0,15}$/,
  sha: /^[0-9a-f]{40}$/,
  name: /^simpr-pr-\d+-[0-9a-f]{8,64}\.zip$/,
  bundle: /^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/,
  folder: /^[A-Za-z0-9._-]{1,200}$/,
  appfile: /^[^/\\\0]{1,200}\.app$/,
  version: /^\d+(\.\d+){0,2}$/,
  key: /^[0-9a-f]{8,64}$/,
};

const ARCHS = new Set(['arm64', 'x86_64']);

/** Field specs: [name, required, validator]. */
const FIELDS = [
  ['repo', true, (v) => RE.repo.test(v) && !v.split('/')[1].startsWith('.')],
  ['pr', true, (v) => RE.int.test(v)],
  ['sha', true, (v) => RE.sha.test(v)],
  ['run', true, (v) => RE.int.test(v)],
  ['artifact', true, (v) => RE.int.test(v)],
  ['name', false, (v) => RE.name.test(v)],
  ['app', false, (v) => v.length <= 100 && !/[\u0000-\u001f\u007f]/.test(v)],
  ['bundle', false, (v) => RE.bundle.test(v) && v.length <= 255],
  ['folder', false, (v) => RE.folder.test(v) && !/^\.+$/.test(v)],
  ['appfile', false, (v) => RE.appfile.test(v) && !v.includes('..')],
  ['minos', false, (v) => RE.version.test(v)],
  ['arch', false, (v) => v.split(',').every((a) => ARCHS.has(a))],
  ['key', false, (v) => RE.key.test(v)],
  ['size', false, (v) => RE.int.test(v)],
];

/**
 * Validates query parameters.
 * @param {URLSearchParams} params
 * @returns {{ ok: true, value: object } | { ok: false, errors: string[] }}
 */
export function parseRunParams(params) {
  const value = {};
  const errors = [];
  for (const [name, required, valid] of FIELDS) {
    const raw = params.get(name);
    if (raw === null || raw === '') {
      if (required) errors.push(`Missing "${name}".`);
      continue;
    }
    if (!valid(raw)) {
      errors.push(`Invalid "${name}".`);
      continue;
    }
    value[name] = raw;
  }
  if (value.name && value.pr && !value.name.startsWith(`simpr-pr-${value.pr}-`)) {
    errors.push('"name" does not match "pr".');
  }
  return errors.length ? { ok: false, errors } : { ok: true, value };
}

/** The custom-scheme URL handled by the SimPR Mac app. Only validated fields are forwarded. */
export function schemeUrl(value) {
  const out = new URLSearchParams();
  for (const [name] of FIELDS) {
    if (value[name] !== undefined) out.set(name, value[name]);
  }
  out.set('v', '1');
  return `simpr://run?${out.toString()}`;
}

/** GitHub's artifact page. The browser downloads the build when the user is signed in. */
export function downloadUrl(value) {
  return `https://github.com/${value.repo}/actions/runs/${value.run}/artifacts/${value.artifact}`;
}

export function pullUrl(value) {
  return `https://github.com/${value.repo}/pull/${value.pr}`;
}

export function shellQuote(value) {
  const s = String(value);
  if (/^[A-Za-z0-9_./:@%+=,-]+$/.test(s)) return s;
  return `'${s.replace(/'/g, `'\\''`)}'`;
}

/** Same command as the PR comment (action/src/lib/comment.mjs). Returns null if fields are missing. */
export function terminalCommand(value) {
  if (!value.folder || !value.appfile || !value.bundle) return null;
  return [
    'D="$(mktemp -d)" && \\',
    `gh api repos/${value.repo}/actions/artifacts/${value.artifact}/zip > "$D/build.zip" && \\`,
    'ditto -x -k "$D/build.zip" "$D" && \\',
    'open -a Simulator && \\',
    'until xcrun simctl list devices booted | grep -q Booted; do sleep 1; done && \\',
    `xcrun simctl install booted "$D"/${shellQuote(value.folder)}/${shellQuote(value.appfile)} && \\`,
    `xcrun simctl launch booted ${shellQuote(value.bundle)}`,
  ].join('\n');
}

export function formatBytes(bytes) {
  const n = Number(bytes);
  if (!Number.isFinite(n) || n < 0) return null;
  const units = ['B', 'KB', 'MB', 'GB'];
  let v = n;
  let u = 0;
  while (v >= 1000 && u < units.length - 1) {
    v /= 1000;
    u++;
  }
  return `${u === 0 ? v : v.toFixed(1)} ${units[u]}`;
}

/** Best-effort platform check: the app and the Simulator need a Mac. */
export function isMac(userAgent, platform = '', maxTouchPoints = 0) {
  // iPadOS reports a Mac user agent; touch points give it away.
  if (maxTouchPoints > 1) return false;
  return /Macintosh|Mac OS X/.test(userAgent) || /^Mac/.test(platform);
}
