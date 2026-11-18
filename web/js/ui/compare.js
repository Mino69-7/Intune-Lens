// compare.js : logique PURE (sans DOM) de la comparaison de deux groupes ou de deux éléments.
// Testée sous Node (tests/web/compare.test.mjs).
//
// Chaque ligne aligne un même élément (ou une même cible) des deux côtés :
//   same  : présent des deux côtés, même statut, même intent, même filtre ;
//   diff  : présent des deux côtés mais différent (ex. Inclus d'un côté, Exclu de l'autre) ;
//   onlyA / onlyB : présent d'un seul côté.
// Groupes : assignations DIRECTES + exclusions du groupe sur les règles globales (les règles globales
// elles-mêmes sont identiques pour tous les groupes : non comparées, choix de l'utilisateur).
// Utilisateurs / machines : éléments ciblés (Inclus / Exclu) + appartenance aux groupes Entra (« Membre »).

import { asArray, norm, toCsv, toTsv } from './model.js';
import { T, typeLabel, filterLabel, intentLabel, familyLabel, fmt, L, LOCALE, srv } from '../i18n.js';

export const GAP_LABEL = { same: L('Identique', 'Identical'), diff: L('Différent', 'Different'), onlyA: L('Seulement A', 'Only A'), onlyB: L('Seulement B', 'Only B') };
const GAP_ORDER = { diff: 0, onlyA: 1, onlyB: 2, same: 3 };
const collator = new Intl.Collator(LOCALE, { sensitivity: 'base', numeric: true });

/** Une « face » de ligne : ce que A (ou B) a pour cet élément. */
function side(mode, intent, filter, via) {
  return {
    mode: mode === 'exclude' ? 'exclude' : mode === 'member' ? 'member' : 'include',
    intent: intent || '',
    filterKey: filter ? `${filter.id}|${filter.mode}` : '',
    intentText: intentLabel(intent),
    filterText: filterLabel(filter),
    via: srv(via) || '',
  };
}

function sameSide(a, b) {
  return a.mode === b.mode && a.intent === b.intent && a.filterKey === b.filterKey;
}

/** Fusionne deux faces pour un même élément vu deux fois du même côté (l'exclusion l'emporte). */
function merge(prev, next) {
  if (!prev) return next;
  return prev.mode === 'exclude' ? prev : next;
}

function finalize(map) {
  const rows = [];
  for (const r of map.values()) {
    r.gap = r.a && r.b ? (sameSide(r.a, r.b) ? 'same' : 'diff') : r.a ? 'onlyA' : 'onlyB';
    rows.push(r);
  }
  return rows;
}

export function compareCounts(rows) {
  const c = { all: rows.length, gaps: 0, same: 0, diff: 0, onlyA: 0, onlyB: 0 };
  for (const r of rows) { c[r.gap]++; if (r.gap !== 'same') c.gaps++; }
  return c;
}

/** Deux vues /api/group/{id}. */
export function compareGroups(viewA, viewB) {
  const map = new Map();
  const put = (key, meta, which, s) => {
    let r = map.get(key);
    if (!r) { r = { type: 'item', key, ...meta, a: null, b: null }; map.set(key, r); }
    r[which] = merge(r[which], s);
  };
  for (const [which, view] of [['a', viewA], ['b', viewB]]) {
    for (const it of asArray(view.items)) {
      put(`o:${it.objectId}`, {
        objectId: it.objectId, name: it.name, family: it.family, platform: it.platform || '',
        typeLabel: typeLabel(it.odataType), odataType: it.odataType,
      }, which, side(it.mode, it.intent, it.filter, it.via || T.via.direct));
    }
    // Exclusions du groupe sur une règle globale (seule partie des règles globales qui varie d'un groupe à l'autre)
    for (const g of asArray(view.global)) {
      if (!g.excludedForGroup) continue;
      const via = T.via[g.target] || srv(g.via) || '';
      put(`x:${g.objectId}:${g.target}`, {
        objectId: g.objectId, name: g.name, family: 'Exclusions sur règles globales', platform: g.platform || '',
        typeLabel: L(`Exclu de « ${via} »`, `Excluded from "${via}"`), odataType: null,
      }, which, side('exclude', null, null, via));
    }
  }
  return finalize(map);
}

/** Deux vues /api/object/{id}. */
export function compareObjects(viewA, viewB) {
  const map = new Map();
  for (const [which, view] of [['a', viewA], ['b', viewB]]) {
    for (const a of asArray(view.assignments)) {
      const isGroup = a.target === 'group';
      const isOther = a.target === 'other';
      const key = isGroup ? `g:${a.groupId}` : isOther ? `t:other:${a.via}` : `t:${a.target}`;
      let r = map.get(key);
      if (!r) {
        r = {
          type: 'item', key,
          groupId: isGroup ? a.groupId : null,
          groupExists: a.groupExists !== false,
          name: isGroup ? srv(a.groupName) : isOther ? L('Cible non prise en charge', 'Unsupported target') : (T.via[a.target] || srv(a.via)),
          family: isGroup ? 'Groupes' : isOther ? 'Autres cibles' : 'Cibles globales',
          typeLabel: isGroup ? T.kindLabel.group : isOther ? L('Autre cible', 'Other target') : L('Cible globale', 'Global target'),
          platform: '', a: null, b: null,
        };
        map.set(key, r);
      }
      r[which] = merge(r[which], side(a.mode, a.intent, a.filter, a.via));
    }
  }
  return finalize(map);
}

/**
 * Deux fiches Utilisateur (ou deux fiches Machine) : éléments ciblés + groupes Entra.
 * Un élément est « Inclus » s'il s'applique à au moins un appareil, « Exclu » sinon.
 */
export function compareProfiles(viewA, viewB) {
  const map = new Map();
  const put = (key, meta, which, s) => {
    let r = map.get(key);
    if (!r) { r = { type: 'item', key, ...meta, a: null, b: null }; map.set(key, r); }
    r[which] = merge(r[which], s);
  };
  for (const [which, view] of [['a', viewA], ['b', viewB]]) {
    for (const c of asArray(view.configs)) {
      const inc = asArray(c.targets).filter((t) => t.mode === 'include');
      const via = [...new Set((inc.length ? inc : asArray(c.targets)).flatMap((t) => asArray(inc.length ? t.via : t.exclVia).map(srv)))].join(', ');
      put(`o:${c.objectId}`, {
        objectId: c.objectId, name: c.name, family: c.family, platform: c.platform || '',
        typeLabel: typeLabel(c.odataType), odataType: c.odataType,
      }, which, side(c.mode, c.intent, c.filter, via));
    }
    for (const g of asArray(view.groups)) {
      put(`g:${g.id}`, {
        groupId: g.id, name: g.name, family: GROUPS_FAMILY, platform: '',
        typeLabel: g.used ? fmt.plural(g.used, L('élément Intune', 'Intune item'), L('éléments Intune', 'Intune items')) : L('Non utilisé dans Intune', 'Not used in Intune'),
      }, which, side('member', null, null, ''));
    }
  }
  return finalize(map);
}

export const GROUPS_FAMILY = 'Groupes Entra';
const FAMILY_ORDER = { 'Cibles globales': 0, Groupes: 1, 'Autres cibles': 2, 'Groupes Entra': 98, 'Exclusions sur règles globales': 99 };

/**
 * Lignes affichées : sections par famille, éléments triés (écarts d'abord, puis par nom).
 * opts : { text, show: 'all'|'gaps'|'same'|'diff'|'onlyA'|'onlyB', collapsed: Set }
 */
export function buildCompareRows(rows, opts = {}) {
  const q = norm(opts.text || '').trim();
  const tokens = q.split(/\s+/).filter(Boolean);
  const show = opts.show || 'all';
  const keep = (r) => {
    if (show === 'gaps' && r.gap === 'same') return false;
    if (!['all', 'gaps'].includes(show) && r.gap !== show) return false;
    if (!tokens.length) return true;
    const hay = norm([r.name, r.family, r.typeLabel, r.a?.filterText, r.b?.filterText, r.a?.intentText, r.b?.intentText].join(' '));
    return tokens.every((t) => hay.includes(t));
  };
  const byFam = new Map();
  for (const r of rows) {
    if (!keep(r)) continue;
    if (!byFam.has(r.family)) byFam.set(r.family, []);
    byFam.get(r.family).push(r);
  }
  const fams = [...byFam.keys()].sort((x, y) => (FAMILY_ORDER[x] ?? 10) - (FAMILY_ORDER[y] ?? 10) || collator.compare(x, y));
  const out = [];
  const visible = [];
  for (const fam of fams) {
    const list = byFam.get(fam).sort((x, y) => GAP_ORDER[x.gap] - GAP_ORDER[y.gap] || collator.compare(x.name, y.name));
    const gaps = list.filter((r) => r.gap !== 'same').length;
    const key = `fam:${fam}`;
    const expanded = !opts.collapsed?.has(key);
    out.push({
      type: 'section', key, label: fam, count: list.length, expanded,
      countText: fmt.plural(list.length, L('élément', 'item'), L('éléments', 'items')) + (gaps ? ` · ${fmt.plural(gaps, L('écart', 'difference'), L('écarts', 'differences'))}` : L(' · identiques', ' · identical')),
    });
    if (expanded) out.push(...list);
    visible.push(...list);
  }
  return { rows: out, visible };
}

export const sideStatus = (s) => (s ? (s.mode === 'exclude' ? T.mode.exclude : s.mode === 'member' ? L('Membre', 'Member') : T.mode.include) : L('Absent', 'Missing'));
export const sideDetail = (s) => (s ? [s.intentText, s.filterText].filter(Boolean).join(' · ') : '');

export function compareExport(visible, nameA, nameB) {
  const headers = [L('Famille', 'Family'), L('Nom', 'Name'), 'Type', L(`Statut A (${nameA})`, `Status A (${nameA})`), L('Détail A', 'Details A'), L(`Statut B (${nameB})`, `Status B (${nameB})`), L('Détail B', 'Details B'), L('Écart', 'Difference')];
  const rows = visible.map((r) => [familyLabel(r.family), r.name, r.typeLabel, sideStatus(r.a), sideDetail(r.a), sideStatus(r.b), sideDetail(r.b), GAP_LABEL[r.gap]]);
  return { headers, rows };
}

export { toCsv, toTsv };
