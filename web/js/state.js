// state.js : réglages et préférences locales (navigateur). Tout accès au stockage est protégé :
// l'interface fonctionne normalement si le stockage est indisponible.

// v2 : nouvelles valeurs par défaut (thème clair) ; l'ancienne clé v1 est ignorée.
const KEY_SETTINGS = 'ial.settings.v2';
const KEY_RECENT = 'ial.recent.v1';
const MAX_RECENT = 8;

function read(key, fallback) {
  try {
    const v = localStorage.getItem(key);
    return v ? JSON.parse(v) : fallback;
  } catch { return fallback; }
}
function write(key, value) {
  try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* stockage indisponible */ }
}

// Thème clair par défaut (préférence de l'utilisateur), même si Windows est en sombre.
// Deux thèmes seulement : clair / sombre (interrupteur « Mode sombre » dans ⚙, ou touche T).
const defaults = { theme: 'light', kind: 'group' };
const settings = { ...defaults, ...read(KEY_SETTINGS, {}) };
if (!['light', 'dark'].includes(settings.theme)) settings.theme = 'light';
delete settings.effects;   // réglage d'effets supprimé : verre « Léger » fixe
if (!['user', 'device', 'group', 'object'].includes(settings.kind)) settings.kind = 'group';

export const store = {
  get: (k) => settings[k],
  set(k, v) { settings[k] = v; write(KEY_SETTINGS, settings); },

  recent() {
    const r = read(KEY_RECENT, []);
    return Array.isArray(r) ? r.filter((x) => x && typeof x.id === 'string' && typeof x.name === 'string').slice(0, MAX_RECENT) : [];
  },
  addRecent(item) {
    const list = store.recent().filter((x) => !(x.id === item.id && x.kind === item.kind));
    list.unshift({ kind: item.kind, id: item.id, name: item.name });
    write(KEY_RECENT, list.slice(0, MAX_RECENT));
  },
  clearRecent() { write(KEY_RECENT, []); },
};
