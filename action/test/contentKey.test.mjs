import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { computeContentKey, parseList, normalizePath, findLockfiles } from '../src/lib/contentKey.mjs';

const fakeRepo = (objects, files = []) => ({
  revParse: (rev) => objects[rev] ?? null,
  lsFiles: () => files,
});

test('parseList splits newlines and commas, trims, dedupes and skips comments', () => {
  assert.deepEqual(parseList(' App/ ,Shared\n\n# comment\nApp/\n'), ['App/', 'Shared']);
  assert.deepEqual(parseList(''), []);
  assert.deepEqual(parseList(undefined), []);
});

test('normalizePath', () => {
  assert.equal(normalizePath('./App/'), 'App');
  assert.equal(normalizePath('App//Sources'), 'App/Sources');
  assert.equal(normalizePath('.'), '.');
  assert.equal(normalizePath('./'), '.');
  assert.throws(() => normalizePath('../secrets'));
  assert.throws(() => normalizePath('/etc'));
  assert.throws(() => normalizePath('App/../../x'));
});

test('findLockfiles picks known lockfiles anywhere in the tree', () => {
  const files = ['README.md', 'App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved', 'Podfile.lock', 'docs/Podfile.lock.md'];
  assert.deepEqual(findLockfiles(files), [
    'App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved',
    'Podfile.lock',
  ]);
});

test('key is stable and independent of input order', () => {
  const repo = fakeRepo({ 'HEAD:App': 'aaa', 'HEAD:Shared': 'bbb', 'HEAD:Podfile.lock': 'ccc' }, ['Podfile.lock']);
  const a = computeContentKey({ appPaths: ['App', 'Shared'], settings: { scheme: 'App' }, ...repo });
  const b = computeContentKey({ appPaths: ['Shared/', './App'], settings: { scheme: 'App' }, ...repo });
  assert.equal(a.key, b.key);
  assert.match(a.key, /^[0-9a-f]{16}$/);
  assert.ok(a.inputs.includes('path:Podfile.lock=ccc'));
});

test('key changes when an app path, a lockfile or a setting changes', () => {
  const base = { 'HEAD:App': 'aaa', 'HEAD:Podfile.lock': 'ccc' };
  const files = ['Podfile.lock'];
  const k = (objects, settings = { scheme: 'App' }) =>
    computeContentKey({ appPaths: ['App'], settings, ...fakeRepo(objects, files) }).key;
  const original = k(base);
  assert.notEqual(k({ ...base, 'HEAD:App': 'aab' }), original);
  assert.notEqual(k({ ...base, 'HEAD:Podfile.lock': 'ccd' }), original);
  assert.notEqual(k(base, { scheme: 'App', configuration: 'Release' }), original);
  assert.equal(k(base, { scheme: 'App', configuration: '' }), original, 'empty settings are ignored');
});

test('missing paths are recorded, not fatal', () => {
  const { inputs } = computeContentKey({ appPaths: ['Nope'], ...fakeRepo({}) });
  assert.ok(inputs.includes('path:Nope=missing'));
});

test('whole-repo key uses the root tree and skips lockfile lookups', () => {
  let listed = false;
  const { inputs } = computeContentKey({
    appPaths: ['.'],
    revParse: (rev) => (rev === 'HEAD^{tree}' ? 'root' : null),
    lsFiles: () => {
      listed = true;
      return [];
    },
  });
  assert.ok(inputs.includes('path:.=root'));
  assert.equal(listed, false);
});

test('with a real git repo: docs-only commits keep the key, app commits change it', () => {
  const dir = mkdtempSync(join(tmpdir(), 'simpr-key-'));
  const git = (...args) => execFileSync('git', args, { cwd: dir, encoding: 'utf8' }).trim();
  git('init', '-q');
  git('config', 'user.email', 'test@example.com');
  git('config', 'user.name', 'Test');
  mkdirSync(join(dir, 'App'));
  mkdirSync(join(dir, 'docs'));
  writeFileSync(join(dir, 'App', 'main.swift'), 'print("hi")\n');
  writeFileSync(join(dir, 'Package.resolved'), '{}\n');
  writeFileSync(join(dir, 'docs', 'README.md'), '# Docs\n');
  git('add', '.');
  git('commit', '-qm', 'initial');

  const key = () =>
    computeContentKey({
      appPaths: ['App'],
      settings: { scheme: 'App' },
      revParse: (rev) => {
        try {
          return git('rev-parse', '--verify', '--quiet', rev);
        } catch {
          return null;
        }
      },
      lsFiles: () => git('ls-files', '-z').split('\0').filter(Boolean),
    }).key;

  const k1 = key();
  writeFileSync(join(dir, 'docs', 'README.md'), '# Docs, edited\n');
  git('commit', '-qam', 'docs');
  assert.equal(key(), k1, 'docs-only change keeps the key');

  writeFileSync(join(dir, 'Package.resolved'), '{"pins":[]}\n');
  git('commit', '-qam', 'deps');
  const k2 = key();
  assert.notEqual(k2, k1, 'lockfile change changes the key');

  writeFileSync(join(dir, 'App', 'main.swift'), 'print("bye")\n');
  git('commit', '-qam', 'app');
  assert.notEqual(key(), k2, 'app change changes the key');
});
