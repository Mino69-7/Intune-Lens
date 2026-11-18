// views.js : écrans de résultat (Groupe, Élément, Utilisateur, Machine, Comparaison) et panneau latéral de détail.

import { $, h, icon, copyText, downloadText, toast } from './dom.js';
import { VTable } from './vtable.js';
import { shareLink } from './link.js';
import {
  asArray, buildGroupRows, buildObjectRows, familyCounts, groupExport, objectExport,
  statusText, toCsv, toTsv, safeFileName,
} from './model.js';
import { fmt, typeLabel, familyLabel, T, L, tx } from '../i18n.js';
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

function copyBtn(value, label = L('Copier', 'Copy')) {
  return h('button', {
    type: 'button', class: 'copy-btn', 'aria-label': L(`${label} l'identifiant`, `${label} the identifier`),
    on: { click: (e) => { e.stopPropagation(); copyText(value, L('Identifiant copié', 'Identifier copied')); } },
  }, [label]);
}

const deviceIcon = (platform) => (platform === 'iOS' || platform === 'Android' ? 'phone' : 'laptop');

/** Pastille d'appareil : icône, nom ; estompée si inactif, barrée d'un cercle si exclu. */
function devicePill(t) {
  const cls = `dev-pill${t.mode === 'exclude' ? ' is-excluded' : ''}${t.stale ? ' is-stale' : ''}`;
  const title = `${t.deviceName}${t.mode === 'exclude' ? L(' : exclu', ': excluded') : ''}${t.stale ? L(' (inactif)', ' (inactive)') : ''}`;
  return h('span', { class: cls, title }, [icon(t.mode === 'exclude' ? 'ban' : deviceIcon(t.platform)), h('span', { class: 'dev-name', text: t.deviceName })]);
}
function devicePills(r) {
  if (r.allDevices && r.targets.length > 1) return h('span', { class: 'dev-pills' }, [h('span', { class: 'dev-pill is-all' }, [icon('laptop'), h('span', { class: 'dev-name', text: L('Tous ses appareils', 'All their devices') })])]);
  const named = r.targets.filter((t) => t.deviceName);
  if (!named.length) return h('span', { class: 'muted', text: L('Sans appareil', 'No device') });
  return h('span', { class: 'dev-pills' }, named.map(devicePill));
}

const GROUP_COLUMNS = [
  { key: 'name', label: L('Nom', 'Name'), width: 'minmax(200px, 2.4fr)', render: (r) => h('span', {}, [r.name, r.platform ? h('span', { class: 'sub', text: r.platform }) : null]) },
  { key: 'type', label: 'Type', width: 'minmax(110px, 1.3fr)', render: (r) => r.typeLabel },
  { key: 'status', label: L('Statut', 'Status'), width: '112px', render: (r) => badge(r.modeKey) },
  { key: 'via', label: 'Via', width: 'minmax(110px, 1fr)', render: (r) => r.viaText },
  { key: 'intent', label: 'Intent', width: 'minmax(80px, 0.9fr)', render: (r) => r.intentText || '—' },
  { key: 'filter', label: L('Filtre', 'Filter'), width: 'minmax(110px, 1.3fr)', render: (r) => r.filterText || '—' },
];

const OBJECT_COLUMNS = [
  {
    key: 'name', label: L('Cible', 'Target'), width: 'minmax(220px, 2.6fr)',
    render: (r) => h('span', {}, [
      r.name,
      r.kind === 'group' && !r.groupExists ? h('span', { class: 'sub tag-deleted', text: L('Groupe supprimé dans Entra', 'Group deleted in Entra') }) : null,
      r.kind === 'group' && r.groupExists ? h('span', { class: 'sub mono', text: r.groupId }) : null,
    ]),
  },
  { key: 'status', label: L('Statut', 'Status'), width: '112px', render: (r) => badge(r.modeKey) },
  { key: 'via', label: 'Via', width: 'minmax(120px, 1fr)', render: (r) => r.viaText },
  { key: 'intent', label: 'Intent', width: 'minmax(90px, 0.9fr)', render: (r) => r.intentText || '—' },
  { key: 'filter', label: L('Filtre', 'Filter'), width: 'minmax(120px, 1.3fr)', render: (r) => r.filterText || '—' },
];

/** Fiche Utilisateur (withDevices) ou Machine : éléments ciblés. */
function configColumns(withDevices) {
  return [
    { key: 'name', label: L('Nom', 'Name'), width: 'minmax(200px, 2.2fr)', render: (r) => h('span', {}, [r.name, h('span', { class: 'sub', text: [r.typeLabel, r.platform].filter(Boolean).join(' · ') })]) },
    { key: 'status', label: L('Statut', 'Status'), width: '112px', render: (r) => badge(r.modeKey) },
    withDevices
      ? { key: 'devices', label: L('Appareils', 'Devices'), width: 'minmax(150px, 1.5fr)', render: devicePills }
      : { key: 'scope', label: L('Ciblage', 'Targeting'), width: 'minmax(110px, 1fr)', render: (r) => r.scopeText },
    { key: 'via', label: 'Via', width: 'minmax(150px, 1.6fr)', render: (r) => r.viaText || '—' },
    { key: 'detail', label: L('Détail', 'Details'), width: 'minmax(100px, 1fr)', render: (r) => [r.intentText, r.filterText ? L(`Filtre : ${r.filterText}`, `Filter: ${r.filterText}`) : ''].filter(Boolean).join(' · ') || '—' },
  ];
}
const GROUP_LIST_COLUMNS = [
  { key: 'name', label: L('Groupe', 'Group'), width: 'minmax(220px, 2.6fr)', render: (r) => h('span', {}, [r.name, h('span', { class: 'sub mono', text: r.groupId })]) },
  { key: 'used', label: L('Dans Intune', 'In Intune'), width: 'minmax(150px, 1fr)', render: (r) => (r.used ? h('span', { class: 'badge badge-include' }, [r.usedText]) : h('span', { class: 'muted', text: r.usedText })) },
];
const DEVICE_COLUMNS = [
  { key: 'name', label: L('Appareil', 'Device'), width: 'minmax(180px, 1.8fr)', render: (r) => h('span', {}, [r.name, h('span', { class: 'sub', text: r.modelText || r.raw.serial || '' })]) },
  { key: 'os', label: L('Système', 'OS'), width: 'minmax(120px, 1.2fr)', render: (r) => r.osText || '—' },
  { key: 'sync', label: L('Dernière synchro', 'Last sync'), width: 'minmax(140px, 1.1fr)', render: (r) => h('span', { class: 'dev-sync' }, [r.syncText, r.stale ? h('span', { class: 'badge badge-neutral', text: L('Inactif', 'Inactive') }) : null]) },
  { key: 'compliance', label: L('Conformité', 'Compliance'), width: 'minmax(110px, 1fr)', render: (r) => r.complianceText },
];

/** Cellule d'un côté de la comparaison : statut + détail (intent, filtre), ou « Absent ». */
function sideCell(sd) {
  if (!sd) return h('span', { class: 'cmp-absent', text: L('Absent', 'Missing') });
  const detail = sideDetail(sd);
  return h('span', { class: 'cmp-cell' }, [badge(sd.mode), detail ? h('span', { class: 'sub', text: detail }) : null]);
}
function gapBadge(gap) {
  return h('span', { class: `badge gap-badge gap-${gap}` }, [GAP_LABEL[gap]]);
}
function compareColumns(nameA, nameB) {
  return [
    { key: 'name', label: L('Nom', 'Name'), width: 'minmax(180px, 2fr)', render: (r) => h('span', {}, [r.name, h('span', { class: 'sub', text: [r.typeLabel, r.platform].filter(Boolean).join(' · ') })]) },
    { key: 'side-a', label: `A · ${nameA}`, width: 'minmax(132px, 1.2fr)', render: (r) => sideCell(r.a) },
    { key: 'side-b', label: `B · ${nameB}`, width: 'minmax(132px, 1.2fr)', render: (r) => sideCell(r.b) },
    { key: 'gap', label: L('Écart', 'Difference'), width: '112px', render: (r) => gapBadge(r.gap) },
  ];
}

/** Nom, identifiant, nombre d'éléments et libellés d'une fiche, quel que soit son type. */
function describe(kind, view) {
  switch (kind) {
    case 'group': return { id: view.group.id, name: view.group.name, count: asArray(view.items).length, kicker: T.kindLabel.group, unit: [L('élément assigné', 'assigned item'), L('éléments assignés', 'assigned items')], what: L('ces deux groupes', 'these two groups') };
    case 'object': return { id: view.object.id, name: view.object.name, count: asArray(view.assignments).length, kicker: familyLabel(view.object.family) || 'Configuration', unit: [L('cible', 'target'), L('cibles', 'targets')], what: L('ces deux éléments', 'these two items') };
    case 'user': return { id: view.user.id, name: view.user.name, count: asArray(view.configs).length, kicker: T.kindLabel.user, unit: [L('élément ciblé', 'targeted item'), L('éléments ciblés', 'targeted items')], what: L('ces deux utilisateurs', 'these two users') };
    default: return { id: view.device.id, name: view.device.name, count: asArray(view.configs).length, kicker: T.kindLabel.device, unit: [L('élément ciblé', 'targeted item'), L('éléments ciblés', 'targeted items')], what: L('ces deux machines', 'these two devices') };
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
  const resetButton = () => h('button', { type: 'button', class: 'btn', text: L('Réinitialiser les filtres', 'Reset filters'), on: { click: () => { resetFilters(); refresh(); } } });

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
    if (rows.length === 0 && filtered) showEmpty(L('Aucun résultat avec ces filtres', 'No results with these filters'), '', resetButton());
    else if (rows.length === 0 && ctx.tab === 'groups') showEmpty(L('Aucun groupe', 'No groups'), asArray(v.warnings).length ? L('Les groupes n\'ont pas pu être lus (voir ci-dessus).', 'The groups could not be read (see above).') : L('Membre d\'aucun groupe Entra.', 'Not a member of any Entra group.'));
    else if (rows.length === 0 && ctx.tab === 'devices') showEmpty(L('Aucun appareil', 'No devices'), L('Aucun appareil géré par Intune pour cet utilisateur.', 'No Intune-managed device for this user.'));
    else if (rows.length === 0) showEmpty(L('Aucun élément ciblé', 'Nothing targeted'), ctx.kind === 'user'
      ? L('Aucune configuration, application ou stratégie ne cible cet utilisateur ni ses appareils.', 'No configuration, app or policy targets this user or their devices.')
      : L('Aucune configuration, application ou stratégie ne cible cette machine ni son utilisateur.', 'No configuration, app or policy targets this device or its user.'));
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
      showEmpty(L('Rien à comparer', 'Nothing to compare'), L(`Aucune assignation pour ${ctx.what}.`, `No assignments for ${ctx.what}.`));
    } else if (ctx.kind === 'compare' && filters.show === 'gaps' && rows.length === 0 && !filters.text) {
      showEmpty(L('Aucun écart', 'No differences'), L(`${ctx.what.charAt(0).toUpperCase()}${ctx.what.slice(1)} ont exactement les mêmes assignations.`, `${ctx.what.charAt(0).toUpperCase()}${ctx.what.slice(1)} have exactly the same assignments.`));
    } else if (ctx.kind === 'group' && asArray(ctx.view.items).length === 0 && !filtered) {
      showEmpty(L('Aucune assignation directe', 'No direct assignments'), L("Aucune configuration, application ou stratégie n'est assignée directement à ce groupe. Les assignations globales (indicatives) restent listées ci-dessous.", 'No configuration, app or policy is assigned directly to this group. Global assignments (for information) are still listed below.'));
    } else if (ctx.kind === 'object' && ctx.view.unassigned) {
      showEmpty(L('Aucune assignation', 'No assignments'), L("Cet élément n'est assigné à aucun groupe ni à aucune cible globale (orphelin potentiel).", 'This item is not assigned to any group or global target (possibly orphaned).'));
    } else if (rows.length === 0) {
      showEmpty(L('Aucun résultat avec ces filtres', 'No results with these filters'), '', resetButton());
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
      btn(icon('chevronLeft'), p.page - 1, { 'aria-label': L('Page précédente', 'Previous page'), disabled: p.page <= 1 }),
      ...pageList(p.page, p.pages).map((n) => (n === null
        ? h('span', { class: 'pager-gap', 'aria-hidden': 'true', text: '…' })
        : btn(String(n), n, { 'aria-label': `Page ${n}`, 'aria-current': n === p.page ? 'page' : null }))),
      btn(icon('chevronRight'), p.page + 1, { 'aria-label': L('Page suivante', 'Next page'), disabled: p.page >= p.pages }),
      h('span', { class: 'pager-info', text: L(`${fmt.num(first)}–${fmt.num(last)} sur ${fmt.num(p.total)}`, `${fmt.num(first)}–${fmt.num(last)} of ${fmt.num(p.total)}`) }),
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
      const defs = [['all', L('Tous', 'All')], ['gaps', L('Écarts', 'Differences')], ['onlyA', L('Seulement A', 'Only A')], ['onlyB', L('Seulement B', 'Only B')], ['diff', L('Différents', 'Different')], ['same', L('Identiques', 'Identical')]];
      box.replaceChildren(...defs.map(([k, l]) => chip(filters.show === k, l, c[k], () => { filters.show = k; refresh(); })));
      return;
    }
    if (isProfile(ctx.kind)) {
      // Onglets de la fiche : Configurations · Groupes · Appareils
      const v = ctx.view;
      const tabs = [['configs', 'Configurations', asArray(v.configs).length], ['groups', L('Groupes', 'Groups'), asArray(v.groups).length]];
      if (ctx.kind === 'user') tabs.push(['devices', L('Appareils', 'Devices'), asArray(v.devices).length]);
      box.replaceChildren(...tabs.map(([k, l, n]) => chip(ctx.tab === k, l, n, () => setTab(k))));
      return;
    }
    if (ctx.kind !== 'group') { box.replaceChildren(); return; }
    box.replaceChildren(...familyCounts(ctx.view).map(([fam, n]) => chip(filters.families.has(fam), familyLabel(fam), n, () => {
      if (filters.families.has(fam)) filters.families.delete(fam); else filters.families.add(fam);
      refresh();
    }, L(`Filtrer : ${familyLabel(fam)}`, `Filter: ${familyLabel(fam)}`))));
  }

  function renderNotes(status) {
    const notes = [];
    const unc = asArray(status?.uncovered);
    if (unc.length) {
      notes.push(h('div', { class: 'notes-box surface', role: 'note' }, [
        h('strong', { text: L('Non couvert (permission non consentie) : ', 'Not covered (permission not granted): ') }),
        unc.map((u) => familyLabel(u.family)).join(', '),
        L('. Les assignations de ces types n\'apparaissent pas ici.', '. Assignments of these types are not shown here.'),
      ]));
    }
    if (ctx.kind === 'group' && ctx.view.group && ctx.view.group.exists === false) {
      notes.push(h('div', { class: 'notes-box surface', role: 'note' }, [
        h('strong', { text: L('Groupe supprimé dans Entra. ', 'Group deleted in Entra. ') }),
        L('Il est encore référencé par des assignations : elles ne s\'appliquent plus à personne.', 'It is still referenced by assignments: they no longer apply to anyone.'),
      ]));
    }
    if (isProfile(ctx.kind)) {
      const w = asArray(ctx.view.warnings);
      if (w.length) notes.push(h('div', { class: 'notes-box surface', role: 'note' }, [h('strong', { text: L('Données partielles : ', 'Partial data: ') }), w.map(tx).join(' · ')]));
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
      type: 'button', class: 'btn', text: L('Copier le lien', 'Copy link'),
      title: L('Lien à envoyer à un collègue : il le colle (Ctrl+V) dans son Intune Lens pour ouvrir cette fiche', 'Link to send to a colleague: they paste it (Ctrl+V) into their Intune Lens to open this page'),
      on: { click: () => copyText(shareLink(kind, id), L('Lien copié : à coller (Ctrl+V) dans Intune Lens pour ouvrir cette fiche.', 'Link copied: paste it (Ctrl+V) into Intune Lens to open this page.')) },
    });
  }

  function compareButton(kind, id, name) {
    const titles = {
      group: L('Comparer ce groupe avec un autre groupe', 'Compare this group with another group'), object: L('Comparer avec une autre configuration', 'Compare with another configuration'),
      user: L('Comparer avec un autre utilisateur', 'Compare with another user'), device: L('Comparer avec une autre machine', 'Compare with another device'),
    };
    return h('button', {
      type: 'button', class: 'btn btn-primary', text: L('Comparer', 'Compare'), title: titles[kind],
      on: { click: () => onCompare?.(kind, id, name) },
    });
  }

  function showGroup(view, status) {
    closePanel();
    resetFilters();
    ctx = { kind: 'group', view, title: view.group.name };
    setToolbar({ mode: true, via: true });
    header({
      kicker: T.kindLabel.group,
      title: view.group.name,
      meta: [
        h('span', { class: 'mono', text: view.group.id }), copyBtn(view.group.id),
        view.group.exists === false ? h('span', { class: 'tag-deleted', text: L('Supprimé dans Entra', 'Deleted in Entra') }) : null,
      ],
      total: view.total,
      totalLabel: view.total > 1 ? L('éléments assignés', 'assigned items') : L('élément assigné', 'assigned item'),
      actions: [linkButton('group', view.group.id), compareButton('group', view.group.id, view.group.name)],
    });
    ensureTable(GROUP_COLUMNS, L(`Éléments assignés au groupe ${view.group.name}`, `Items assigned to group ${view.group.name}`));
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
      kicker: familyLabel(o.family),
      title: o.name,
      meta: [
        o.platform ? h('span', { text: o.platform }) : null,
        h('span', { text: typeLabel(o.odataType) }),
        h('span', { text: L(`Modifié le ${fmt.date(o.lastModified)}`, `Modified ${fmt.date(o.lastModified)}`) }),
        h('span', { class: 'mono', text: o.id }), copyBtn(o.id),
      ],
      total: n,
      totalLabel: n > 1 ? L('cibles', 'targets') : L('cible', 'target'),
      actions: [linkButton('object', o.id), compareButton('object', o.id, o.name)],
    });
    ensureTable(OBJECT_COLUMNS, L(`Cibles de ${o.name}`, `Targets of ${o.name}`));
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
      ensureTable(GROUP_LIST_COLUMNS, L(`Groupes Entra de ${name}`, `Entra groups of ${name}`));
    } else if (tab === 'devices') {
      setToolbar({});
      ensureTable(DEVICE_COLUMNS, L(`Appareils de ${name}`, `Devices of ${name}`));
    } else {
      setToolbar({ mode: true, device: ctx.kind === 'user' && asArray(v.devices).length > 1 });
      ensureTable(configColumns(ctx.kind === 'user'), L(`Éléments ciblant ${name}`, `Items targeting ${name}`), {
        className: `vt-profile vt-profile-${ctx.kind}`,
        rowClass: (r) => (r.targets.every((t) => t.stale) ? 'is-stale' : ''),
      });
    }
    refresh();
  }

  function fillDeviceFilter(view) {
    const devs = asArray(view.devices);
    elDevice.replaceChildren(
      h('option', { value: '', text: L('Tous', 'All') }),
      ...devs.map((d) => h('option', { value: d.id, text: `${d.name}${d.stale ? L(' (inactif)', ' (inactive)') : ''}` })),
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
      kicker: T.kindLabel.user,
      title: u.name,
      meta: [
        h('span', { class: 'mono', text: u.upn || u.id }), copyBtn(u.upn || u.id),
        h('span', { text: fmt.plural(devs.length, L('appareil', 'device'), L('appareils', 'devices')) + (stale ? L(` (dont ${fmt.plural(stale, 'inactif', 'inactifs')})`, ` (${fmt.num(stale)} inactive)`) : '') }),
        h('span', { text: fmt.plural(asArray(view.groups).length, L('groupe', 'group'), L('groupes', 'groups')) }),
      ],
      total: n,
      totalLabel: n > 1 ? L('éléments ciblés', 'targeted items') : L('élément ciblé', 'targeted item'),
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
      kicker: [T.kindLabel.device, d.stale ? h('span', { class: 'hdr-tag', text: L(`Inactive depuis ${fmt.num(days)} j`, `Inactive for ${fmt.num(days)} days`) }) : null],
      title: d.name,
      meta: [
        h('span', { text: [d.os, d.osVersion].filter(Boolean).join(' ') || '—' }),
        d.model ? h('span', { text: [d.maker, d.model].filter(Boolean).join(' ') }) : null,
        h('span', { text: L(`Synchro ${fmt.ago(d.lastSync)}`, `Synced ${fmt.ago(d.lastSync)}`) }),
        h('span', { text: complianceLabel(d.compliance) }),
        view.user
          ? h('button', { type: 'button', class: 'btn-link hdr-user', title: L(`Ouvrir la fiche de ${view.user.name}`, `Open ${view.user.name}'s page`), on: { click: () => onOpenUser?.(view.user.id) } }, [icon('person'), view.user.name])
          : h('span', { class: 'muted', text: L('Sans utilisateur', 'No user') }),
      ],
      total: n,
      totalLabel: n > 1 ? L('éléments ciblés', 'targeted items') : L('élément ciblé', 'targeted item'),
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
          type: 'button', class: 'icon-btn cmp-swap', title: L('Inverser A et B', 'Swap A and B'), 'aria-label': L('Inverser A et B', 'Swap A and B'),
          on: { click: () => onSwapCompare?.(kind, A.id, B.id) },
        }, [icon('swap')]),
        sideBlock('B', B, 'result-title-b'),
      ]),
      h('div', { class: 'hdr-actions' }, [
        h('button', { type: 'button', class: 'btn', text: L('Fermer', 'Close'), title: L(`Revenir à ${A.name}`, `Back to ${A.name}`), on: { click: () => onCloseCompare?.(kind, A.id) } }),
      ]),
    );
    hd.hidden = false;
    $('result-view').setAttribute('aria-labelledby', 'result-title');

    ensureTable(compareColumns(A.name, B.name), L(`Comparaison de ${A.name} et ${B.name}`, `Comparison of ${A.name} and ${B.name}`), {
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
        kv(L('Utilisation dans Intune', 'Use in Intune'), row.usedText),
        kv(L('Identifiant', 'ID'), [h('span', { class: 'mono', text: row.groupId }), copyBtn(row.groupId)]),
      );
      actions.push(primary(L('Ouvrir ce groupe', 'Open this group'), () => onOpenGroup(row.groupId)));
    } else if (row.kind === 'device') {
      const d = row.raw;
      items.push(
        kv(L('Système', 'OS'), row.osText),
        kv(L('Modèle', 'Model'), row.modelText),
        kv(L('N° de série', 'Serial number'), d.serial ? [h('span', { class: 'mono', text: d.serial }), copyBtn(d.serial)] : null),
        kv(L('Dernière synchro', 'Last sync'), `${fmt.date(d.lastSync)} (${fmt.ago(d.lastSync)})`),
        kv(L('État', 'State'), d.stale ? [h('span', { class: 'badge badge-neutral', text: L('Inactif', 'Inactive') }), L(' : aucune synchro depuis plus de 30 jours', ': no sync for more than 30 days')] : L('Actif', 'Active')),
        kv(L('Conformité', 'Compliance'), row.complianceText),
      );
      actions.push(primary(L('Ouvrir la machine', 'Open the device'), () => onOpenDevice?.(row.deviceId)));
    } else {
      items.push(
        kv(L('Famille', 'Family'), familyLabel(row.family)),
        kv('Type', row.typeLabel),
        kv(L('Statut', 'Status'), [badge(row.modeKey)]),
        ctx.kind === 'device' ? kv(L('Ciblage', 'Targeting'), row.scopeText) : null,
        kv('Via', row.viaText),
        kv('Intent', row.intentText),
        kv(L('Filtre', 'Filter'), row.filter ? [`${row.filterText}`, h('span', { class: 'muted', text: L('Filtre non évalué : l\'application réelle en dépend.', 'Filter not evaluated: whether it actually applies depends on it.') })] : null),
        kv(L('Plateforme', 'Platform'), row.platform),
      );
      if (ctx.kind === 'user') {
        const list = h('ul', { class: 'dev-list' }, row.targets.filter((t) => t.deviceName).map((t) => h('li', {}, [
          devicePill(t),
          h('span', { class: 'muted', text: t.mode === 'exclude' ? L(`Exclu par ${t.exclVia.join(', ')}`, `Excluded by ${t.exclVia.join(', ')}`) : t.via.join(', ') + (t.mixedExcl ? L(` · exclusion non garantie : ${t.exclVia.join(', ')}`, ` · exclusion not guaranteed: ${t.exclVia.join(', ')}`) : '') }),
        ])));
        if (row.mixedExcl) items.push(kv('Exclusion', L('Groupe d\'utilisateurs et groupe d\'appareils mélangés entre inclusion et exclusion : Intune ne le prend pas en charge, l\'exclusion peut ne pas s\'appliquer.', 'A user group and a device group are mixed between inclusion and exclusion: Intune does not support this, so the exclusion may not apply.')));
        items.push(kv(L('Par appareil', 'Per device'), row.targets.some((t) => t.deviceName) ? [list] : L('Utilisateur sans appareil : ciblage par l\'utilisateur seulement.', 'User without a device: targeting through the user only.')));
      }
      items.push(kv(L('Identifiant', 'ID'), [h('span', { class: 'mono', text: row.objectId }), copyBtn(row.objectId)]));
      actions.push(primary(L('Voir toutes les cibles de cet élément', 'See all targets of this item'), () => onOpenObject(row.objectId)));
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
        : [h('span', { class: 'cmp-absent', text: L('Absent', 'Missing') })]);
      items.push(
        kv(L('Écart', 'Difference'), [gapBadge(row.gap)]),
        kv(L('Famille', 'Family'), familyLabel(row.family)),
        kv('Type', row.typeLabel),
        sideKv('A', ctx.a.name, row.a),
        sideKv('B', ctx.b.name, row.b),
        row.objectId ? kv(L('Identifiant', 'ID'), [h('span', { class: 'mono', text: row.objectId }), copyBtn(row.objectId)]) : null,
        row.groupId ? kv(L('Identifiant du groupe', 'Group ID'), [h('span', { class: 'mono', text: row.groupId }), copyBtn(row.groupId)]) : null,
      );
      if (ctx.cmpKind !== 'object' && row.objectId) actions.push(primary(L('Voir toutes les cibles de cet élément', 'See all targets of this item'), () => onOpenObject(row.objectId)));
      if (row.groupId && row.groupExists !== false) actions.push(primary(L('Ouvrir ce groupe', 'Open this group'), () => onOpenGroup(row.groupId)));
    } else if (isProfile(ctx.kind)) {
      profilePanel(row, items, actions);
    } else if (ctx.kind === 'group') {
      items.push(
        kv(L('Famille', 'Family'), familyLabel(row.family)),
        kv('Type', row.odataType ? `${row.typeLabel} (${String(row.odataType).replace('#microsoft.graph.', '')})` : null),
        kv(L('Statut', 'Status'), [badge(row.modeKey)]),
        kv('Via', row.viaText),
        kv('Intent', row.intentText),
        kv(L('Filtre', 'Filter'), row.filter ? [`${row.filterText}`, h('span', { class: 'mono muted', text: row.filter.id })] : null),
        kv(L('Plateforme', 'Platform'), row.platform),
        kv(L('Dernière modification', 'Last modified'), r.lastModified ? fmt.date(r.lastModified) : null),
        kv(L('Identifiant', 'ID'), [h('span', { class: 'mono', text: row.objectId }), copyBtn(row.objectId)]),
      );
      if (row.kind === 'global') items.push(kv(L('Remarque', 'Note'), L('Règle globale : application au groupe non calculée (indicatif).', 'Global rule: whether it applies to the group is not computed (for information).')));
      actions.push(primary(L('Voir toutes les cibles de cet élément', 'See all targets of this item'), () => onOpenObject(row.objectId)));
    } else {
      items.push(
        kv(L('Cible', 'Target'), row.typeLabel),
        kv(L('Statut', 'Status'), [badge(row.modeKey)]),
        kv('Via', row.viaText),
        kv('Intent', row.intentText),
        kv(L('Filtre', 'Filter'), row.filter ? [`${row.filterText}`, h('span', { class: 'mono muted', text: row.filter.id })] : null),
        row.groupId ? kv(L('Identifiant du groupe', 'Group ID'), [h('span', { class: 'mono', text: row.groupId }), copyBtn(row.groupId)]) : null,
        row.kind === 'group' && !row.groupExists ? kv(L('Remarque', 'Note'), L('Ce groupe a été supprimé dans Entra.', 'This group was deleted in Entra.')) : null,
      );
      if (row.groupId) actions.push(primary(L('Ouvrir ce groupe', 'Open this group'), () => onOpenGroup(row.groupId)));
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
    if (ctx.kind === 'compare') return L(`Comparaison - ${ctx.title}`, `Comparison - ${ctx.title}`);
    if (isProfile(ctx.kind)) return `${ctx.title} - ${{ configs: 'Configurations', groups: L('Groupes', 'Groups'), devices: L('Appareils', 'Devices') }[ctx.tab]}`;
    return ctx.title;
  }
  $('btn-export').addEventListener('click', () => {
    if (!ctx) return;
    const { headers, rows } = exportData();
    const day = new Date().toISOString().slice(0, 10);
    downloadText(`Intune Lens - ${safeFileName(exportName())} - ${day}.csv`, toCsv(headers, rows), 'text/csv;charset=utf-8');
    toast(fmt.plural(rows.length, L('ligne exportée', 'row exported'), L('lignes exportées', 'rows exported')));
  });
  $('btn-copy-table').addEventListener('click', () => {
    if (!ctx) return;
    const { headers, rows } = exportData();
    copyText(toTsv(headers, rows), fmt.plural(rows.length, L('ligne copiée', 'row copied'), L('lignes copiées', 'rows copied')));
  });

  return {
    showGroup, showObject, showUser, showDevice, showCompare, clear, closePanel,
    focusTable: () => table?.focusFirst(),
    hasPanel: () => !$('detail-panel').hidden,
    current: () => ctx,
  };
}

export { profileDevices, targetsText };
