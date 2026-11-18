// api.js : calls to the LOCAL server only (same origin).
// The session token arrives in the URL fragment (#s=…), is removed from the address bar at once
// and only kept in memory (spec 5.8). A manual reload therefore requires restarting the tool;
// reloadWithSession() is the one controlled exception (language change).
import { L, tx } from './i18n.js';

let token = '';

export function captureToken() {
  const params = new URLSearchParams(location.hash.slice(1));
  token = params.get('s') || '';
  const go = params.get('go');   // screen to reopen after reloadWithSession()
  if (params.has('s')) history.replaceState(null, '', location.pathname + (go && /^\/[\w/%.-]*$/.test(go) ? `#${go}` : ''));
  return token !== '';
}

/** Reloads the page while keeping the session (same form as the launch URL), back on the current screen. */
export function reloadWithSession() {
  const route = location.hash.startsWith('#/') ? location.hash.slice(1) : '';
  const params = new URLSearchParams({ s: token });
  if (route) params.set('go', route);
  location.replace(`${location.pathname}#${params.toString()}`);
  location.reload();
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
    throw new ApiError('network', 0, L('Serveur injoignable.', 'Server unreachable.'));
  }
  let data = null;
  try { data = await res.json(); } catch { data = null; }
  if (res.status === 401) throw new ApiError('session', 401, tx(data && data.error) || L('Session invalide.', 'Invalid session.'));
  if (!res.ok) throw new ApiError('http', res.status, tx(data && data.error) || L(`Erreur HTTP ${res.status}.`, `HTTP error ${res.status}.`));
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
  /** Saved settings (language, theme), kept by the server across launches. */
  setPrefs: (prefs) => request('POST', '/api/prefs', prefs),
};
