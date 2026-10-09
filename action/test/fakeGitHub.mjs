// In-memory fake of the GitHub REST endpoints SimPR uses.

import { createServer } from 'node:http';

export async function startFakeGitHub({ repo = 'octo/sample' } = {}) {
  const state = {
    artifacts: [], // { id, name, created_at, expired, size_in_bytes, expires_at, workflow_run: { id, head_sha }, blob: Buffer }
    runs: new Map(), // id -> { id, conclusion, head_sha }
    pulls: new Map(), // number -> { number, state, merged_at, head: { sha } }
    comments: [], // { id, issue, body, user }
    nextId: 5000,
    requests: [],
  };

  const prefix = `/repos/${repo}`;
  const json = (res, status, body) => {
    res.writeHead(status, { 'content-type': 'application/json' });
    res.end(JSON.stringify(body));
  };
  const publicArtifact = ({ blob, ...a }) => a;

  const server = createServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    const chunks = [];
    for await (const c of req) chunks.push(c);
    const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString()) : undefined;
    state.requests.push({ method: req.method, path: url.pathname, auth: req.headers.authorization });

    let m;
    const p = url.pathname;
    if ((m = /^\/blob\/(\d+)$/.exec(p))) {
      const a = state.artifacts.find((x) => x.id === Number(m[1]));
      if (req.headers.authorization) return json(res, 400, { message: 'token leaked to blob storage' });
      res.writeHead(200, { 'content-type': 'application/zip' });
      return res.end(a.blob);
    }
    if (!p.startsWith(prefix)) return json(res, 404, { message: 'Not Found' });
    const rest = p.slice(prefix.length);

    if (req.method === 'GET' && rest === '/actions/artifacts') {
      const name = url.searchParams.get('name');
      const perPage = Number(url.searchParams.get('per_page') ?? 30);
      const page = Number(url.searchParams.get('page') ?? 1);
      const list = state.artifacts
        .filter((a) => !name || a.name === name)
        .sort((a, b) => b.id - a.id)
        .map(publicArtifact);
      return json(res, 200, { total_count: list.length, artifacts: list.slice((page - 1) * perPage, page * perPage) });
    }
    if ((m = /^\/actions\/artifacts\/(\d+)(\/zip)?$/.exec(rest))) {
      const a = state.artifacts.find((x) => x.id === Number(m[1]));
      if (!a) return json(res, 404, { message: 'Not Found' });
      if (req.method === 'DELETE') {
        state.artifacts = state.artifacts.filter((x) => x !== a);
        res.writeHead(204);
        return res.end();
      }
      if (m[2]) {
        if (a.expired) return json(res, 410, { message: 'Artifact has expired' });
        res.writeHead(302, { location: `http://127.0.0.1:${server.address().port}/blob/${a.id}` });
        return res.end();
      }
      return json(res, 200, publicArtifact(a));
    }
    if ((m = /^\/actions\/runs\/(\d+)(\/artifacts)?$/.exec(rest))) {
      const run = state.runs.get(Number(m[1]));
      if (!run) return json(res, 404, { message: 'Not Found' });
      if (m[2]) {
        const list = state.artifacts.filter((a) => a.workflow_run?.id === run.id).map(publicArtifact);
        const page = Number(url.searchParams.get('page') ?? 1);
        return json(res, 200, { total_count: list.length, artifacts: page === 1 ? list : [] });
      }
      return json(res, 200, run);
    }
    if ((m = /^\/pulls\/(\d+)$/.exec(rest))) {
      const pull = state.pulls.get(Number(m[1]));
      return pull ? json(res, 200, pull) : json(res, 404, { message: 'Not Found' });
    }
    if ((m = /^\/issues\/(\d+)\/comments$/.exec(rest))) {
      const issue = Number(m[1]);
      if (req.method === 'POST') {
        const c = { id: state.nextId++, issue, body: body.body, user: { login: 'github-actions[bot]', type: 'Bot' } };
        c.html_url = `https://github.com/${repo}/pull/${issue}#issuecomment-${c.id}`;
        state.comments.push(c);
        return json(res, 201, c);
      }
      const page = Number(url.searchParams.get('page') ?? 1);
      const list = state.comments.filter((c) => c.issue === issue);
      return json(res, 200, page === 1 ? list : []);
    }
    if ((m = /^\/issues\/comments\/(\d+)$/.exec(rest)) && req.method === 'PATCH') {
      const c = state.comments.find((x) => x.id === Number(m[1]));
      if (!c) return json(res, 404, { message: 'Not Found' });
      if (c.user.type !== 'Bot') return json(res, 403, { message: 'Forbidden' });
      c.body = body.body;
      return json(res, 200, c);
    }
    return json(res, 404, { message: `No fake for ${req.method} ${p}` });
  });

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return {
    state,
    url: `http://127.0.0.1:${server.address().port}`,
    close: () => new Promise((resolve) => server.close(resolve)),
    addArtifact(fields) {
      const a = {
        id: state.nextId++,
        created_at: new Date().toISOString(),
        expires_at: '2027-01-01T00:00:00Z',
        expired: false,
        size_in_bytes: fields.blob?.length ?? 1000,
        ...fields,
      };
      state.artifacts.push(a);
      return a;
    },
  };
}
