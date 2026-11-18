// api.js : appels vers le serveur LOCAL uniquement (même origine).
// Le jeton de session arrive dans le fragment d'URL (#s=…), est retiré aussitôt de la barre d'adresse
// et n'est conservé qu'en mémoire (spec 5.8). Recharger la page impose donc de relancer l'outil.

let token = '';

export function captureToken() {
  const params = new URLSearchParams(location.hash.slice(1));
  token = params.get('s') || '';
  if (params.has('s')) history.replaceState(null, '', location.pathname);
  return token !== '';
}

export class ApiError extends Error {
  /** kind : 'network' | 'session' | 'http' */
  constructor(kind, status, message) {
    super(message);
    this.kind = kind;
    this.status = status;
  }
}

async function request(method, path, body, signal) {
  let res;
  try {
    res = await fetch(path, {
      method,
      headers: body === undefined ? { 'X-Session': token } : { 'X-Session': token, 'Content-Type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
      cache: 'no-store',
      credentials: 'omit',
      redirect: 'error',
      signal,
    });
  } catch (e) {
    if (e && e.name === 'AbortError') throw e;
    throw new ApiError('network', 0, 'Serveur injoignable.');
  }
  let data = null;
  try { data = await res.json(); } catch { data = null; }
  if (res.status === 401) throw new ApiError('session', 401, (data && data.error) || 'Session invalide.');
  if (!res.ok) throw new ApiError('http', res.status, (data && data.error) || `Erreur HTTP ${res.status}.`);
  return data;
}

export const api = {
  status: () => request('GET', '/api/status'),
  search: (q, kind, limit, signal) =>
    request('GET', `/api/search?kind=${encodeURIComponent(kind)}&limit=${limit}&q=${encodeURIComponent(q)}`, undefined, signal),
  group: (id) => request('GET', `/api/group/${encodeURIComponent(id)}`),
  object: (id) => request('GET', `/api/object/${encodeURIComponent(id)}`),
  user: (id) => request('GET', `/api/user/${encodeURIComponent(id)}`),
  device: (id) => request('GET', `/api/device/${encodeURIComponent(id)}`),
  /** Lecture générique d'une fiche selon son type. */
  get(kind, id) { return api[kind](id); },
  refresh: (mode) => request('POST', '/api/refresh', { mode }),
  clearCache: () => request('POST', '/api/cache/clear', {}),
  shutdown: () => request('POST', '/api/shutdown', {}),
};
