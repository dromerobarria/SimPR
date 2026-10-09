// Minimal GitHub REST client built on fetch. No dependencies.

export class GitHubError extends Error {
  constructor(method, path, status, body) {
    super(`GitHub API ${method} ${path} failed with ${status}: ${truncate(body)}`);
    this.status = status;
    this.body = body;
  }
}

function truncate(value) {
  const text = typeof value === 'string' ? value : JSON.stringify(value);
  return text && text.length > 300 ? `${text.slice(0, 300)}…` : text;
}

export function createClient({
  token,
  apiUrl = 'https://api.github.com',
  fetchImpl = globalThis.fetch,
  userAgent = 'simpr-action',
}) {
  const base = apiUrl.replace(/\/$/, '');

  async function request(method, path, { body, query, redirect = 'follow', accept } = {}) {
    const url = new URL(base + path);
    for (const [k, v] of Object.entries(query ?? {})) {
      if (v !== undefined && v !== null) url.searchParams.set(k, String(v));
    }
    const headers = {
      Accept: accept ?? 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': userAgent,
    };
    if (token) headers.Authorization = `Bearer ${token}`;
    if (body !== undefined) headers['Content-Type'] = 'application/json';

    const res = await fetchImpl(url, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      redirect,
    });
    if (redirect === 'manual' && res.status >= 300 && res.status < 400) {
      return { status: res.status, headers: res.headers, data: null };
    }
    const text = res.status === 204 ? '' : await res.text();
    let data = text;
    if (text && (res.headers.get('content-type') ?? '').includes('json')) {
      try {
        data = JSON.parse(text);
      } catch {
        // keep raw text
      }
    }
    if (res.status >= 400) throw new GitHubError(method, path, res.status, data);
    return { status: res.status, headers: res.headers, data };
  }

  /** Iterates pages of a list endpoint. `key` selects the array in wrapped responses. */
  async function* paginate(path, { query = {}, key, maxPages = 10 } = {}) {
    for (let page = 1; page <= maxPages; page++) {
      const { data } = await request('GET', path, { query: { ...query, per_page: 100, page } });
      const items = key ? data[key] : data;
      if (!Array.isArray(items) || items.length === 0) return;
      yield* items;
      if (items.length < 100) return;
    }
  }

  return { request, paginate };
}

/** Repository-scoped helpers used by the action. */
export function repoApi(client, repository) {
  const [owner, repo] = repository.split('/');
  if (!owner || !repo) throw new Error(`Invalid repository: ${repository}`);
  const r = `/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}`;

  return {
    repository,

    async findArtifactsByName(name) {
      const { data } = await client.request('GET', `${r}/actions/artifacts`, {
        query: { name, per_page: 100 },
      });
      return data.artifacts ?? [];
    },

    async listArtifacts({ maxPages = 10 } = {}) {
      const out = [];
      for await (const a of client.paginate(`${r}/actions/artifacts`, { key: 'artifacts', maxPages })) {
        out.push(a);
      }
      return out;
    },

    async listRunArtifacts(runId) {
      const out = [];
      for await (const a of client.paginate(`${r}/actions/runs/${runId}/artifacts`, { key: 'artifacts' })) {
        out.push(a);
      }
      return out;
    },

    async getArtifact(id) {
      try {
        const { data } = await client.request('GET', `${r}/actions/artifacts/${id}`);
        return data;
      } catch (e) {
        if (e.status === 404) return null;
        throw e;
      }
    },

    async deleteArtifact(id) {
      try {
        await client.request('DELETE', `${r}/actions/artifacts/${id}`);
        return true;
      } catch (e) {
        if (e.status === 404) return false;
        throw e;
      }
    },

    /** Returns the short-lived (about 1 minute) download URL of an artifact. */
    async artifactDownloadUrl(id) {
      const res = await client.request('GET', `${r}/actions/artifacts/${id}/zip`, { redirect: 'manual' });
      const location = res.headers.get('location');
      if (!location) throw new Error(`No download location for artifact ${id} (status ${res.status})`);
      return location;
    },

    async getPull(number) {
      const { data } = await client.request('GET', `${r}/pulls/${number}`);
      return data;
    },

    async getRun(runId) {
      try {
        const { data } = await client.request('GET', `${r}/actions/runs/${runId}`);
        return data;
      } catch (e) {
        if (e.status === 404) return null;
        throw e;
      }
    },

    async listIssueComments(number) {
      const out = [];
      for await (const c of client.paginate(`${r}/issues/${number}/comments`, { maxPages: 30 })) {
        out.push(c);
      }
      return out;
    },

    async createComment(number, body) {
      const { data } = await client.request('POST', `${r}/issues/${number}/comments`, { body: { body } });
      return data;
    },

    async updateComment(id, body) {
      const { data } = await client.request('PATCH', `${r}/issues/comments/${id}`, { body: { body } });
      return data;
    },
  };
}
