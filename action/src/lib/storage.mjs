// Build storage. v1 stores builds as GitHub Actions artifacts; this is the only
// module that knows that. To add S3 or Cloudflare R2 later, implement the same
// interface and swap the upload step in action.yml (see docs/architecture.md).
//
// interface Storage {
//   findByName(name)       -> Build[]   live and expired builds with exactly this name
//   list({ maxPages })     -> Build[]   all builds (any PR), newest first
//   listForRun(runId)      -> Build[]   builds uploaded by one workflow run
//   get(id)                -> Build | null
//   delete(id)             -> boolean   false if it was already gone
//   downloadUrl(id)        -> string    short-lived URL that needs no token
// }
//
// Build objects use GitHub's artifact shape: { id, name, created_at, expires_at,
// expired, size_in_bytes, workflow_run: { id, head_sha } }.

export function githubArtifactsStorage(repo) {
  return {
    kind: 'github-artifacts',
    findByName: (name) => repo.findArtifactsByName(name),
    list: (options) => repo.listArtifacts(options),
    listForRun: (runId) => repo.listRunArtifacts(runId),
    get: (id) => repo.getArtifact(id),
    delete: (id) => repo.deleteArtifact(id),
    downloadUrl: (id) => repo.artifactDownloadUrl(id),
  };
}
