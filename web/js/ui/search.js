// search.js : champ de recherche (combobox ARIA) et suggestions instantanées.

import { $, h, rectIn } from './dom.js';
import { api } from '../api.js';
import { fmt, T } from '../i18n.fr.js';
import { markChanged } from '../glass.js';

const LIMIT = 10;

/** Texte secondaire d'une suggestion selon son type. */
export function suggestMeta(r) {
  if (r.kind === 'object') return `${r.family} · ${fmt.plural(r.count, 'assignation', 'assignations')}`;
  if (r.kind === 'user') return [String(r.upn || '').split('@')[0], fmt.plural(r.count, 'appareil', 'appareils')].filter(Boolean).join(' · ');
  if (r.kind === 'device') return [r.os, r.userName || 'Sans utilisateur', r.stale ? 'inactive' : ''].filter(Boolean).join(' · ');
  return fmt.plural(r.count, 'élément', 'éléments');
}

export function createSearch({ getKind, onOpen, onError, onCancelPick }) {
  const input = $('search-input');
  const list = $('suggestions');
  const root = $('glass-root');
  // Mode « Comparer avec… » : { kind, excludeId, label } ou null.
  let pick = null;
  let results = [];
  let active = -1;
  let seq = 0;
  let ctrl = null;
  let timer = 0;

  function position() {
    const r = rectIn($('search-pill'), root);
    list.style.left = `${r.left}px`;
    list.style.top = `${r.bottom + 8}px`;
    list.style.width = `${r.width}px`;
  }

  function close() {
    if (list.hidden) return;
    list.hidden = true;
    input.setAttribute('aria-expanded', 'false');
    input.removeAttribute('aria-activedescendant');
    active = -1;
    markChanged();
  }

  function open() {
    position();
    list.hidden = false;
    input.setAttribute('aria-expanded', 'true');
    markChanged();
  }

  function setActive(i) {
    const opts = list.querySelectorAll('[role="option"]');
    if (!opts.length) return;
    active = (i + opts.length) % opts.length;
    opts.forEach((o, k) => o.setAttribute('aria-selected', String(k === active)));
    input.setAttribute('aria-activedescendant', opts[active].id);
    opts[active].scrollIntoView({ block: 'nearest' });
  }

  /** Met en évidence la sous-chaîne si elle figure telle quelle (casse ignorée). */
  function highlighted(name, q) {
    const i = q ? name.toLowerCase().indexOf(q.toLowerCase()) : -1;
    if (i < 0) return [name];
    return [name.slice(0, i), h('mark', { text: name.slice(i, i + q.length) }), name.slice(i + q.length)];
  }

  function render(q, res) {
    results = (res.results || []).filter((r) => !pick || r.id !== pick.excludeId).slice(0, LIMIT);
    active = -1;
    if (!results.length) {
      list.replaceChildren(h('div', { class: 'suggest-empty', role: 'presentation', text: `Aucun résultat pour « ${q} ».` }));
      open();
      return;
    }
    const items = results.map((r, i) =>
      h('div', {
        class: 'suggest-item', role: 'option', id: `sug-${i}`, 'aria-selected': 'false',
        on: { click: () => choose(i) },
      }, [
        h('span', { class: 'suggest-name' }, highlighted(r.name, q.trim())),
        h('span', { class: 'suggest-meta', text: suggestMeta(r) }),
      ]));
    const total = `${fmt.num(res.total)}${res.totalCapped ? '+' : ''}`;
    items.push(h('div', { class: 'suggest-foot', role: 'presentation', text: `${total} résultat(s) · ${res.elapsedMs} ms · Entrée pour ouvrir` }));
    list.replaceChildren(...items);
    open();
  }

  async function run() {
    const q = input.value;
    const mine = ++seq;
    if (!q.trim()) { close(); list.replaceChildren(); return; }
    ctrl?.abort();
    ctrl = new AbortController();
    try {
      const res = await api.search(q, pick ? pick.kind : getKind(), LIMIT + 1, ctrl.signal);
      if (mine === seq && document.activeElement === input) render(q, res);
    } catch (e) {
      if (e.name === 'AbortError') return;
      if (e.kind === 'http' && e.status === 503 && mine === seq) {
        results = [];
        list.replaceChildren(h('div', { class: 'suggest-empty', role: 'presentation', text: 'Données en cours de chargement : la recherche sera disponible à la fin de la première synchronisation.' }));
        open();
        return;
      }
      onError(e);
    }
  }

  function choose(i) {
    const r = results[i];
    if (!r) return;
    close();
    input.value = '';
    onOpen(r);
  }

  input.addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(run, 60); });
  input.addEventListener('focus', () => { if (input.value.trim()) run(); });
  input.addEventListener('blur', () => setTimeout(() => { if (document.activeElement !== input) close(); }, 120));
  list.addEventListener('pointerdown', (e) => e.preventDefault());   // garde le focus dans le champ
  input.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowDown') { if (list.hidden) run(); else setActive(active + 1); }
    else if (e.key === 'ArrowUp') setActive(active - 1);
    else if (e.key === 'Enter') { if (!list.hidden && results.length) choose(active >= 0 ? active : 0); }
    else if (e.key === 'Escape') {
      if (!list.hidden) close();
      else if (input.value) input.value = '';
      else if (pick) onCancelPick?.();
      else input.blur();
    } else return;
    e.preventDefault();
    e.stopPropagation();
  });
  addEventListener('resize', () => { if (!list.hidden) position(); });

  return {
    focus() { input.focus(); input.select(); },
    setKind(kind) {
      if (pick) return;
      input.placeholder = T.searchPlaceholder[kind];
      input.setAttribute('aria-label', T.searchPlaceholder[kind]);
      if (input.value.trim() && document.activeElement === input) run();
    },
    /** Active (ou désactive avec null) le mode « Comparer avec… » : recherche limitée au même type. */
    setPick(p) {
      pick = p;
      const kind = p ? p.kind : getKind();
      const text = p ? T.comparePlaceholder[p.kind] : T.searchPlaceholder[kind];
      input.placeholder = text;
      input.setAttribute('aria-label', p ? `${text} (comparaison avec ${p.label})` : text);
      input.value = '';
      close();
    },
    isPicking: () => !!pick,
    close,
    reposition() { if (!list.hidden) position(); },
  };
}
