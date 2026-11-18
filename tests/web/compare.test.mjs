// Comparaison de deux groupes / deux éléments : alignement, écarts, filtres, export.
import './lang-fr.mjs';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { compareGroups, compareObjects, compareCounts, buildCompareRows, compareExport } from '../../web/js/ui/compare.js';

const item = (objectId, name, family, mode = 'include', extra = {}) => ({ objectId, name, family, odataType: '#microsoft.graph.win32LobApp', platform: 'Windows', mode, intent: null, filter: null, via: 'Groupe direct', ...extra });

const A = {
  group: { id: 'A', name: 'Groupe A' },
  items: [
    item('o1', 'Wi-Fi', 'Configuration (modèles)'),
    item('o2', '7-Zip', 'Applications', 'include', { intent: 'required' }),
    item('o3', 'BitLocker', 'Conformité'),
    item('o4', 'Teams', 'Applications', 'include', { intent: 'available' }),
  ],
  global: [
    { objectId: 'g1', name: 'Antivirus', family: 'Sécurité', target: 'allDevices', excludedForGroup: true },
    { objectId: 'g2', name: 'Défaut', family: 'Configuration (modèles)', target: 'allLicensedUsers', excludedForGroup: false },
  ],
};
const B = {
  group: { id: 'B', name: 'Groupe B' },
  items: [
    item('o1', 'Wi-Fi', 'Configuration (modèles)'),                                  // identique
    item('o2', '7-Zip', 'Applications', 'exclude', { intent: 'required' }),            // différent (statut)
    item('o4', 'Teams', 'Applications', 'include', { intent: 'required' }),            // différent (intent)
    item('o5', 'Edge', 'Applications', 'include', { filter: { id: 'f1', name: 'Filtre-Win', mode: 'include' } }), // seulement B
  ],
  global: [
    { objectId: 'g1', name: 'Antivirus', family: 'Sécurité', target: 'allDevices', excludedForGroup: false },
    { objectId: 'g2', name: 'Défaut', family: 'Configuration (modèles)', target: 'allLicensedUsers', excludedForGroup: false },
  ],
};

const byKey = (rows) => Object.fromEntries(rows.map((r) => [r.key, r]));

test('groupes : alignement et classement des écarts', () => {
  const rows = compareGroups(A, B);
  const k = byKey(rows);
  assert.equal(k['o:o1'].gap, 'same');
  assert.equal(k['o:o2'].gap, 'diff', 'Inclus dans A, Exclu dans B');
  assert.equal(k['o:o4'].gap, 'diff', 'intent différent');
  assert.equal(k['o:o3'].gap, 'onlyA');
  assert.equal(k['o:o5'].gap, 'onlyB');
  assert.equal(k['x:g1:allDevices'].gap, 'onlyA', 'exclusion de A sur une règle globale');
  assert.equal(k['x:g2:allLicensedUsers'], undefined, 'règles globales non exclues : jamais comparées');
  assert.deepEqual(compareCounts(rows), { all: 6, gaps: 5, same: 1, diff: 2, onlyA: 2, onlyB: 1 });
});

test('groupes : filtre « Écarts », « Seulement B », recherche sans accents', () => {
  const rows = compareGroups(A, B);
  const items = (o) => buildCompareRows(rows, o).rows.filter((r) => r.type === 'item').map((r) => r.key).sort();
  assert.deepEqual(items({ show: 'gaps' }), ['o:o2', 'o:o3', 'o:o4', 'o:o5', 'x:g1:allDevices']);
  assert.deepEqual(items({ show: 'onlyB' }), ['o:o5']);
  assert.deepEqual(items({ show: 'same' }), ['o:o1']);
  assert.deepEqual(items({ text: 'wi-fi' }), ['o:o1']);
  assert.deepEqual(items({ text: 'BITLOCKER' }), ['o:o3']);
});

test('groupes : sections, écarts en premier, exclusions globales en dernier', () => {
  const { rows } = buildCompareRows(compareGroups(A, B), {});
  const sections = rows.filter((r) => r.type === 'section').map((r) => r.label);
  assert.equal(sections[sections.length - 1], 'Exclusions sur règles globales');
  const apps = rows.slice(rows.findIndex((r) => r.label === 'Applications') + 1).filter((r) => r.type === 'item' && r.family === 'Applications');
  assert.deepEqual(apps.map((r) => r.gap), ['diff', 'diff', 'onlyB']);
});

test('éléments : comparaison des cibles (groupes, cibles globales)', () => {
  const oa = { object: { id: 'x' }, assignments: [
    { target: 'allDevices', mode: 'include' },
    { target: 'group', groupId: 'g1', groupName: 'GRP-1', mode: 'include' },
    { target: 'group', groupId: 'g2', groupName: 'GRP-2', mode: 'exclude' },
  ] };
  const ob = { object: { id: 'y' }, assignments: [
    { target: 'group', groupId: 'g1', groupName: 'GRP-1', mode: 'include', filter: { id: 'f', name: 'F', mode: 'exclude' } },
    { target: 'group', groupId: 'g3', groupName: 'GRP-3', mode: 'include' },
  ] };
  const k = byKey(compareObjects(oa, ob));
  assert.equal(k['t:allDevices'].gap, 'onlyA');
  assert.equal(k['g:g1'].gap, 'diff', 'filtre différent');
  assert.equal(k['g:g2'].gap, 'onlyA');
  assert.equal(k['g:g3'].gap, 'onlyB');
  const { rows } = buildCompareRows(compareObjects(oa, ob), {});
  assert.equal(rows[0].label, 'Cibles globales');
});

test('export CSV de la comparaison', () => {
  const { visible } = buildCompareRows(compareGroups(A, B), {});
  const { headers, rows } = compareExport(visible, 'Groupe A', 'Groupe B');
  assert.equal(headers[3], 'Statut A (Groupe A)');
  const z = rows.find((r) => r[1] === '7-Zip');
  assert.deepEqual(z.slice(3), ['Inclus', 'Obligatoire', 'Exclu', 'Obligatoire', 'Différent']);
  const e = rows.find((r) => r[1] === 'Edge');
  assert.deepEqual(e.slice(3), ['Absent', '', 'Inclus', 'Filtre-Win (inclure)', 'Seulement B']);
});

test('deux groupes identiques : aucun écart', () => {
  const rows = compareGroups(A, A);
  assert.equal(compareCounts(rows).gaps, 0);
  assert.equal(buildCompareRows(rows, { show: 'gaps' }).rows.length, 0);
});
