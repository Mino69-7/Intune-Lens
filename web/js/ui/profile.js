// profile.js : logique PURE (sans DOM) des fiches Utilisateur et Machine. Testée sous Node (tests/web/profile.test.mjs).
//
// Une fiche a trois onglets :
//   configs : éléments Intune qui ciblent l'utilisateur ou la machine, avec, pour chaque appareil, Inclus / Exclu ;
//   groups  : groupes Entra (transitifs), ceux utilisés dans Intune en premier, paginés par 20 ;
//   devices : appareils de l'utilisateur (fiche Utilisateur seulement).

import { asArray, norm, toCsv, toTsv } from './model.js';
import { T, typeLabel, filterLabel, intentLabel, fmt } from '../i18n.fr.js';

export const PAGE_SIZE = 20;
const collator = new Intl.Collator('fr-FR', { sensitivity: 'base', numeric: true });

const matches = (hay, q) => !q || q.split(/\s+/).filter(Boolean).every((t) => hay.includes(t));

/** Appareils d'une fiche (Utilisateur : tous ses appareils ; Machine : elle-même). */
export function profileDevices(view) {
  return view.device ? [view.device] : asArray(view.devices);
}

export const complianceLabel = (c) => T.compliance[c] || c || '—';

/** Libellé de portée du ciblage : par l'utilisateur, par l'appareil, ou les deux. */
export function scopeLabel(scope) {
  return scope === 'user' ? 'Utilisateur' : scope === 'device' ? 'Appareil' : scope === 'both' ? 'Utilisateur et appareil' : '—';
}

/**
 * Lignes « élément » enrichies : appareils concernés (nom, inactif), texte Via, statut.
 * Si opts.device est défini, la ligne ne garde que la cible de cet appareil.
 */
export function configItems(view, opts = {}) {
  const devs = new Map(profileDevices(view).map((d) => [d.id, d]));
  const out = [];
  for (const c of asArray(view.configs)) {
    let targets = asArray(c.targets).map((t) => {
      const d = t.deviceId ? devs.get(t.deviceId) : null;
      return { ...t, via: asArray(t.via), exclVia: asArray(t.exclVia), deviceName: d ? d.name : '', stale: !!(d && d.stale), platform: d ? d.platform : '' };
    });
    if (opts.device) targets = targets.filter((t) => t.deviceId === opts.device);
    if (!targets.length) continue;
    const included = targets.filter((t) => t.mode === 'include');
    const modeKey = included.length ? 'include' : 'exclude';
    const via = [...new Set((included.length ? included : targets).flatMap((t) => t.via))];
    const excl = [...new Set(targets.flatMap((t) => t.exclVia))];
    const excluded = targets.filter((t) => t.mode === 'exclude');
    const realExcl = [...new Set(excluded.flatMap((t) => t.exclVia))];
    // Exclusion d'un autre type que l'inclusion (utilisateur / appareil) : non prise en charge par Intune.
    const mixed = [...new Set(included.filter((t) => t.mixedExcl).flatMap((t) => t.exclVia))];
    const viaText = modeKey === 'exclude'
      ? `Exclu par ${excl.join(', ')}`
      : via.join(', ') + (mixed.length ? ` · exclusion non garantie : ${mixed.join(', ')}` : '');
    out.push({
      type: 'item',
      key: `c:${c.objectId}`,
      kind: 'config',
      objectId: c.objectId,
      name: c.name,
      family: c.family,
      platform: c.platform || '',
      odataType: c.odataType,
      typeLabel: typeLabel(c.odataType),
      modeKey,
      scope: c.scope,
      scopeText: scopeLabel(c.scope),
      viaText,
      exclText: excluded.length && modeKey === 'include' ? `Exclu sur ${excluded.map((t) => t.deviceName).filter(Boolean).join(', ')} (${realExcl.join(', ')})` : '',
      mixedExcl: mixed.length > 0,
      intentText: intentLabel(c.intent),
      filterText: filterLabel(c.filter),
      filter: c.filter || null,
      filtered: targets.some((t) => t.filtered),
      targets,
      allDevices: devs.size > 0 && included.length === devs.size,
      raw: c,
    });
  }
  return out;
}

/** Texte « Appareils » d'une ligne (pour l'export et la recherche). */
export function targetsText(row) {
  if (row.allDevices && row.targets.length > 1) return 'Tous ses appareils';
  return row.targets.map((t) => `${t.deviceName || 'Sans appareil'}${t.mode === 'exclude' ? ' (exclu)' : ''}`).join(', ');
}

/**
 * Onglet Configurations : sections par famille.
 * opts : { text, mode: ''|'include'|'exclude', device: ''|id, collapsed: Set }
 */
export function buildConfigRows(view, opts = {}) {
  const q = norm(opts.text || '').trim();
  const items = configItems(view, { device: opts.device || '' }).filter((r) =>
    (!opts.mode || r.modeKey === opts.mode) &&
    matches(norm([r.name, r.family, r.typeLabel, r.viaText, r.filterText, r.intentText, targetsText(r)].join(' ')), q));
  const byFam = new Map();
  for (const r of items) {
    if (!byFam.has(r.family)) byFam.set(r.family, []);
    byFam.get(r.family).push(r);
  }
  const rows = [];
  const visible = [];
  for (const fam of [...byFam.keys()].sort(collator.compare)) {
    const list = byFam.get(fam).sort((a, b) => collator.compare(a.name, b.name));
    const key = `fam:${fam}`;
    const expanded = !opts.collapsed?.has(key);
    const excl = list.filter((r) => r.modeKey === 'exclude').length;
    rows.push({
      type: 'section', key, label: fam, count: list.length, expanded,
      countText: fmt.plural(list.length, 'élément', 'éléments') + (excl ? ` · ${fmt.plural(excl, 'exclusion', 'exclusions')}` : ''),
    });
    if (expanded) rows.push(...list);
    visible.push(...list);
  }
  return { rows, visible };
}

/** Nombre de pages pour n éléments. */
export const pageCount = (n, size = PAGE_SIZE) => Math.max(1, Math.ceil(n / size));

/**
 * Numéros de page à afficher : 1 … p-1 p p+1 … N (null = points de suspension).
 * Toujours la première et la dernière ; au plus 7 entrées.
 */
export function pageList(page, pages) {
  if (pages <= 7) return Array.from({ length: pages }, (_, i) => i + 1);
  const set = new Set([1, pages, page, page - 1, page + 1]);
  if (page <= 3) [2, 3, 4].forEach((p) => set.add(p));
  if (page >= pages - 2) [pages - 1, pages - 2, pages - 3].forEach((p) => set.add(p));
  const list = [...set].filter((p) => p >= 1 && p <= pages).sort((a, b) => a - b);
  const out = [];
  for (let i = 0; i < list.length; i++) {
    if (i && list[i] - list[i - 1] > 1) out.push(null);
    out.push(list[i]);
  }
  return out;
}

/**
 * Onglet Groupes : filtre texte puis page de 20.
 * opts : { text, page } → { rows, visible (tous les groupes filtrés, pour l'export), page, pages, total }
 */
export function buildGroupListRows(view, opts = {}) {
  const q = norm(opts.text || '').trim();
  const all = asArray(view.groups)
    .map((g) => ({
      type: 'item', key: `g:${g.id}`, kind: 'group', groupId: g.id, name: g.name, used: g.used || 0,
      usedText: g.used ? fmt.plural(g.used, 'élément Intune', 'éléments Intune') : 'Non utilisé dans Intune',
      typeLabel: 'Groupe Entra', raw: g,
    }))
    .filter((r) => matches(norm(`${r.name} ${r.groupId}`), q));
  const pages = pageCount(all.length);
  const page = Math.min(Math.max(1, opts.page || 1), pages);
  const rows = all.slice((page - 1) * PAGE_SIZE, page * PAGE_SIZE);
  return { rows, visible: all, page, pages, total: all.length };
}

/** Onglet Appareils (fiche Utilisateur). */
export function buildDeviceRows(view, opts = {}) {
  const q = norm(opts.text || '').trim();
  const rows = asArray(view.devices)
    .map((d) => ({
      type: 'item', key: `d:${d.id}`, kind: 'device', deviceId: d.id, name: d.name,
      osText: [d.os, d.osVersion].filter(Boolean).join(' '), modelText: [d.maker, d.model].filter(Boolean).join(' '),
      syncText: fmt.ago(d.lastSync), complianceText: complianceLabel(d.compliance), stale: !!d.stale, raw: d,
    }))
    .filter((r) => matches(norm([r.name, r.osText, r.modelText, r.raw.serial].join(' ')), q));
  return { rows, visible: rows };
}

export function configExport(visible, withDevices) {
  const headers = ['Famille', 'Nom', 'Type', 'Statut', withDevices ? 'Appareils' : 'Ciblage', 'Via', 'Intent', 'Filtre', 'Plateforme', 'Identifiant'];
  const rows = visible.map((r) => [r.family, r.name, r.typeLabel, r.modeKey === 'exclude' ? 'Exclu' : 'Inclus',
    withDevices ? targetsText(r) : r.scopeText, r.viaText, r.intentText, r.filterText, r.platform, r.objectId]);
  return { headers, rows };
}
export function groupListExport(visible) {
  return { headers: ['Groupe', 'Utilisation dans Intune', 'Identifiant'], rows: visible.map((r) => [r.name, r.usedText, r.groupId]) };
}
export function deviceExport(visible) {
  return {
    headers: ['Appareil', 'Système', 'Modèle', 'Dernière synchro', 'Conformité', 'État', 'N° de série', 'Identifiant Intune'],
    rows: visible.map((r) => [r.name, r.osText, r.modelText, fmt.date(r.raw.lastSync), r.complianceText, r.stale ? 'Inactif' : 'Actif', r.raw.serial || '', r.deviceId]),
  };
}

export { toCsv, toTsv };
