// app.js : point d'entrée de l'interface. Routage, raccourcis clavier, thèmes, menus, gestion des erreurs.

import { captureToken, api, reloadWithSession } from './api.js';
import { store } from './state.js';
import { fmt, T, L, LANG, tx, familyLabel } from './i18n.js';
import * as glass from './glass.js';
import { $, h, toast } from './ui/dom.js';
import { openMenu, closeMenu, isMenuOpen } from './ui/menu.js';
import { createSearch } from './ui/search.js';
import { createStatus } from './ui/status.js';
import { createResultView, viewName } from './ui/views.js';
import { computeChromeLayout, ROW_H } from './ui/chrome.js';
import { parseShareLink } from './ui/link.js';

const root = $('glass-root');
/** Types de recherche, dans l'ordre du sélecteur. */
const KINDS = ['user', 'device', 'group', 'object'];
const KIND_SHORT = { user: L('Utilisateur', 'User'), device: L('Machine', 'Device'), group: L('Groupe', 'Group'), object: L('Élément', 'Item') };
const NOT_FOUND = {
  user: L('Utilisateur introuvable.', 'User not found.'), device: L('Machine introuvable.', 'Device not found.'),
  group: L('Groupe introuvable.', 'Group not found.'), object: L('Élément introuvable.', 'Item not found.'),
};
const content = $('content');
// Search type: always "User" at startup (the selector then follows the page that is open).
let kind = 'user';
let lastStatus = null;
let fatal = false;

// ---------------------------------------------------------------- Thème

// Two themes: light (default) and dark. Toggle: "Dark mode" switch in the settings, or the T key.
// Saved by the server (prefs.json), which writes it into <html data-theme> at the next launch: no flash.
const THEME_LABEL = { light: L('Clair', 'Light'), dark: L('Sombre', 'Dark') };
const currentTheme = () => (document.documentElement.getAttribute('data-theme') === 'dark' ? 'dark' : 'light');
function applyTheme(t) {
  document.documentElement.setAttribute('data-theme', t === 'dark' ? 'dark' : 'light');
}
function setTheme(t) {
  applyTheme(t);
  api.setPrefs({ theme: t }).catch(() => { /* not saved: the theme still applies to this session */ });
  toast(L(`Thème : ${THEME_LABEL[t]}`, `Theme: ${THEME_LABEL[t]}`));
}
function toggleTheme() { setTheme(currentTheme() === 'dark' ? 'light' : 'dark'); }

// ---------------------------------------------------------------- Language

// English by default. Saved by the server, so the choice survives a full restart. Changing it reloads the page.
async function setLanguage(lang) {
  if (lang === LANG) return;
  try {
    await api.setPrefs({ lang });
    reloadWithSession();
  } catch (e) { handleError(e); }
}

/** Static page text: written in English in index.html; French from the data-fr* attributes. */
function applyStaticText() {
  if (LANG === 'fr') {
    for (const el of document.querySelectorAll('[data-fr]')) el.textContent = el.dataset.fr;
    for (const [attr, data] of [['placeholder', 'frPlaceholder'], ['title', 'frTitle'], ['aria-label', 'frAriaLabel']]) {
      for (const el of document.querySelectorAll(`[data-fr-${attr}]`)) el.setAttribute(attr, el.dataset[data]);
    }
  }
  document.documentElement.classList.add('i18n-ready');
}

// ---------------------------------------------------------------- Erreurs bloquantes

function showOverlay(which) {
  const e = T.errors[which];
  fatal = true;
  $('overlay-title').textContent = e.title;
  $('overlay-text').textContent = e.text;
  $('overlay-retry').hidden = which === 'session';
  $('overlay').hidden = false;
  if (which !== 'session') $('overlay-retry').focus();
}
function hideOverlay() {
  if (!fatal) return;
  fatal = false;
  $('overlay').hidden = true;
}
let stopped = false;
function handleError(e) {
  if (stopped) return;
  if (e?.kind === 'network') showOverlay('network');
  else if (e?.kind === 'session') showOverlay('session');
  else toast(e?.message || T.errors.generic);
}

// ---------------------------------------------------------------- Mise en page

/** Place un verre de la barre du haut (coordonnées relatives à la racine). */
function place(el, left, top, width) {
  el.style.left = `${Math.round(left)}px`;
  el.style.top = `${Math.round(top)}px`;
  if (width !== undefined) el.style.width = `${Math.round(width)}px`;
}

/**
 * Largeur naturelle de la pastille d'état pour un texte donné. Mesure le texte RÉEL dans le DOM
 * (scrollWidth du libellé, qui ignore la troncature) sans déplacer la pastille.
 * = marge gauche 16 + point 8 + espace 8 + texte + marge droite 16 + 4 de sécurité.
 */
function statusWidthFor(text) {
  const el = $('status-text');
  el.textContent = text;
  return Math.ceil(16 + 8 + 8 + el.scrollWidth + 16 + 4);
}

/** Bas du titre d'accueil, en coordonnées de la racine (sous les bandeaux éventuels). */
function heroBottom() {
  const hero = document.querySelector('.hero');
  if (!hero || $('home-view').hidden) return undefined;
  return hero.getBoundingClientRect().bottom - root.getBoundingClientRect().top;
}

/**
 * Placement de la barre du haut : mesure les éléments puis choisit, dans l'ordre,
 *  1. une ligne (texte d'état complet), 2. une ligne (texte d'état court), 3. deux lignes.
 * Garantit qu'aucun élément ne se chevauche, quelle que soit la largeur. Grille de 8 px.
 */
function layoutChrome() {
  const W = root.clientWidth;
  const H = root.clientHeight;
  const sp = $('search-pill');
  const seg = $('segmented');
  const st = $('status-pill');
  const act = $('actions');
  const txt = $('status-text');
  const full = txt.dataset.full || txt.textContent;
  const short = txt.dataset.short || full;
  const isResult = root.dataset.view === 'result';
  sp.classList.toggle('compact', isResult);
  seg.style.display = '';
  const L = computeChromeLayout({
    W, H, view: isResult ? 'result' : 'home',
    segW: seg.offsetWidth, actW: act.offsetWidth,
    fullW: statusWidthFor(full), shortW: statusWidthFor(short),
    searchH: sp.offsetHeight,
    heroBottom: isResult ? undefined : heroBottom(),
  });
  root.style.setProperty('--pad', `${L.pad}px`);
  txt.textContent = L.useFull ? full : short;
  place(sp, L.search.left, L.search.top, L.search.width);
  place(st, L.status.left, L.status.top, L.status.width);
  place(act, L.actions.left, L.actions.top);
  if (L.seg.hidden) seg.style.display = 'none';
  else place(seg, L.seg.left, L.seg.top);
  if (L.searchTop !== undefined) root.style.setProperty('--search-top', `${L.searchTop}px`);
  const chromeBottom = L.chromeBottom;
  root.style.setProperty('--chrome-bottom', `${chromeBottom + 16}px`);
  root.classList.add('laid-out');
  placeThumb();
  return chromeBottom;
}

function layout() {
  // Accueil : le haut du contenu est fixé AVANT de mesurer le titre (la recherche se place dessous).
  if (root.dataset.view !== 'result') {
    const pad = root.clientWidth >= 900 ? 24 : 16;
    root.style.setProperty('--content-top', `${pad + ROW_H + 16}px`);
  }
  const chromeBottom = layoutChrome();
  const hdr = $('result-header');
  const top = root.dataset.view === 'result' && !hdr.hidden
    ? chromeBottom + 16 + hdr.offsetHeight + 16
    : chromeBottom + 16;
  root.style.setProperty('--content-top', `${Math.round(top)}px`);
  // Largeur de la barre de défilement du contenu : l'en-tête s'aligne sur la zone de contenu réelle.
  root.style.setProperty('--sbw', `${content.offsetWidth - content.clientWidth}px`);
  // Le bord de défilement couvre la barre du haut (+ l'en-tête sur l'écran de résultat).
  root.style.setProperty('--edge-h', `${Math.round(top - 4)}px`);
  search.reposition();
  glass.markChanged();
}

function setView(v) {
  root.dataset.view = v;
  // Placement immédiat (aucune image intermédiaire avec les anciennes positions), puis recapture du
  // contenu une fois l'écran rendu.
  layout();
  setTimeout(() => { layout(); glass.recapture(content); }, 150);
}

// ---------------------------------------------------------------- Sélecteur segmenté

function placeThumb() {
  const sel = $('segmented').querySelector('[aria-selected="true"]');
  const seg = $('segmented');
  seg.style.setProperty('--thumb-x', `${sel.offsetLeft - 4}px`);
  seg.style.setProperty('--thumb-w', `${sel.offsetWidth}px`);
}
function setKind(k, { focus = false } = {}) {
  if (picking) return;          // type verrouillé pendant « Comparer avec… »
  kind = k;
  for (const b of $('segmented').querySelectorAll('[role="tab"]')) {
    const on = b.dataset.kind === k;
    b.setAttribute('aria-selected', String(on));
    b.tabIndex = on ? 0 : -1;
  }
  placeThumb();
  search.setKind(k);
  // Sur l'écran de résultat, seul l'onglet actif garde son libellé : la largeur change, on replace la barre.
  if (root.dataset.view === 'result') layout();
  glass.markChanged($('segmented'));
  if (focus) search.focus();
}

// ---------------------------------------------------------------- Accueil et récents

function renderRecent() {
  const list = store.recent();
  $('recent').hidden = list.length === 0;
  $('recent-list').replaceChildren(...list.map((r) => h('li', {}, [
    h('button', {
      type: 'button', class: 'chip', title: r.name,
      on: { click: () => navigate(r.kind, r.id) },
    }, [h('span', { class: 'chip-kind', text: KIND_SHORT[r.kind] || KIND_SHORT.object }), h('span', { class: 'chip-label', text: r.name })]),
  ])));
}

// ---------------------------------------------------------------- Comparaison

/** Choix en cours : { kind, id, name } — la recherche du haut propose uniquement le même type. */
let picking = null;

function startComparePick(k, id, name) {
  closeMenu({ restoreFocus: false });
  views.closePanel();
  picking = { kind: k, id, name };
  root.dataset.comparePick = k;
  $('compare-chip').hidden = false;
  search.setPick({ kind: k, excludeId: id, label: name });
  layout();
  search.focus();
  const what = {
    user: L("l'utilisateur", 'the user'), device: L('la machine', 'the device'),
    group: L('le groupe', 'the group'), object: L("l'élément", 'the item'),
  }[k];
  toast(L(`Choisissez ${what} à comparer (Échap pour annuler).`, `Choose ${what} to compare with (Esc to cancel).`));
}

function stopComparePick() {
  if (!picking) return;
  picking = null;
  delete root.dataset.comparePick;
  $('compare-chip').hidden = true;
  search.setPick(null);
  layout();
}

function openCompare(k, idA, idB) {
  const target = `#/compare/${k}/${encodeURIComponent(idA)}/${encodeURIComponent(idB)}`;
  if (location.hash === target) route(); else location.hash = target;
}

// ---------------------------------------------------------------- Routage (#/<type>/<id>, #/compare/<type>/<A>/<B>)

function navigate(k, id) {
  const target = `#/${k}/${encodeURIComponent(id)}`;
  if (location.hash === target) route(); else location.hash = target;
}
function goHome() {
  if (location.hash) history.pushState(null, '', location.pathname);
  route();
}

let routeSeq = 0;
async function route(opts = {}) {
  closeMenu({ restoreFocus: false });
  stopComparePick();
  const mine = ++routeSeq;
  const c = /^#\/compare\/(group|object|user|device)\/([^/]+)\/([^/]+)$/.exec(location.hash);
  if (c) return routeCompare(c[1], decodeURIComponent(c[2]), decodeURIComponent(c[3]), mine, opts);
  const m = /^#\/(group|object|user|device)\/(.+)$/.exec(location.hash);
  if (!m) {
    views.clear();
    $('result-view').hidden = true;
    $('home-view').hidden = false;
    document.title = T.appName;
    renderRecent();
    setView('home');
    return;
  }
  const [, k, rawId] = m;
  const id = decodeURIComponent(rawId);
  $('home-view').hidden = true;
  $('result-view').hidden = false;
  $('result-view').setAttribute('aria-busy', 'true');
  $('table-host').replaceChildren(...Array.from({ length: 6 }, () => h('div', { class: 'skeleton', 'aria-hidden': 'true' })));
  setView('result');
  try {
    const t0 = performance.now();
    const data = await api.get(k, id);
    if (mine !== routeSeq) return;
    // Le sélecteur suit le type de la fiche ouverte : la recherche du haut reste dans le même contexte.
    if (kind !== k) setKind(k);
    const show = { group: views.showGroup, object: views.showObject, user: views.showUser, device: views.showDevice }[k];
    show(data, lastStatus);
    const name = viewName(k, data);
    store.addRecent({ kind: k, id, name });
    document.title = `${name} · ${T.appName}`;
    $('result-view').dataset.loadMs = String(Math.round(performance.now() - t0));
    layout();
    if (!opts.silent) views.focusTable();
  } catch (e) {
    if (mine !== routeSeq) return;
    if (e.kind === 'http' && e.status === 404) {
      toast(NOT_FOUND[k]);
      goHome();
    } else {
      handleError(e);
    }
  } finally {
    if (mine === routeSeq) $('result-view').setAttribute('aria-busy', 'false');
  }
}

async function routeCompare(k, idA, idB, mine, opts) {
  $('home-view').hidden = true;
  $('result-view').hidden = false;
  $('result-view').setAttribute('aria-busy', 'true');
  $('table-host').replaceChildren(...Array.from({ length: 6 }, () => h('div', { class: 'skeleton', 'aria-hidden': 'true' })));
  setView('result');
  try {
    const [a, b] = await Promise.all([api.get(k, idA), api.get(k, idB)]);
    if (mine !== routeSeq) return;
    views.showCompare(k, a, b, lastStatus);
    document.title = `${viewName(k, a)} ⇄ ${viewName(k, b)} · ${T.appName}`;
    layout();
    if (!opts.silent) views.focusTable();
  } catch (e) {
    if (mine !== routeSeq) return;
    if (e.kind === 'http' && e.status === 404) {
      toast(L('Élément de la comparaison introuvable.', 'An item of the comparison was not found.'));
      goHome();
    } else {
      handleError(e);
    }
  } finally {
    if (mine === routeSeq) $('result-view').setAttribute('aria-busy', 'false');
  }
}

// ---------------------------------------------------------------- Actions

async function doRefresh(mode) {
  try {
    const r = await api.refresh(mode);
    toast(tx(r?.message) || (mode === 'full' ? L('Synchronisation complète lancée.', 'Full sync started.') : L('Synchronisation lancée.', 'Sync started.')));
    status.refreshNow();
  } catch (e) { handleError(e); }
}
async function doClearCache() {
  if (!confirm(L('Effacer le cache local ? Les données seront relues depuis Microsoft Graph au prochain démarrage.', 'Clear the local cache? Data will be read again from Microsoft Graph at the next start.'))) return;
  try { const r = await api.clearCache(); toast(tx(r?.message) || L('Cache local effacé.', 'Local cache cleared.')); } catch (e) { handleError(e); }
}
async function doShutdown() {
  if (!confirm(L("Arrêter l'outil ? Le serveur local s'arrête et la session Graph est fermée.", 'Stop the tool? The local server stops and the Graph session is closed.'))) return;
  try {
    await api.shutdown();
    stopped = true;
    fatal = true;
    $('overlay-title').textContent = L('Outil arrêté', 'Tool stopped');
    $('overlay-text').textContent = L('Le serveur local est arrêté. Vous pouvez fermer cet onglet.', 'The local server is stopped. You can close this tab.');
    $('overlay-retry').hidden = true;
    $('overlay').hidden = false;
  } catch (e) { handleError(e); }
}

function openStatusMenu() {
  const s = lastStatus || {};
  const items = [
    { type: 'label', label: L('Synchronisation', 'Sync') },
    { type: 'info', label: L(`État : ${T.phase[s.phase] || '—'}`, `Status: ${T.phase[s.phase] || '—'}`) },
    { type: 'info', label: L(`Dernière synchro : ${fmt.date(s.lastSyncAt)}`, `Last sync: ${fmt.date(s.lastSyncAt)}`) },
    { type: 'info', label: L(`Dernière synchro complète : ${fmt.date(s.lastFullSyncAt)}`, `Last full sync: ${fmt.date(s.lastFullSyncAt)}`) },
  ];
  const st = s.lastSyncStats;
  if (st) {
    items.push({ type: 'info', label: L(
      `Dernière synchro ${st.mode === 'full' ? 'complète' : 'incrémentale'} : ${fmt.num(st.durationSec)} s, ${fmt.plural(st.requests, 'requête', 'requêtes')}`,
      `Last ${st.mode === 'full' ? 'full' : 'incremental'} sync: ${fmt.num(st.durationSec)} s, ${fmt.plural(st.requests, 'request', 'requests')}`,
    ) });
    items.push({ type: 'info', label: L(
      `${fmt.plural(st.added, 'nouveau', 'nouveaux')} · ${fmt.plural(st.changed, 'modifié', 'modifiés')} · ${fmt.plural(st.deleted, 'supprimé', 'supprimés')} · ${fmt.plural(st.assignmentsRead, 'élément relu', 'éléments relus')}`,
      `${fmt.num(st.added)} new · ${fmt.num(st.changed)} changed · ${fmt.num(st.deleted)} deleted · ${fmt.plural(st.assignmentsRead, 'item re-read', 'items re-read')}`,
    ) });
  } else if (s.dataSource === 'cache') {
    items.push({ type: 'info', label: L('Données issues du cache local, synchronisation en attente.', 'Data from the local cache, sync pending.') });
  }
  items.push({ type: 'info', label: s.cacheEnabled
    ? (s.cacheSavedAt ? L(`Cache local : enregistré le ${fmt.date(s.cacheSavedAt)}`, `Local cache: saved ${fmt.date(s.cacheSavedAt)}`) : L('Cache local : pas encore enregistré', 'Local cache: not saved yet'))
    : L('Cache local désactivé (-NoDiskCache)', 'Local cache disabled (-NoDiskCache)') });
  if (s.foregroundSync) items.push({ type: 'info', label: L('Synchronisation au premier plan (repli) : l’interface ne répond pas pendant une synchro.', 'Foreground sync (fallback): the interface does not respond during a sync.') });
  if (s.mode === 'Mock') items.push({ type: 'info', label: L('Mode démo : données fictives', 'Demo mode: fictitious data') });
  items.push(
    { type: 'sep' },
    { label: L('Synchronisation incrémentale (R)', 'Incremental sync (R)'), onSelect: () => doRefresh('incremental') },
    { label: L('Synchronisation complète (Maj+R)', 'Full sync (Shift+R)'), onSelect: () => doRefresh('full') },
    { label: L('Effacer le cache local', 'Clear the local cache'), onSelect: doClearCache },
  );
  const unc = Array.isArray(s.uncovered) ? s.uncovered : [];
  if (unc.length) {
    items.push({ type: 'sep' }, { type: 'label', label: L('Non couvert (permission non consentie)', 'Not covered (permission not granted)') });
    for (const u of unc) items.push({ type: 'info', label: `${familyLabel(u.family)}${L(' : ', ': ')}${tx(u.reason)}` });
  }
  openMenu($('status-btn'), items, L('Synchronisation', 'Sync'));
}

/** État du tenant affiché dans les réglages : libellé + coche bleue quand tout est à jour. */
function tenantState(s) {
  const busy = s.syncRunning || !['done', 'idle', 'error'].includes(s.phase);
  const p = s.progress || {};
  const pc = p.total > 0 ? Math.min(100, Math.floor((p.done / p.total) * 100)) : null;
  if (s.phase === 'error' || s.error) return { label: L('Échec de la synchronisation', 'Sync failed'), ok: false };
  if (busy) return { label: pc === null ? L('Synchronisation en cours…', 'Sync in progress…') : L(`Synchronisation en cours (${pc} %)`, `Sync in progress (${pc}%)`), ok: false };
  if (!s.ready) return { label: L('En attente de données', 'Waiting for data'), ok: false };
  return { label: L('Tenant synchronisé', 'Tenant synced'), ok: true };
}

function openSettingsMenu() {
  const s = lastStatus || {};
  const ts = tenantState(s);
  const items = [
    { type: 'label', label: 'Tenant' },   // same word in both languages
    { type: 'state', label: ts.label, checked: ts.ok },
    { type: 'info', label: s.mode === 'Mock' ? L('Mode démo : données fictives', 'Demo mode: fictitious data') : L(`ID du tenant : ${s.tenantId || '—'}`, `Tenant ID: ${s.tenantId || '—'}`) },
    { type: 'info', label: L(`Dernière synchro : ${fmt.date(s.lastSyncAt)}`, `Last sync: ${fmt.date(s.lastSyncAt)}`) },
    { type: 'sep' },
    { type: 'toggle', label: L('Mode sombre (T)', 'Dark mode (T)'), checked: currentTheme() === 'dark', onSelect: toggleTheme },
    { type: 'sep' },
    { type: 'label', label: L('Langue', 'Language') },
    { label: 'English', checked: LANG === 'en', onSelect: () => setLanguage('en') },
    { label: 'Français', checked: LANG === 'fr', onSelect: () => setLanguage('fr') },
    { type: 'sep' },
    { label: L('Effacer les recherches récentes', 'Clear recent searches'), onSelect: () => { store.clearRecent(); renderRecent(); toast(L('Recherches récentes effacées.', 'Recent searches cleared.')); } },
    { label: L("Arrêter l'outil", 'Stop the tool'), danger: true, onSelect: doShutdown },
  ];
  openMenu($('btn-settings'), items, L('Réglages', 'Settings'));
}

// ---------------------------------------------------------------- Clavier

function isTyping(el) {
  return el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT' || el.isContentEditable);
}

document.addEventListener('keydown', (e) => {
  if (fatal || e.ctrlKey || e.altKey || e.metaKey) return;
  const typing = isTyping(document.activeElement);
  if (e.key === 'Escape') {
    if (isMenuOpen()) { closeMenu(); e.preventDefault(); return; }
    if (picking) { stopComparePick(); e.preventDefault(); return; }
    if (views.closePanel()) { e.preventDefault(); return; }
    if (!typing && root.dataset.view === 'result') { goHome(); search.focus(); e.preventDefault(); }
    return;
  }
  if (typing) return;
  const k = e.key;
  if (k === '/') { e.preventDefault(); search.focus(); }
  else if (k === 'u' || k === 'U') { e.preventDefault(); setKind('user', { focus: true }); }
  else if (k === 'm' || k === 'M') { e.preventDefault(); setKind('device', { focus: true }); }
  else if (k === 'g' || k === 'G') { e.preventDefault(); setKind('group', { focus: true }); }
  else if (k === 'c' || k === 'C') { e.preventDefault(); setKind('object', { focus: true }); }
  else if (k === 'R' && e.shiftKey) { e.preventDefault(); doRefresh('full'); }
  else if (k === 'r') { e.preventDefault(); doRefresh('incremental'); }
  else if (k === 't' || k === 'T') { e.preventDefault(); toggleTheme(); }
});

// ---------------------------------------------------------------- Démarrage

applyStaticText();

const search = createSearch({
  getKind: () => kind,
  onOpen: (r) => {
    if (picking) { const p = picking; stopComparePick(); openCompare(p.kind, p.id, r.id); }
    else navigate(r.kind, r.id);
  },
  onCancelPick: () => { stopComparePick(); toast(L('Comparaison annulée.', 'Comparison cancelled.')); },
  onError: handleError,
});

const views = createResultView({
  scroller: content,
  onOpenGroup: (id) => navigate('group', id),
  onOpenObject: (id) => navigate('object', id),
  onOpenUser: (id) => navigate('user', id),
  onOpenDevice: (id) => navigate('device', id),
  onCompare: (k, id, name) => startComparePick(k, id, name),
  onCloseCompare: (k, idA) => navigate(k, idA),
  onSwapCompare: (k, idA, idB) => openCompare(k, idB, idA),
});

const status = createStatus({
  onStatus(s) {
    const updated = lastStatus && lastStatus.lastSyncAt && s.lastSyncAt && s.lastSyncAt !== lastStatus.lastSyncAt;
    lastStatus = s;
    if (updated) {
      const st = s.lastSyncStats;
      toast(st
        ? L(`Données mises à jour : ${fmt.plural(st.added, 'nouveau', 'nouveaux')}, ${fmt.plural(st.changed, 'modifié', 'modifiés')}, ${fmt.plural(st.deleted, 'supprimé', 'supprimés')}.`,
          `Data updated: ${fmt.num(st.added)} new, ${fmt.num(st.changed)} changed, ${fmt.num(st.deleted)} deleted.`)
        : L('Données mises à jour.', 'Data updated.'));
      if (root.dataset.view === 'result' && !views.hasPanel()) route({ silent: true });   // réaffiche l'écran courant avec les nouvelles données
    }
    hideOverlay();
    $('mock-banner').hidden = s.mode !== 'Mock';
    const stale = s.lastSyncAt && Date.now() - new Date(s.lastSyncAt).getTime() > 24 * 3600 * 1000;
    $('stale-banner').hidden = !stale;
    if (stale) $('stale-banner').textContent = L(`${fmt.dataAge(s.lastSyncAt)} : données de plus de 24 h. Une synchronisation est recommandée.`, `${fmt.dataAge(s.lastSyncAt)}: data older than 24 h. A sync is recommended.`);
    layout();   // le texte de la pastille a pu changer de longueur : on replace la barre du haut
  },
  onError: handleError,
});

$('segmented').addEventListener('click', (e) => {
  const b = e.target.closest('[role="tab"]');
  if (b) setKind(b.dataset.kind, { focus: true });
});
$('segmented').addEventListener('keydown', (e) => {
  if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return;
  e.preventDefault();
  const i = KINDS.indexOf(kind);
  setKind(KINDS[(i + (e.key === 'ArrowRight' ? 1 : KINDS.length - 1)) % KINDS.length]);
  $('segmented').querySelector('[aria-selected="true"]').focus();
});
$('status-btn').addEventListener('click', openStatusMenu);
$('btn-settings').addEventListener('click', openSettingsMenu);
$('btn-home').addEventListener('click', () => { closeMenu({ restoreFocus: false }); goHome(); search.focus(); });
$('btn-refresh').addEventListener('click', () => doRefresh('incremental'));
$('recent-clear').addEventListener('click', () => { store.clearRecent(); renderRecent(); });
$('overlay-retry').addEventListener('click', () => status.refreshNow());
content.addEventListener('scroll', () => glass.onContentScroll(content), { passive: true });
// Lien de partage collé (Ctrl+V), dans la recherche ou n'importe où : ouvre directement la fiche.
document.addEventListener('paste', (e) => {
  if (fatal) return;
  const link = parseShareLink(e.clipboardData?.getData('text/plain'));
  if (!link) return;
  e.preventDefault();
  closeMenu({ restoreFocus: false });
  document.activeElement?.blur?.();   // ferme les suggestions ; le sélecteur suit le type de la fiche (route)
  navigate(link.kind, link.id);
});
addEventListener('hashchange', route);
addEventListener('popstate', route);
let resizeT = 0;
addEventListener('resize', () => { cancelAnimationFrame(resizeT); resizeT = requestAnimationFrame(layout); });
new ResizeObserver(layout).observe($('result-header'));

const hasToken = captureToken();
setKind(kind);
route();
glass.init({ root });
if (!hasToken) showOverlay('session');
else status.start();
