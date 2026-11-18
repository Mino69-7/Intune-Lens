// status.js : pastille d'état et de synchronisation, interrogation périodique de /api/status.

import { $ } from './dom.js';
import { api } from '../api.js';
import { fmt, T, L } from '../i18n.js';
import { markChanged } from '../glass.js';

const FAST_MS = 1500;    // pendant une synchronisation
const SLOW_MS = 15000;   // au repos (détecte aussi l'arrêt du serveur)

export function createStatus({ onStatus, onError }) {
  let last = null;
  let timer = 0;

  function busy(s) { return !!s && (s.syncRunning || !['done', 'idle', 'error'].includes(s.phase)); }

  function percent(s) {
    const p = s.progress || {};
    return p.total > 0 ? Math.min(100, Math.floor((p.done / p.total) * 100)) : null;
  }

  /** Texte de la pastille (court) et libellé complet (lecteur d'écran / info-bulle). */
  function describe(s) {
    const parts = [];
    let dot = 'ok';
    const throttled = s.throttledUntil && new Date(s.throttledUntil) > new Date();
    if (s.lastSyncAt) parts.push(fmt.dataAge(s.lastSyncAt));
    if (s.counts) {
      parts.push(fmt.plural(s.counts.groups, L('groupe', 'group'), L('groupes', 'groups')));
      parts.push(fmt.plural(s.counts.objects, L('élément', 'item'), L('éléments', 'items')));
    }
    if (throttled) { parts.push(L('Microsoft ralentit les requêtes, reprise automatique', 'Microsoft is throttling requests, resuming automatically')); dot = 'warn'; }
    else if (busy(s)) {
      const pc = percent(s);
      parts.push(pc === null ? T.phase[s.phase] || L('Synchronisation', 'Syncing') : L(`Synchronisation ${pc} %`, `Syncing ${pc}%`));
      dot = 'syncing';
    } else if (s.phase === 'error' || s.error) { parts.push(L('Échec de la dernière synchronisation', 'Last sync failed')); dot = 'error'; }
    if (!s.ready) parts.unshift(busy(s) ? L('Première synchronisation', 'First sync') : L('Chargement des données…', 'Loading data…'));
    return { text: parts.join(' · '), dot };
  }

  /** Version courte, utilisée quand la barre du haut manque de place. */
  function shortText(s) {
    const throttled = s.throttledUntil && new Date(s.throttledUntil) > new Date();
    if (throttled) return L('Ralenti par Microsoft', 'Throttled by Microsoft');
    if (busy(s)) { const pc = percent(s); return pc === null ? L('Synchronisation…', 'Syncing…') : L(`Synchro ${pc} %`, `Sync ${pc}%`); }
    if (s.phase === 'error' || s.error) return L('Échec de synchro', 'Sync failed');
    if (!s.lastSyncAt) return L('Chargement…', 'Loading…');
    const d = new Date(s.lastSyncAt);
    return fmt.shortDateTime(d.toISOString());
  }

  function paint(s) {
    const d = describe(s);
    const el = $('status-text');
    el.dataset.full = d.text;
    el.dataset.short = shortText(s);
    el.textContent = d.text;
    $('status-btn').setAttribute('aria-label', L(`État : ${d.text}. Ouvrir le menu de synchronisation.`, `Status: ${d.text}. Open the sync menu.`));
    $('status-dot').className = `dot ${d.dot === 'ok' ? '' : d.dot}`;
    $('btn-refresh').classList.toggle('spinning', d.dot === 'syncing');
    markChanged($('status-pill'));
  }

  async function tick() {
    clearTimeout(timer);
    try {
      const s = await api.status();
      last = s;
      paint(s);
      onStatus(s);
      timer = setTimeout(tick, busy(s) ? FAST_MS : SLOW_MS);
    } catch (e) {
      onError(e);
      timer = setTimeout(tick, SLOW_MS);
    }
  }

  return {
    start: tick,
    refreshNow: tick,
    get: () => last,
  };
}
