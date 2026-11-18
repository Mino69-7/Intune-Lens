// model.js : logique pure (sans DOM) : filtres, regroupement par famille, export CSV/TSV.
// Testée sous Node (tests/web/model.test.mjs).

import { T, typeLabel, filterLabel, intentLabel, fmt } from '../i18n.fr.js';

export const asArray = (x) => (Array.isArray(x) ? x : x === null || x === undefined ? [] : [x]);

/** Minuscules sans accents ni ligatures (même règle que la recherche serveur). */
export function norm(s) {
  return String(s ?? '')
    .toLowerCase()
    .replace(/œ/g, 'oe').replace(/æ/g, 'ae').replace(/ß/g, 'ss')
    .normalize('NFD').replace(/[̀-ͯ]/g, '');
}

const collator = new Intl.Collator('fr-FR', { sensitivity: 'base', numeric: true });

function matchesText(row, q) {
  if (!q) return true;
  const hay = norm([row.name, row.family, row.typeLabel, row.filterText, row.intentText, row.viaText].join(' '));
  return q.split(/\s+/).filter(Boolean).every((t) => hay.includes(t));
}

/** Lignes « élément » d'un groupe : directes + globales (indicatives). */
export function groupItems(view) {
  const direct = asArray(view.items).map((it) => ({
    type: 'item',
    key: `d:${it.objectId}:${it.mode}`,
    kind: 'direct',
    objectId: it.objectId,
    name: it.name,
    family: it.family,
    platform: it.platform || '',
    lastModified: it.lastModified,
    odataType: it.odataType,
    typeLabel: typeLabel(it.odataType),
    modeKey: it.mode === 'exclude' ? 'exclude' : 'include',
    viaText: it.via || T.via.direct,
    intentText: intentLabel(it.intent),
    filterText: filterLabel(it.filter),
    filter: it.filter || null,
    raw: it,
  }));
  const global = asArray(view.global).map((g) => ({
    type: 'item',
    key: `g:${g.objectId}:${g.target}`,
    kind: 'global',
    objectId: g.objectId,
    name: g.name,
    family: g.family,
    platform: g.platform || '',
    odataType: null,
    typeLabel: '—',
    modeKey: g.excludedForGroup ? 'exclude' : 'potential',
    viaText: T.via[g.target] || g.via || '',
    intentText: intentLabel(g.intent),
    filterText: filterLabel(g.filter),
    filter: g.filter || null,
    raw: g,
  }));
  return { direct, global };
}

/**
 * Construit les lignes affichées pour l'écran Groupe.
 * opts : { text, mode: ''|'include'|'exclude', via: ''|'direct'|'global', families: Set, collapsed: Set }
 * Renvoie { rows, visible } (visible = éléments filtrés, pour l'export).
 */
export function buildGroupRows(view, opts) {
  const { direct, global } = groupItems(view);
  const q = norm(opts.text || '').trim();
  const fams = opts.families || new Set();
  const keep = (r) =>
    matchesText(r, q) &&
    (!opts.mode || (opts.mode === 'exclude' ? r.modeKey === 'exclude' : r.modeKey === 'include' || r.modeKey === 'potential')) &&
    (fams.size === 0 || fams.has(r.family));

  const rows = [];
  const visible = [];
  if (opts.via !== 'global') {
    const byFam = new Map();
    for (const r of direct) {
      if (!keep(r)) continue;
      if (!byFam.has(r.family)) byFam.set(r.family, []);
      byFam.get(r.family).push(r);
    }
    for (const fam of [...byFam.keys()].sort(collator.compare)) {
      const list = byFam.get(fam).sort((a, b) => collator.compare(a.name, b.name));
      const key = `fam:${fam}`;
      const expanded = !opts.collapsed?.has(key);
      rows.push({ type: 'section', key, label: fam, count: list.length, countText: fmt.plural(list.length, 'élément', 'éléments'), expanded });
      if (expanded) rows.push(...list);
      visible.push(...list);
    }
  }
  if (opts.via !== 'direct') {
    const list = global.filter(keep).sort((a, b) => (a.modeKey === b.modeKey ? collator.compare(a.name, b.name) : a.modeKey === 'exclude' ? -1 : 1));
    if (list.length) {
      const key = 'global';
      const expanded = !opts.collapsed?.has(key);
      const excl = list.filter((r) => r.modeKey === 'exclude').length;
      rows.push({
        type: 'section', key, label: 'Assignations globales (indicatif)', count: list.length,
        countText: fmt.plural(list.length, 'règle', 'règles') + (excl ? ` · ${fmt.plural(excl, 'exclusion de ce groupe', 'exclusions de ce groupe')}` : ''),
        expanded,
      });
      if (expanded) {
        rows.push({ type: 'note', key: 'global-note', text: T.globalNote });
        rows.push(...list);
      }
      visible.push(...list);
    }
  }
  return { rows, visible };
}

/** Comptes par famille (assignations directes) pour le bandeau de synthèse. */
export function familyCounts(view) {
  const m = new Map();
  for (const it of asArray(view.items)) m.set(it.family, (m.get(it.family) || 0) + 1);
  return [...m.entries()].sort((a, b) => b[1] - a[1] || collator.compare(a[0], b[0]));
}

/** Lignes de l'écran Élément → groupes. */
export function buildObjectRows(view, opts = {}) {
  const q = norm(opts.text || '').trim();
  const rows = asArray(view.assignments).map((a, i) => {
    const isGroup = a.target === 'group';
    const isOther = a.target === 'other';
    return {
      type: 'item',
      key: `a:${i}`,
      kind: isGroup ? 'group' : isOther ? 'other' : 'global',
      groupId: a.groupId || null,
      groupExists: a.groupExists !== false,
      name: isGroup ? a.groupName : isOther ? 'Cible non prise en charge' : T.via[a.target] || a.via,
      family: '',
      typeLabel: isGroup ? 'Groupe Entra' : isOther ? 'Autre cible' : 'Cible globale',
      modeKey: a.mode === 'exclude' ? 'exclude' : 'include',
      viaText: a.via || (isGroup ? T.via.direct : T.via[a.target] || ''),
      intentText: intentLabel(a.intent),
      filterText: filterLabel(a.filter),
      filter: a.filter || null,
      raw: a,
    };
  });
  const visible = rows.filter((r) => matchesText(r, q) && (!opts.mode || r.modeKey === opts.mode));
  return { rows: visible, visible };
}

export const statusText = (modeKey) =>
  modeKey === 'exclude' ? 'Exclu' : modeKey === 'potential' ? 'Potentiel' : modeKey === 'member' ? 'Membre' : 'Inclus';

/** Neutralise l'injection de formules à l'ouverture dans Excel. */
function safeCell(v) {
  let s = String(v ?? '');
  if (/^[=+\-@\t\r]/.test(s)) s = `'${s}`;
  return s;
}

/** CSV : séparateur « ; », guillemets si nécessaire, fin de ligne CRLF, BOM UTF-8. */
export function toCsv(headers, rows) {
  const q = (v) => {
    const s = safeCell(v);
    return /[;"\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  return '﻿' + [headers, ...rows].map((r) => r.map(q).join(';')).join('\r\n') + '\r\n';
}

/** TSV pour le presse-papiers (collage direct dans Excel). */
export function toTsv(headers, rows) {
  const c = (v) => safeCell(v).replace(/[\t\r\n]+/g, ' ');
  return [headers, ...rows].map((r) => r.map(c).join('\t')).join('\r\n');
}

export function groupExport(visible) {
  const headers = ['Famille', 'Nom', 'Type', 'Statut', 'Via', 'Intent', 'Filtre', 'Plateforme', 'Identifiant'];
  const rows = visible.map((r) => [r.family, r.name, r.typeLabel, statusText(r.modeKey), r.viaText, r.intentText, r.filterText, r.platform, r.objectId]);
  return { headers, rows };
}

export function objectExport(visible) {
  const headers = ['Cible', 'Statut', 'Via', 'Intent', 'Filtre', 'Identifiant du groupe'];
  const rows = visible.map((r) => [r.name, statusText(r.modeKey), r.viaText, r.intentText, r.filterText, r.groupId || '']);
  return { headers, rows };
}

/** Nom de fichier sûr pour Windows. */
export function safeFileName(s) {
  return String(s || 'export').replace(/[<>:"/\\|?*\u0000-\u001f]+/g, '_').replace(/\s+/g, ' ').trim().slice(0, 80) || 'export';
}
