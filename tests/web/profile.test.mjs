// Tests de la logique pure des fiches Utilisateur / Machine (node --test).
import './lang-fr.mjs';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  configItems, buildConfigRows, buildGroupListRows, buildDeviceRows, pageList, pageCount, targetsText, configExport, PAGE_SIZE,
} from '../../web/js/ui/profile.js';
import { compareProfiles, compareCounts, buildCompareRows } from '../../web/js/ui/compare.js';

const userView = {
  user: { id: 'u1', name: 'Camille', upn: 'camille@x' },
  devices: [
    { id: 'd1', name: 'PC-1', platform: 'Windows', stale: false, os: 'Windows', osVersion: '11', lastSync: new Date().toISOString(), compliance: 'compliant' },
    { id: 'd2', name: 'PC-OLD', platform: 'Windows', stale: true, os: 'Windows', osVersion: '10', lastSync: '2020-01-01T00:00:00Z', compliance: 'noncompliant' },
  ],
  groups: Array.from({ length: 45 }, (_, i) => ({ id: `g${i}`, name: `Groupe ${String(i).padStart(2, '0')}`, used: i < 5 ? 3 : 0 })),
  configs: [
    { objectId: 'o1', name: 'Wi-Fi', family: 'Configuration', mode: 'include', scope: 'user', targets: [{ deviceId: 'd1', mode: 'include', via: ['G (utilisateur)'], exclVia: [] }, { deviceId: 'd2', mode: 'include', via: ['G (utilisateur)'], exclVia: [] }] },
    { objectId: 'o2', name: 'BitLocker', family: 'Configuration', mode: 'include', scope: 'device', targets: [{ deviceId: 'd1', mode: 'include', via: ['D (appareil)'], exclVia: [] }] },
    { objectId: 'o3', name: '7-Zip', family: 'Applications', mode: 'exclude', scope: 'none', intent: 'required', targets: [{ deviceId: 'd1', mode: 'exclude', via: ['G (utilisateur)'], exclVia: ['X (appareil)'] }] },
  ],
  warnings: [],
};

test('éléments : tous ses appareils, un seul appareil, exclusion', () => {
  const items = configItems(userView);
  const by = Object.fromEntries(items.map((r) => [r.objectId, r]));
  assert.equal(by.o1.allDevices, true);
  assert.equal(targetsText(by.o1), 'Tous ses appareils');
  assert.equal(by.o2.allDevices, false);
  assert.equal(targetsText(by.o2), 'PC-1');
  assert.equal(by.o3.modeKey, 'exclude');
  assert.match(by.o3.viaText, /^Exclu par X/);
  assert.equal(by.o1.targets[1].stale, true);
});

test('exclusion de l\'autre type (utilisateur / appareil) : inclus, signalé « non garantie »', () => {
  const v = { ...userView, configs: [{ objectId: 'm1', name: 'Mix', family: 'Configuration', mode: 'include', scope: 'user',
    targets: [{ deviceId: 'd1', mode: 'include', via: ['G (utilisateur)'], exclVia: ['X (appareil)'], mixedExcl: true }] }] };
  const [r] = configItems(v);
  assert.equal(r.modeKey, 'include');
  assert.equal(r.mixedExcl, true);
  assert.match(r.viaText, /exclusion non garantie : X \(appareil\)/);
  assert.equal(r.exclText, '');
});

test('filtre par appareil : seule la cible de cet appareil compte', () => {
  const items = configItems(userView, { device: 'd2' });
  assert.deepEqual(items.map((r) => r.objectId), ['o1']);
});

test('onglet Configurations : sections par famille, filtre statut', () => {
  const { rows, visible } = buildConfigRows(userView, { text: '', mode: '', device: '', collapsed: new Set() });
  assert.equal(visible.length, 3);
  assert.deepEqual(rows.filter((r) => r.type === 'section').map((r) => r.label), ['Applications', 'Configuration']);
  assert.equal(buildConfigRows(userView, { mode: 'exclude' }).visible.length, 1);
  assert.equal(buildConfigRows(userView, { text: 'bitlo' }).visible[0].objectId, 'o2');
});

test('onglet Groupes : 20 par page, filtre avant pagination', () => {
  const p1 = buildGroupListRows(userView, { page: 1 });
  assert.equal(PAGE_SIZE, 20);
  assert.equal(p1.rows.length, 20);
  assert.equal(p1.pages, 3);
  assert.equal(p1.total, 45);
  const p3 = buildGroupListRows(userView, { page: 3 });
  assert.equal(p3.rows.length, 5);
  assert.equal(buildGroupListRows(userView, { page: 99 }).page, 3);
  const f = buildGroupListRows(userView, { text: 'groupe 4', page: 2 });
  assert.equal(f.page, 1);
  assert.equal(f.total, 9);   // 04, 14, 24, 34, 40..44
  assert.equal(p1.visible.length, 45, 'export : tous les groupes filtrés, pas seulement la page');
});

test('numéros de page : premier, dernier, voisins, points de suspension', () => {
  assert.deepEqual(pageList(1, 3), [1, 2, 3]);
  assert.deepEqual(pageList(1, 10), [1, 2, 3, 4, null, 10]);
  assert.deepEqual(pageList(5, 10), [1, null, 4, 5, 6, null, 10]);
  assert.deepEqual(pageList(10, 10), [1, null, 7, 8, 9, 10]);
  assert.equal(pageCount(0), 1);
  assert.equal(pageCount(41), 3);
});

test('onglet Appareils et export', () => {
  const { rows } = buildDeviceRows(userView, {});
  assert.equal(rows.length, 2);
  assert.equal(rows[1].stale, true);
  assert.equal(rows[0].complianceText, 'Conforme');
  const ex = configExport(configItems(userView), true);
  assert.ok(ex.headers.includes('Appareils'));
  assert.equal(ex.rows.find((r) => r[1] === 'Wi-Fi')[4], 'Tous ses appareils');
});

test('comparaison de deux utilisateurs : éléments et groupes', () => {
  const other = {
    user: { id: 'u2', name: 'Alex' }, devices: [], warnings: [],
    groups: [{ id: 'g0', name: 'Groupe 00', used: 3 }, { id: 'zz', name: 'Autre', used: 0 }],
    configs: [
      { objectId: 'o1', name: 'Wi-Fi', family: 'Configuration', mode: 'include', targets: [{ deviceId: null, mode: 'include', via: ['G (utilisateur)'], exclVia: [] }] },
      { objectId: 'o3', name: '7-Zip', family: 'Applications', mode: 'include', intent: 'required', targets: [{ deviceId: null, mode: 'include', via: ['G (utilisateur)'], exclVia: [] }] },
    ],
  };
  const rows = compareProfiles(userView, other);
  const by = Object.fromEntries(rows.map((r) => [r.key, r]));
  assert.equal(by['o:o1'].gap, 'same');
  assert.equal(by['o:o2'].gap, 'onlyA');
  assert.equal(by['o:o3'].gap, 'diff');
  assert.equal(by['g:g0'].gap, 'same');
  assert.equal(by['g:zz'].gap, 'onlyB');
  assert.equal(by['g:g0'].a.mode, 'member');
  const c = compareCounts(rows);
  assert.equal(c.all, 3 + 46);
  const { rows: out } = buildCompareRows(rows, { show: 'gaps' });
  assert.equal(out.filter((r) => r.type === 'section').at(-1).label, 'Groupes Entra', 'les groupes en dernier');
});
