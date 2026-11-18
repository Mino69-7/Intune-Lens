// status.js : pastille d'état et de synchronisation, interrogation périodique de /api/status.

import { $ } from './dom.js';
import { api } from '../api.js';
import { fmt, T } from '../i18n.fr.js';
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
      parts.push(fmt.plural(s.counts.groups, 'groupe', 'groupes'));
      parts.push(fmt.plural(s.counts.objects, 'élément', 'éléments'));
    }
    if (throttled) { parts.push('Microsoft ralentit les requêtes, reprise automatique'); dot = 'warn'; }
    else if (busy(s)) {
      const pc = percent(s);
      parts.push(pc === null ? T.phase[s.phase] || 'Synchronisation' : `Synchronisation ${pc} %`);
      dot = 'syncing';
    } else if (s.phase === 'error' || s.error) { parts.push('Échec de la dernière synchronisation'); dot = 'error'; }
    if (!s.ready) parts.unshift(busy(s) ? 'Première synchronisation' : 'Chargement des données…');
    return { text: parts.join(' · '), dot };
  }

  /** Version courte, utilisée quand la barre du haut manque de place. */
  function shortText(s) {
    const throttled = s.throttledUntil && new Date(s.throttledUntil) > new Date();
    if (throttled) return 'Ralenti par Microsoft';
    if (busy(s)) { const pc = percent(s); return pc === null ? 'Synchronisation…' : `Synchro ${pc} %`; }
    if (s.phase === 'error' || s.error) return 'Échec de synchro';
    if (!s.lastSyncAt) return 'Chargement…';
    const d = new Date(s.lastSyncAt);
    return `${d.toLocaleDateString('fr-FR', { day: '2-digit', month: '2-digit' })} ${d.toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' })}`;
  }

  function paint(s) {
    const d = describe(s);
    const el = $('status-text');
    el.dataset.full = d.text;
    el.dataset.short = shortText(s);
    el.textContent = d.text;
    $('status-btn').setAttribute('aria-label', `État : ${d.text}. Ouvrir le menu de synchronisation.`);
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
