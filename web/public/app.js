import {
  parseRunParams,
  schemeUrl,
  downloadUrl,
  terminalCommand,
  formatBytes,
  isMac,
  MAC_APP,
} from './params.mjs';

// How long to wait for the Mac app before showing the no-app path.
const APP_TIMEOUT_MS = 1500;

const $ = (selector) => document.querySelector(selector);
const sections = ['opening', 'opened', 'fallback', 'invalid', 'home'];

function show(id) {
  for (const s of sections) $(`#${s}`).hidden = s !== id;
}

function setText(field, text) {
  for (const el of document.querySelectorAll(`[data-field="${field}"]`)) {
    el.textContent = text;
    el.hidden = !text;
  }
}

function describe(value) {
  const title = `${value.app ?? 'App'} · ${value.repo} #${value.pr}`;
  const meta = [
    `commit ${value.sha.slice(0, 7)}`,
    value.minos && `iOS ${value.minos}+`,
    value.arch && value.arch.replace(',', ' + '),
    value.size && formatBytes(value.size),
  ]
    .filter(Boolean)
    .join(' · ');
  setText('title', title);
  setText('meta', meta);
  setText('appfile', value.appfile ?? 'the .app');
  document.title = `${value.app ?? 'Build'} · SimPR`;
}

async function copy(text, button) {
  try {
    await navigator.clipboard.writeText(text);
    button.textContent = 'Copied';
  } catch {
    button.textContent = 'Select and copy';
  }
  setTimeout(() => {
    button.textContent = 'Copy';
  }, 2000);
}

function setupLinks() {
  $('#releases').href = MAC_APP.releases;
  $('#home-releases').href = MAC_APP.releases;
  $('#home-docs').href = MAC_APP.docs;
  $('#brew').textContent = MAC_APP.brew;
  document.querySelector('[data-action="copy-brew"]').addEventListener('click', (e) => copy(MAC_APP.brew, e.currentTarget));
}

/**
 * Tries the simpr:// link. The page losing focus or visibility right after
 * means the browser handed the link to the app (or is asking permission to).
 */
function tryOpenApp(value) {
  show('opening');
  let settled = false;
  const opened = () => {
    if (settled) return;
    settled = true;
    cleanup();
    show('opened');
  };
  const onVisibility = () => {
    if (document.visibilityState === 'hidden') opened();
  };
  const timer = setTimeout(() => {
    if (settled) return;
    settled = true;
    cleanup();
    show('fallback');
  }, APP_TIMEOUT_MS);
  function cleanup() {
    clearTimeout(timer);
    window.removeEventListener('blur', opened);
    document.removeEventListener('visibilitychange', onVisibility);
  }
  window.addEventListener('blur', opened);
  document.addEventListener('visibilitychange', onVisibility);
  window.location.href = schemeUrl(value);
}

function main() {
  setupLinks();
  const params = new URLSearchParams(window.location.search);
  if ([...params.keys()].length === 0) {
    show('home');
    return;
  }

  const result = parseRunParams(params);
  if (!result.ok) {
    const list = $('#errors');
    for (const error of result.errors) {
      const li = document.createElement('li');
      li.textContent = error;
      list.append(li);
    }
    show('invalid');
    return;
  }

  const value = result.value;
  describe(value);
  $('#download').href = downloadUrl(value);
  const command = terminalCommand(value);
  if (command) {
    $('#command').textContent = command;
    document.querySelector('[data-action="copy"]').addEventListener('click', (e) => copy(command, e.currentTarget));
  } else {
    $('#terminal').hidden = true;
  }

  for (const b of document.querySelectorAll('[data-action="retry"]')) b.addEventListener('click', () => tryOpenApp(value));
  document.querySelector('[data-action="show-fallback"]').addEventListener('click', () => show('fallback'));

  if (!isMac(navigator.userAgent, navigator.platform, navigator.maxTouchPoints)) {
    $('#not-mac').hidden = false;
    show('fallback');
    return;
  }
  // "#no-app" skips straight to the no-app path (handy for docs and bookmarks).
  if (window.location.hash === '#no-app') {
    show('fallback');
    return;
  }
  tryOpenApp(value);
}

main();
