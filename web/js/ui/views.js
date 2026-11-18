// views.js : écrans de résultat (Groupe, Élément, Utilisateur, Machine, Comparaison) et panneau latéral de détail.

import { $, h, icon, copyText, downloadText, toast } from './dom.js';
import { VTable } from './vtable.js';
import { shareLink } from './link.js';
import {
  asArray, buildGroupRows, buildObjectRows, familyCounts, groupExport, objectExport,
  statusText, toCsv, toTsv, safeFileName,
} from './model.js';
import { fmt, typeLabel, T } from '../i18n.fr.js';
import {
  compareGroups, compareObjects, compareProfiles, compareCounts, buildCompareRows, compareExport, GAP_LABEL, sideDetail,
} from './compare.js';
import {
  buildConfigRows, buildGroupListRows, buildDeviceRows, configExport, groupListExport, deviceExport,
  pageList, profileDevices, complianceLabel, targetsText,
} from './profile.js';
import { markChanged, recapture } from '../glass.js';

function badge(modeKey) {
  const map = {
    include: ['badge-include', 'check'],
    member: ['badge-include', 'check'],
    exclude: ['badge-exclude', 'ban'],
    potential: ['badge-neutral', 'info'],
  };
  const [cls, ic] = map[modeKey] || map.include;
  return h('span', { class: `badge ${cls}` }, [icon(ic), statusText(modeKey)]);
}

function copyBtn(value, label = 'Copier') {
  return h('button', {
    type: 'button', class: 'copy-btn', 'aria-label': `${label} l'identifiant`,
    on: { click: (e) => { e.stopPropagation(); copyText(value, 'Identifiant copié'); } },
  }, [label]);
}

const deviceIcon = (platform) => (platform === 'iOS' || platform === 'Android' ? 'phone' : 'laptop');

/** Pastille d'appareil : icône, nom ; estompée si inactif, barrée d'un cercle si exclu. */
function devicePill(t) {
  const cls = `dev-pill${t.mode === 'exclude' ? ' is-excluded' : ''}${t.stale ? ' is-stale' : ''}`;
  const title = `${t.deviceName}${t.mode === 'exclude' ? ' : exclu' : ''}${t.stale ? ' (inactif)' : ''}`;
  return h('span', { class: cls, title }, [icon(t.mode === 'exclude' ? 'ban' : deviceIcon(t.platform)), h('span', { class: 'dev-name', text: t.deviceName })]);
}
function devicePills(r) {
  if (r.allDevices && r.targets.length > 1) return h('span', { class: 'dev-pills' }, [h('span', { class: 'dev-pill is-all' }, [icon('laptop'), h('span', { class: 'dev-name', text: 'Tous ses appareils' })])]);
  const named = r.targets.filter((t) => t.deviceName);
  if (!named.length) return h('span', { class: 'muted', text: 'Sans appareil' });
  return h('span', { class: 'dev-pills' }, named.map(devicePill));
}

const GROUP_COLUMNS = [
  { key: 'name', label: 'Nom', width: 'minmax(200px, 2.4fr)', render: (r) => h('span', {}, [r.name, r.platform ? h('span', { class: 'sub', text: r.platform }) : null]) },
  { key: 'type', label: 'Type', width: 'minmax(110px, 1.3fr)', render: (r) => r.typeLabel },
  { key: 'status', label: 'Statut', width: '112px', render: (r) => badge(r.modeKey) },
  { key: 'via', label: 'Via', width: 'minmax(110px, 1fr)', render: (r) => r.viaText },
  { key: 'intent', label: 'Intent', width: 'minmax(80px, 0.9fr)', render: (r) => r.intentText || '—' },
  { key: 'filter', label: 'Filtre', width: 'minmax(110px, 1.3fr)', render: (r) => r.filterText || '—' },
];

const OBJECT_COLUMNS = [
  {
    key: 'name', label: 'Cible', width: 'minmax(220px, 2.6fr)',
    render: (r) => h('span', {}, [
      r.name,
      r.kind === 'group' && !r.groupExists ? h('span', { class: 'sub tag-deleted', text: 'Groupe supprimé dans Entra' }) : null,
      r.kind === 'group' && r.groupExists ? h('span', { class: 'sub mono', text: r.groupId }) : null,
    ]),
  },
  { key: 'status', label: 'Statut', width: '112px', render: (r) => badge(r.modeKey) },
  { key: 'via', label: 'Via', width: 'minmax(120px, 1fr)', render: (r) => r.viaText },
  { key: 'intent', label: 'Intent', width: 'minmax(90px, 0.9fr)', render: (r) => r.intentText || '—' },
  { key: 'filter', label: 'Filtre', width: 'minmax(120px, 1.3fr)', render: (r) => r.filterText || '—' },
];

/** Fiche Utilisateur (withDevices) ou Machine : éléments ciblés. */
function configColumns(withDevices) {
  return [
    { key: 'name', label: 'Nom', width: 'minmax(200px, 2.2fr)', render: (r) => h('span', {}, [r.name, h('span', { class: 'sub', text: [r.typeLabel, r.platform].filter(Boolean).join(' · ') })]) },
    { key: 'status', label: 'Statut', width: '112px', render: (r) => badge(r.modeKey) },
    withDevices
      ? { key: 'devices', label: 'Appareils', width: 'minmax(150px, 1.5fr)', render: devicePills }
      : { key: 'scope', label: 'Ciblage', width: 'minmax(110px, 1fr)', render: (r) => r.scopeText },
    { key: 'via', label: 'Via', width: 'minmax(150px, 1.6fr)', render: (r) => r.viaText || '—' },
    { key: 'detail', label: 'Détail', width: 'minmax(100px, 1fr)', render: (r) => [r.intentText, r.filterText ? `Filtre : ${r.filterText}` : ''].filter(Boolean).join(' · ') || '—' },
  ];
}
const GROUP_LIST_COLUMNS = [
  { key: 'name', label: 'Groupe', width: 'minmax(220px, 2.6fr)', render: (r) => h('span', {}, [r.name, h('span', { class: 'sub mono', text: r.groupId })]) },
  { key: 'used', label: 'Dans Intune', width: 'minmax(150px, 1fr)', render: (r) => (r.used ? h('span', { class: 'badge badge-include' }, [r.usedText]) : h('span', { class: 'muted', text: r.usedText })) },
];
const DEVICE_COLUMNS = [
  { key: 'name', label: 'Appareil', width: 'minmax(180px, 1.8fr)', render: (r) => h('span', {}, [r.name, h('span', { class: 'sub', text: r.modelText || r.raw.serial || '' })]) },
  { key: 'os', label: 'Système', width: 'minmax(120px, 1.2fr)', render: (r) => r.osText || '—' },
  { key: 'sync', label: 'Dernière synchro', width: 'minmax(140px, 1.1fr)', render: (r) => h('span', { class: 'dev-sync' }, [r.syncText, r.stale ? h('span', { class: 'badge badge-neutral', text: 'Inactif' }) : null]) },
  { key: 'compliance', label: 'Conformité', width: 'minmax(110px, 1fr)', render: (r) => r.complianceText },
];

/** Cellule d'un côté de la comparaison : statut + détail (intent, filtre), ou « Absent ». */
function sideCell(sd) {
  if (!sd) return h('span', { class: 'cmp-absent', text: 'Absent' });
  const detail = sideDetail(sd);
  return h('span', { class: 'cmp-cell' }, [badge(sd.mode), detail ? h('span', { class: 'sub', text: detail }) : null]);
}
function gapBadge(gap) {
  return h('span', { class: `badge gap-badge gap-${gap}` }, [GAP_LABEL[gap]]);
}
function compareColumns(nameA, nameB) {
  return [
    { key: 'name', label: 'Nom', width: 'minmax(180px, 2fr)', render: (r) => h('span', {}, [r.name, h('span', { class: 'sub', text: [r.typeLabel, r.platform].filter(Boolean).join(' · ') })]) },
    { key: 'side-a', label: `A · ${nameA}`, width: 'minmax(132px, 1.2fr)', render: (r) => sideCell(r.a) },
    { key: 'side-b', label: `B · ${nameB}`, width: 'minmax(132px, 1.2fr)', render: (r) => sideCell(r.b) },
    { key: 'gap', label: 'Écart', width: '112px', render: (r) => gapBadge(r.gap) },
  ];
}

/** Nom, identifiant, nombre d'éléments et libellés d'une fiche, quel que soit son type. */
function describe(kind, view) {
  switch (kind) {
    case 'group': return { id: view.group.id, name: view.group.name, count: asArray(view.items).length, kicker: 'Groupe Entra', unit: ['élément assigné', 'éléments assignés'], what: 'ces deux groupes' };
    case 'object': return { id: view.object.id, name: view.object.name, count: asArray(view.assignments).length, kicker: view.object.family || 'Configuration', unit: ['cible', 'cibles'], what: 'ces deux éléments' };
    case 'user': return { id: view.user.id, name: view.user.name, count: asArray(view.configs).length, kicker: 'Utilisateur', unit: ['élément ciblé', 'éléments ciblés'], what: 'ces deux utilisateurs' };
    default: return { id: view.device.id, name: view.device.name, count: asArray(view.configs).length, kicker: 'Machine', unit: ['élément ciblé', 'éléments ciblés'], what: 'ces deux machines' };
  }
}
export function viewName(kind, view) { return describe(kind, view).name; }

const isProfile = (k) => k === 'user' || k === 'device';

export function createResultView({ scroller, onOpenGroup, onOpenObject, onOpenUser, onOpenDevice, onCompare, onCloseCompare, onSwapCompare }) {
  let table = null;
  // { kind: 'group'|'object'|'user'|'device'|'compare', view, title, tab?, page? } ; comparaison : { cmpKind, a, b, cmp }
  let ctx = null;
  let visible = [];
  const filters = { text: '', mode: '', via: '', device: '', show: 'all', families: new Set(), collapsed: new Set(['global']) };
  let lastFocus = null;

  const elText = $('filter-text');
  const elMode = $('filter-mode');
  const elVia = $('filter-via');
  const elDevice = $('filter-device');

  function resetFilters() {
    filters.text = ''; filters.mode = ''; filters.via = ''; filters.device = ''; filters.show = 'all';
    filters.families = new Set();
    filters.collapsed = new Set(['global']);
    elText.value = ''; elMode.value = ''; elVia.value = ''; elDevice.value = '';
  }

  /** Commandes visibles de la barre d'outils selon l'écran. */
  function setToolbar({ mode = false, via = false, device = false } = {}) {
    $('filter-mode-wrap').hidden = !mode;
    $('filter-via-wrap').hidden = !via;
    $('filter-device-wrap').hidden = !device;
  }

  function ensureTable(columns, label, extra = {}) {
    table?.destroy();
    table = new VTable({
      host: $('table-host'), scroller, columns, label, ...extra,
      onActivate: (row) => openPanel(row),
      onToggle: (row) => {
        if (filters.collapsed.has(row.key)) filters.collapsed.delete(row.key); else filters.collapsed.add(row.key);
        refresh({ keepFocus: true });
      },
    });
  }

  function showEmpty(title, text, button) {
    const empty = $('empty');
    empty.replaceChildren(h('h3', { text: title }), text ? h('p', { text }) : null, button || null);
    empty.hidden = false;
  }
  const resetButton = () => h('button', { type: 'button', class: 'btn', text: 'Réinitialiser les filtres', on: { click: () => { resetFilters(); refresh(); } } });

  function refreshProfile(keepFocus) {
    const v = ctx.view;
    let rows;
    let pager = null;
    if (ctx.tab === 'groups') {
      const r = buildGroupListRows(v, { text: filters.text, page: ctx.page });
      ctx.page = r.page;
      rows = r.rows; visible = r.visible;
      pager = r.pages > 1 ? r : null;
    } else if (ctx.tab === 'devices') {
      ({ rows, visible } = buildDeviceRows(v, { text: filters.text }));
    } else {
      ({ rows, visible } = buildConfigRows(v, filters));
    }
    table.setRows(rows, { keepFocus });
    renderPager(pager);
    renderSummary();
    $('empty').hidden = true;
    const filtered = filters.text || filters.mode || filters.device;
    if (rows.length === 0 && filtered) showEmpty('Aucun résultat avec ces filtres', '', resetButton());
    else if (rows.length === 0 && ctx.tab === 'groups') showEmpty('Aucun groupe', asArray(v.warnings).length ? 'Les groupes n\'ont pas pu être lus (voir ci-dessus).' : 'Membre d\'aucun groupe Entra.');
    else if (rows.length === 0 && ctx.tab === 'devices') showEmpty('Aucun appareil', 'Aucun appareil géré par Intune pour cet utilisateur.');
    else if (rows.length === 0) showEmpty('Aucun élément ciblé', 'Aucune configuration, application ou stratégie ne cible ' + (ctx.kind === 'user' ? 'cet utilisateur ni ses appareils.' : 'cette machine ni son utilisateur.'));
  }

  function refresh({ keepFocus = false } = {}) {
    if (!ctx) return;
    if (isProfile(ctx.kind)) { refreshProfile(keepFocus); recapture(scroller); return; }
    let rows;
    if (ctx.kind === 'compare') ({ rows, visible } = buildCompareRows(ctx.cmp, filters));
    else if (ctx.kind === 'group') ({ rows, visible } = buildGroupRows(ctx.view, filters));
    else ({ rows, visible } = buildObjectRows(ctx.view, filters));
    table.setRows(rows, { keepFocus });
    renderPager(null);
    renderSummary();
    $('empty').hidden = true;
    const filtered = filters.text || filters.mode || filters.via || filters.families.size;
    if (ctx.kind === 'compare' && ctx.cmp.length === 0) {
      showEmpty('Rien à comparer', `Aucune assignation pour ${ctx.what}.`);
    } else if (ctx.kind === 'compare' && filters.show === 'gaps' && rows.length === 0 && !filters.text) {
      showEmpty('Aucun écart', `${ctx.what.charAt(0).toUpperCase()}${ctx.what.slice(1)} ont exactement les mêmes assignations.`);
    } else if (ctx.kind === 'group' && asArray(ctx.view.items).length === 0 && !filtered) {
      showEmpty('Aucune assignation directe', "Aucune configuration, application ou stratégie n'est assignée directement à ce groupe. Les assignations globales (indicatives) restent listées ci-dessous.");
    } else if (ctx.kind === 'object' && ctx.view.unassigned) {
      showEmpty('Aucune assignation', "Cet élément n'est assigné à aucun groupe ni à aucune cible globale (orphelin potentiel).");
    } else if (rows.length === 0) {
      showEmpty('Aucun résultat avec ces filtres', '', resetButton());
    }
    recapture(scroller);   // le contenu derrière les verres a changé
  }

  // ---------- Pagination (onglet Groupes) ----------

  function goPage(p) {
    ctx.page = p;
    refresh();
    const top = $('table-host').getBoundingClientRect().top - scroller.getBoundingClientRect().top + scroller.scrollTop;
    const pad = parseInt(getComputedStyle(scroller).scrollPaddingTop, 10) || 0;
    if (scroller.scrollTop > top - pad) scroller.scrollTop = Math.max(0, top - pad);
    table?.focusFirst();
  }

  function renderPager(p) {
    const nav = $('pager');
    if (!p) { nav.hidden = true; nav.replaceChildren(); return; }
    const btn = (label, page, attrs = {}) => h('button', {
      type: 'button', class: 'pager-btn', ...attrs,
      on: { click: () => goPage(page) },
    }, [label]);
    const first = (p.page - 1) * 20 + 1;
    const last = Math.min(p.total, p.page * 20);
    nav.replaceChildren(
      btn(icon('chevronLeft'), p.page - 1, { 'aria-label': 'Page précédente', disabled: p.page <= 1 }),
      ...pageList(p.page, p.pages).map((n) => (n === null
        ? h('span', { class: 'pager-gap', 'aria-hidden': 'true', text: '…' })
        : btn(String(n), n, { 'aria-label': `Page ${n}`, 'aria-current': n === p.page ? 'page' : null }))),
      btn(icon('chevronRight'), p.page + 1, { 'aria-label': 'Page suivante', disabled: p.page >= p.pages }),
      h('span', { class: 'pager-info', text: `${fmt.num(first)}–${fmt.num(last)} sur ${fmt.num(p.total)}` }),
    );
    nav.hidden = false;
  }

  // ---------- Synthèse (pastilles) ----------

  function renderSummary() {
    const box = $('summary');
    const chip = (pressed, label, count, onClick, title) => h('button', {
      type: 'button', class: 'chip', 'aria-pressed': String(pressed), title,
      on: { click: onClick },
    }, [h('span', { class: 'chip-label', text: label }), h('span', { class: 'chip-count', text: fmt.num(count) })]);
    if (ctx.kind === 'compare') {
      // Filtre à choix unique, sous forme de pastilles (même style que le bandeau par famille).
      const c = compareCounts(ctx.cmp);
      const defs = [['all', 'Tous'], ['gaps', 'Écarts'], ['onlyA', 'Seulement A'], ['onlyB', 'Seulement B'], ['diff', 'Différents'], ['same', 'Identiques']];
      box.replaceChildren(...defs.map(([k, l]) => chip(filters.show === k, l, c[k], () => { filters.show = k; refresh(); })));
      return;
    }
    if (isProfile(ctx.kind)) {
      // Onglets de la fiche : Configurations · Groupes · Appareils
      const v = ctx.view;
      const tabs = [['configs', 'Configurations', asArray(v.configs).length], ['groups', 'Groupes', asArray(v.groups).length]];
      if (ctx.kind === 'user') tabs.push(['devices', 'Appareils', asArray(v.devices).length]);
      box.replaceChildren(...tabs.map(([k, l, n]) => chip(ctx.tab === k, l, n, () => setTab(k))));
      return;
    }
    if (ctx.kind !== 'group') { box.replaceChildren(); return; }
    box.replaceChildren(...familyCounts(ctx.view).map(([fam, n]) => chip(filters.families.has(fam), fam, n, () => {
      if (filters.families.has(fam)) filters.families.delete(fam); else filters.families.add(fam);
      refresh();
    }, `Filtrer : ${fam}`)));
  }

  function renderNotes(status) {
    const notes = [];
    const unc = asArray(status?.uncovered);
    if (unc.length) {
      notes.push(h('div', { class: 'notes-box surface', role: 'note' }, [
        h('strong', { text: 'Non couvert (permission non consentie) : ' }),
        unc.map((u) => u.family).join(', '),
        '. Les assignations de ces types n\'apparaissent pas ici.',
      ]));
    }
    if (ctx.kind === 'group' && ctx.view.group && ctx.view.group.exists === false) {
      notes.push(h('div', { class: 'notes-box surface', role: 'note' }, [
        h('strong', { text: 'Groupe supprimé dans Entra. ' }),
        'Il est encore référencé par des assignations : elles ne s\'appliquent plus à personne.',
      ]));
    }
    if (isProfile(ctx.kind)) {
      const w = asArray(ctx.view.warnings);
      if (w.length) notes.push(h('div', { class: 'notes-box surface', role: 'note' }, [h('strong', { text: 'Données partielles : ' }), w.join(' · ')]));
      notes.push(h('div', { class: 'notes-box surface', role: 'note' }, [T.targetingNote]));
    }
    $('notes').replaceChildren(...notes);
  }

  function header({ kicker, title, meta, total, totalLabel, actions }) {
    const hd = $('result-header');
    hd.classList.remove('is-compare');
    hd.replaceChildren(
      h('div', { class: 'hdr-main' }, [
        h('div', { class: 'hdr-kicker' }, kicker),
        h('h1', { class: 'hdr-title', id: 'result-title', text: title, title }),
        h('div', { class: 'hdr-meta' }, meta),
      ]),
      h('div', { class: 'hdr-total', 'aria-label': `${fmt.num(total)} ${totalLabel}` }, [
        h('div', { class: 'big', text: fmt.num(total) }),
        h('div', { class: 'lbl', text: totalLabel }),
      ]),
      actions ? h('div', { class: 'hdr-actions' }, actions) : null,
    );
    hd.hidden = false;
    $('result-view').setAttribute('aria-labelledby', 'result-title');
  }

  function linkButton(kind, id) {
    return h('button', {
      type: 'button', class: 'btn', text: 'Copier le lien',
      title: 'Lien à envoyer à un collègue : il le colle (Ctrl+V) dans son Intune Lens pour ouvrir cette fiche',
      on: { click: () => copyText(shareLink(kind, id), 'Lien copié : à coller (Ctrl+V) dans Intune Lens pour ouvrir cette fiche.') },
    });
  }

  function compareButton(kind, id, name) {
    const titles = {
      group: 'Comparer ce groupe avec un autre groupe', object: 'Comparer avec une autre configuration',
      user: 'Comparer avec un autre utilisateur', device: 'Comparer avec une autre machine',
    };
    return h('button', {
      type: 'button', class: 'btn btn-primary', text: 'Comparer', title: titles[kind],
      on: { click: () => onCompare?.(kind, id, name) },
    });
  }

  function showGroup(view, status) {
    closePanel();
    resetFilters();
    ctx = { kind: 'group', view, title: view.group.name };
    setToolbar({ mode: true, via: true });
    header({
      kicker: 'Groupe Entra',
      title: view.group.name,
      meta: [
        h('span', { class: 'mono', text: view.group.id }), copyBtn(view.group.id),
        view.group.exists === false ? h('span', { class: 'tag-deleted', text: 'Supprimé dans Entra' }) : null,
      ],
      total: view.total,
      totalLabel: view.total > 1 ? 'éléments assignés' : 'élément assigné',
      actions: [linkButton('group', view.group.id), compareButton('group', view.group.id, view.group.name)],
    });
    ensureTable(GROUP_COLUMNS, `Éléments assignés au groupe ${view.group.name}`);
    renderNotes(status);
    refresh();
  }

  function showObject(view, status) {
    closePanel();
    resetFilters();
    filters.collapsed = new Set();
    const o = view.object;
    ctx = { kind: 'object', view, title: o.name };
    setToolbar({ mode: true });
    const n = asArray(view.assignments).length;
    header({
      kicker: o.family,
      title: o.name,
      meta: [
        o.platform ? h('span', { text: o.platform }) : null,
        h('span', { text: typeLabel(o.odataType) }),
        h('span', { text: `Modifié le ${fmt.date(o.lastModified)}` }),
        h('span', { class: 'mono', text: o.id }), copyBtn(o.id),
      ],
      total: n,
      totalLabel: n > 1 ? 'cibles' : 'cible',
      actions: [linkButton('object', o.id), compareButton('object', o.id, o.name)],
    });
    ensureTable(OBJECT_COLUMNS, `Cibles de ${o.name}`);
    renderNotes(status);
    refresh();
  }

  // ---------- Fiches Utilisateur / Machine ----------

  function setTab(tab) {
    if (!ctx || !isProfile(ctx.kind)) return;
    ctx.tab = tab;
    ctx.page = 1;
    filters.text = ''; elText.value = '';
    const v = ctx.view;
    const name = describe(ctx.kind, v).name;
    if (tab === 'groups') {
      setToolbar({});
      ensureTable(GROUP_LIST_COLUMNS, `Groupes Entra de ${name}`);
    } else if (tab === 'devices') {
      setToolbar({});
      ensureTable(DEVICE_COLUMNS, `Appareils de ${name}`);
    } else {
      setToolbar({ mode: true, device: ctx.kind === 'user' && asArray(v.devices).length > 1 });
      ensureTable(configColumns(ctx.kind === 'user'), `Éléments ciblant ${name}`, {
        className: `vt-profile vt-profile-${ctx.kind}`,
        rowClass: (r) => (r.targets.every((t) => t.stale) ? 'is-stale' : ''),
      });
    }
    refresh();
  }

  function fillDeviceFilter(view) {
    const devs = asArray(view.devices);
    elDevice.replaceChildren(
      h('option', { value: '', text: 'Tous' }),
      ...devs.map((d) => h('option', { value: d.id, text: `${d.name}${d.stale ? ' (inactif)' : ''}` })),
    );
    elDevice.value = '';
  }

  function showUser(view, status) {
    closePanel();
    resetFilters();
    filters.collapsed = new Set();
    const u = view.user;
    const devs = asArray(view.devices);
    const stale = devs.filter((d) => d.stale).length;
    ctx = { kind: 'user', view, title: u.name, tab: 'configs', page: 1 };
    fillDeviceFilter(view);
    const n = asArray(view.configs).length;
    header({
      kicker: 'Utilisateur',
      title: u.name,
      meta: [
        h('span', { class: 'mono', text: u.upn || u.id }), copyBtn(u.upn || u.id),
        h('span', { text: fmt.plural(devs.length, 'appareil', 'appareils') + (stale ? ` (dont ${fmt.plural(stale, 'inactif', 'inactifs')})` : '') }),
        h('span', { text: fmt.plural(asArray(view.groups).length, 'groupe', 'groupes') }),
      ],
      total: n,
      totalLabel: n > 1 ? 'éléments ciblés' : 'élément ciblé',
      actions: [linkButton('user', u.id), compareButton('user', u.id, u.name)],
    });
    renderNotes(status);
    setTab('configs');
  }

  function showDevice(view, status) {
    closePanel();
    resetFilters();
    filters.collapsed = new Set();
    const d = view.device;
    ctx = { kind: 'device', view, title: d.name, tab: 'configs', page: 1 };
    const n = asArray(view.configs).length;
    const days = fmt.daysSince(d.lastSync);
    header({
      kicker: ['Machine', d.stale ? h('span', { class: 'hdr-tag', text: `Inactive depuis ${fmt.num(days)} j` }) : null],
      title: d.name,
      meta: [
        h('span', { text: [d.os, d.osVersion].filter(Boolean).join(' ') || '—' }),
        d.model ? h('span', { text: [d.maker, d.model].filter(Boolean).join(' ') }) : null,
        h('span', { text: `Synchro ${fmt.ago(d.lastSync)}` }),
        h('span', { text: complianceLabel(d.compliance) }),
        view.user
          ? h('button', { type: 'button', class: 'btn-link hdr-user', title: `Ouvrir la fiche de ${view.user.name}`, on: { click: () => onOpenUser?.(view.user.id) } }, [icon('person'), view.user.name])
          : h('span', { class: 'muted', text: 'Sans utilisateur' }),
      ],
      total: n,
      totalLabel: n > 1 ? 'éléments ciblés' : 'élément ciblé',
      actions: [linkButton('device', d.id), compareButton('device', d.id, d.name)],
    });
    renderNotes(status);
    setTab('configs');
  }

  /** Écran de comparaison A | B (lignes alignées, écarts surlignés). */
  function showCompare(kind, viewA, viewB, status) {
    closePanel();
    resetFilters();
    filters.collapsed = new Set();
    const A = describe(kind, viewA);
    const B = describe(kind, viewB);
    const cmp = kind === 'group' ? compareGroups(viewA, viewB) : kind === 'object' ? compareObjects(viewA, viewB) : compareProfiles(viewA, viewB);
    ctx = { kind: 'compare', cmpKind: kind, a: { id: A.id, name: A.name }, b: { id: B.id, name: B.name }, cmp, title: `${A.name} vs ${B.name}`, what: A.what };
    setToolbar({});

    const sideBlock = (letter, d, titleId) => h('div', { class: 'cmp-side' }, [
      h('div', { class: 'hdr-kicker', text: `${letter} · ${d.kicker}` }),
      h('h1', { class: 'hdr-title', id: titleId, text: d.name, title: d.name }),
      h('div', { class: 'hdr-meta' }, [h('span', { class: 'num', text: fmt.plural(d.count, d.unit[0], d.unit[1]) })]),
    ]);
    const hd = $('result-header');
    hd.classList.add('is-compare');
    hd.replaceChildren(
      h('div', { class: 'cmp-hdr' }, [
        sideBlock('A', A, 'result-title'),
        h('button', {
          type: 'button', class: 'icon-btn cmp-swap', title: 'Inverser A et B', 'aria-label': 'Inverser A et B',
          on: { click: () => onSwapCompare?.(kind, A.id, B.id) },
        }, [icon('swap')]),
        sideBlock('B', B, 'result-title-b'),
      ]),
      h('div', { class: 'hdr-actions' }, [
        h('button', { type: 'button', class: 'btn', text: 'Fermer', title: `Revenir à ${A.name}`, on: { click: () => onCloseCompare?.(kind, A.id) } }),
      ]),
    );
    hd.hidden = false;
    $('result-view').setAttribute('aria-labelledby', 'result-title');

    ensureTable(compareColumns(A.name, B.name), `Comparaison de ${A.name} et ${B.name}`, {
      className: 'vt-compare', rowClass: (r) => `gap-${r.gap}`,
    });
    renderNotes(status);
    refresh();
  }

  function clear() {
    closePanel();
    table?.destroy();
    table = null;
    ctx = null;
    $('result-header').hidden = true;
    $('summary').replaceChildren();
    $('notes').replaceChildren();
    $('empty').hidden = true;
    renderPager(null);
  }

  // ---------- Panneau latéral ----------

  function kv(label, value) {
    if (value === null || value === undefined || value === '') return null;
    return [h('dt', { text: label }), h('dd', {}, [].concat(value))];
  }
  const primary = (text, onClick) => h('button', { type: 'button', class: 'btn btn-primary', text, on: { click: onClick } });

  function profilePanel(row, items, actions) {
    if (row.kind === 'group') {
      items.push(
        kv('Utilisation dans Intune', row.usedText),
        kv('Identifiant', [h('span', { class: 'mono', text: row.groupId }), copyBtn(row.groupId)]),
      );
      actions.push(primary('Ouvrir ce groupe', () => onOpenGroup(row.groupId)));
    } else if (row.kind === 'device') {
      const d = row.raw;
      items.push(
        kv('Système', row.osText),
        kv('Modèle', row.modelText),
        kv('N° de série', d.serial ? [h('span', { class: 'mono', text: d.serial }), copyBtn(d.serial)] : null),
        kv('Dernière synchro', `${fmt.date(d.lastSync)} (${fmt.ago(d.lastSync)})`),
        kv('État', d.stale ? [h('span', { class: 'badge badge-neutral', text: 'Inactif' }), ` : aucune synchro depuis plus de 30 jours`] : 'Actif'),
        kv('Conformité', row.complianceText),
      );
      actions.push(primary('Ouvrir la machine', () => onOpenDevice?.(row.deviceId)));
    } else {
      items.push(
        kv('Famille', row.family),
        kv('Type', row.typeLabel),
        kv('Statut', [badge(row.modeKey)]),
        ctx.kind === 'device' ? kv('Ciblage', row.scopeText) : null,
        kv('Via', row.viaText),
        kv('Intent', row.intentText),
        kv('Filtre', row.filter ? [`${row.filterText}`, h('span', { class: 'muted', text: 'Filtre non évalué : l\'application réelle en dépend.' })] : null),
        kv('Plateforme', row.platform),
      );
      if (ctx.kind === 'user') {
        const list = h('ul', { class: 'dev-list' }, row.targets.filter((t) => t.deviceName).map((t) => h('li', {}, [
          devicePill(t),
          h('span', { class: 'muted', text: t.mode === 'exclude' ? `Exclu par ${t.exclVia.join(', ')}` : t.via.join(', ') + (t.mixedExcl ? ` · exclusion non garantie : ${t.exclVia.join(', ')}` : '') }),
        ])));
        if (row.mixedExcl) items.push(kv('Exclusion', 'Groupe d\'utilisateurs et groupe d\'appareils mélangés entre inclusion et exclusion : Intune ne le prend pas en charge, l\'exclusion peut ne pas s\'appliquer.'));
        items.push(kv('Par appareil', row.targets.some((t) => t.deviceName) ? [list] : 'Utilisateur sans appareil : ciblage par l\'utilisateur seulement.'));
      }
      items.push(kv('Identifiant', [h('span', { class: 'mono', text: row.objectId }), copyBtn(row.objectId)]));
      actions.push(primary('Voir toutes les cibles de cet élément', () => onOpenObject(row.objectId)));
    }
  }

  function openPanel(row) {
    lastFocus = document.activeElement;
    const body = $('panel-body');
    const r = row.raw || {};
    const items = [];
    const actions = [];
    $('panel-title').textContent = row.name;
    if (ctx.kind === 'compare') {
      const sideKv = (letter, name, sd) => kv(`${letter} · ${name}`, sd
        ? [badge(sd.mode), sideDetail(sd) || null, sd.via ? h('span', { class: 'muted', text: sd.via }) : null].filter(Boolean)
        : [h('span', { class: 'cmp-absent', text: 'Absent' })]);
      items.push(
        kv('Écart', [gapBadge(row.gap)]),
        kv('Famille', row.family),
        kv('Type', row.typeLabel),
        sideKv('A', ctx.a.name, row.a),
        sideKv('B', ctx.b.name, row.b),
        row.objectId ? kv('Identifiant', [h('span', { class: 'mono', text: row.objectId }), copyBtn(row.objectId)]) : null,
        row.groupId ? kv('Identifiant du groupe', [h('span', { class: 'mono', text: row.groupId }), copyBtn(row.groupId)]) : null,
      );
      if (ctx.cmpKind !== 'object' && row.objectId) actions.push(primary('Voir toutes les cibles de cet élément', () => onOpenObject(row.objectId)));
      if (row.groupId && row.groupExists !== false) actions.push(primary('Ouvrir ce groupe', () => onOpenGroup(row.groupId)));
    } else if (isProfile(ctx.kind)) {
      profilePanel(row, items, actions);
    } else if (ctx.kind === 'group') {
      items.push(
        kv('Famille', row.family),
        kv('Type', row.odataType ? `${row.typeLabel} (${String(row.odataType).replace('#microsoft.graph.', '')})` : null),
        kv('Statut', [badge(row.modeKey)]),
        kv('Via', row.viaText),
        kv('Intent', row.intentText),
        kv('Filtre', row.filter ? [`${row.filterText}`, h('span', { class: 'mono muted', text: row.filter.id })] : null),
        kv('Plateforme', row.platform),
        kv('Dernière modification', r.lastModified ? fmt.date(r.lastModified) : null),
        kv('Identifiant', [h('span', { class: 'mono', text: row.objectId }), copyBtn(row.objectId)]),
      );
      if (row.kind === 'global') items.push(kv('Remarque', 'Règle globale : application au groupe non calculée (indicatif).'));
      actions.push(primary('Voir toutes les cibles de cet élément', () => onOpenObject(row.objectId)));
    } else {
      items.push(
        kv('Cible', row.typeLabel),
        kv('Statut', [badge(row.modeKey)]),
        kv('Via', row.viaText),
        kv('Intent', row.intentText),
        kv('Filtre', row.filter ? [`${row.filterText}`, h('span', { class: 'mono muted', text: row.filter.id })] : null),
        row.groupId ? kv('Identifiant du groupe', [h('span', { class: 'mono', text: row.groupId }), copyBtn(row.groupId)]) : null,
        row.kind === 'group' && !row.groupExists ? kv('Remarque', 'Ce groupe a été supprimé dans Entra.') : null,
      );
      if (row.groupId) actions.push(primary('Ouvrir ce groupe', () => onOpenGroup(row.groupId)));
    }
    body.replaceChildren(
      h('dl', { class: 'kv' }, items.filter(Boolean).flat()),
      h('div', { class: 'panel-actions' }, actions),
    );
    $('detail-panel').hidden = false;
    $('panel-close').focus();
    markChanged();
  }

  function closePanel() {
    const p = $('detail-panel');
    if (p.hidden) return false;
    p.hidden = true;
    if (lastFocus && document.contains(lastFocus)) lastFocus.focus();
    lastFocus = null;
    markChanged();
    return true;
  }

  // ---------- Filtres et actions ----------

  let ft = 0;
  const onText = () => { filters.text = elText.value; if (ctx) ctx.page = 1; refresh(); };
  elText.addEventListener('input', () => { clearTimeout(ft); ft = setTimeout(onText, 80); });
  elText.addEventListener('keydown', (e) => { if (e.key === 'Escape' && elText.value) { e.stopPropagation(); elText.value = ''; onText(); } });
  elMode.addEventListener('change', () => { filters.mode = elMode.value; refresh(); });
  elVia.addEventListener('change', () => { filters.via = elVia.value; if (filters.via === 'global') filters.collapsed.delete('global'); refresh(); });
  elDevice.addEventListener('change', () => { filters.device = elDevice.value; refresh(); });
  $('panel-close').addEventListener('click', closePanel);

  function exportData() {
    if (ctx.kind === 'compare') return compareExport(visible, ctx.a.name, ctx.b.name);
    if (isProfile(ctx.kind)) {
      if (ctx.tab === 'groups') return groupListExport(visible);
      if (ctx.tab === 'devices') return deviceExport(visible);
      return configExport(visible, ctx.kind === 'user');
    }
    return ctx.kind === 'group' ? groupExport(visible) : objectExport(visible);
  }
  function exportName() {
    if (ctx.kind === 'compare') return `Comparaison - ${ctx.title}`;
    if (isProfile(ctx.kind)) return `${ctx.title} - ${{ configs: 'Configurations', groups: 'Groupes', devices: 'Appareils' }[ctx.tab]}`;
    return ctx.title;
  }
  $('btn-export').addEventListener('click', () => {
    if (!ctx) return;
    const { headers, rows } = exportData();
    const day = new Date().toISOString().slice(0, 10);
    downloadText(`Intune Lens - ${safeFileName(exportName())} - ${day}.csv`, toCsv(headers, rows), 'text/csv;charset=utf-8');
    toast(`${fmt.plural(rows.length, 'ligne exportée', 'lignes exportées')}`);
  });
  $('btn-copy-table').addEventListener('click', () => {
    if (!ctx) return;
    const { headers, rows } = exportData();
    copyText(toTsv(headers, rows), `${fmt.plural(rows.length, 'ligne copiée', 'lignes copiées')}`);
  });

  return {
    showGroup, showObject, showUser, showDevice, showCompare, clear, closePanel,
    focusTable: () => table?.focusFirst(),
    hasPanel: () => !$('detail-panel').hidden,
    current: () => ctx,
  };
}

export { profileDevices, targetsText };
