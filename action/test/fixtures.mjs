export const manifest = Object.freeze({
  schemaVersion: 1,
  bundleId: 'dev.simpr.SampleApp',
  appName: 'Sample App',
  appBundleName: 'SampleApp.app',
  folderName: 'Sample-App-PR42-0123456',
  version: '1.0',
  buildNumber: '7',
  minimumOSVersion: '17.0',
  architectures: ['arm64', 'x86_64'],
  xcodeVersion: '26.6',
  xcodeBuild: '17F113',
  sdkVersion: '26.5',
  configuration: 'Debug',
  scheme: 'SampleApp',
  repository: 'octo/sample',
  prNumber: 42,
  commitSha: '0123456789abcdef0123456789abcdef01234567',
  contentKey: '0123456789abcdef',
  buildDate: '2026-10-09T12:34:56.000Z',
  appSizeBytes: 2_500_000,
});

export const artifact = Object.freeze({
  id: 1001,
  name: 'simpr-pr-42-0123456789abcdef.zip',
  runId: 555,
  sizeBytes: 1_234_567,
  expiresAt: '2027-01-07T12:34:56Z',
});

export function apiArtifact({ id, pr = 42, key = 'aaaaaaaaaaaaaaaa', created, expired = false, runId = 555, name }) {
  return {
    id,
    name: name ?? `simpr-pr-${pr}-${key}.zip`,
    created_at: created,
    expires_at: '2027-01-01T00:00:00Z',
    expired,
    size_in_bytes: 1000,
    workflow_run: runId ? { id: runId, head_sha: '0123456789abcdef0123456789abcdef01234567' } : null,
  };
}
