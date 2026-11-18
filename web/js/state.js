// state.js : per-browser conveniences (recent searches). Every storage access is guarded:
// the interface works normally when storage is unavailable.
//
// Language and theme are NOT stored here: browser storage is tied to the port, which changes at
// every launch. They are saved by the server (%LOCALAPPDATA%\IntuneAssignLens\prefs.json).

const KEY_RECENT = 'ial.recent.v1';
const MAX_RECENT = 8;

function read(key, fallback) {
  try {
    const v = localStorage.getItem(key);
    return v ? JSON.parse(v) : fallback;
  } catch { return fallback; }
}
function write(key, value) {
  try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* storage unavailable */ }
}

export const store = {
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
