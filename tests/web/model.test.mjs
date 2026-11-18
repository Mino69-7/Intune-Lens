// Tests de la logique pure de l'interface (aucun DOM, aucun réseau).
// Exécution : node --test tests/web/
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  norm, buildGroupRows, buildObjectRows, familyCounts, toCsv, toTsv, groupExport, safeFileName, asArray,
} from '../../web/js/ui/model.js';
import { typeLabel, filterLabel } from '../../web/js/i18n.fr.js';

const view = {
  group: { id: 'g1', name: 'GRP-Test', exists: true },
  total: 4,
  items: [
    { objectId: 'o1', name: 'Wi-Fi Siège', family: 'Configuration (modèles)', odataType: '#microsoft.graph.windows10GeneralConfiguration', platform: 'Windows', mode: 'include', intent: null, filter: null },
    { objectId: 'o2', name: 'Œnologie app', family: 'Applications', odataType: '#microsoft.graph.win32LobApp', platform: 'Windows', mode: 'include', intent: 'required', filter: { id: 'f1', name: 'Filtre-Win', mode: 'include' } },
    { objectId: 'o3', name: 'Ancienne app', family: 'Applications', odataType: '#microsoft.graph.winGetApp', platform: 'Windows', mode: 'exclude', intent: 'required', filter: null },
    { objectId: 'o4', name: 'Conformité Windows', family: 'Conformité', odataType: '#microsoft.graph.windows10CompliancePolicy', platform: 'Windows', mode: 'include', intent: null, filter: null },
  ],
  global: [
    { objectId: 'o5', name: 'Antivirus global', family: 'Sécurité', target: 'allDevices', intent: null, filter: null, excludedForGroup: false },
    { objectId: 'o3', name: 'Ancienne app', family: 'Applications', target: 'allLicensedUsers', intent: 'available', filter: null, excludedForGroup: true },
  ],
};

const items = (rows) => rows.filter((r) => r.type === 'item');

test('norm : casse, accents, ligatures', () => {
  assert.equal(norm('Œnologie Élevée'), 'oenologie elevee');
  assert.equal(norm(null), '');
});

test('groupe : sections par famille triées, global replié par défaut', () => {
  const { rows, visible } = buildGroupRows(view, { collapsed: new Set(['global']) });
  const sections = rows.filter((r) => r.type === 'section').map((r) => r.label);
  assert.deepEqual(sections, ['Applications', 'Configuration (modèles)', 'Conformité', 'Assignations globales (indicatif)']);
  assert.equal(items(rows).length, 4, 'les règles globales repliées ne sont pas affichées');
  assert.equal(visible.length, 6, 'mais elles sont exportables');
});

test('groupe : global déplié affiche la note et met les exclusions en premier', () => {
  const { rows } = buildGroupRows(view, { collapsed: new Set() });
  const i = rows.findIndex((r) => r.key === 'global');
  assert.equal(rows[i + 1].type, 'note');
  assert.equal(rows[i + 2].modeKey, 'exclude');
  assert.equal(rows[i + 3].modeKey, 'potential');
});

test('groupe : filtre texte sans accents, statut, via, famille', () => {
  assert.deepEqual(items(buildGroupRows(view, { text: 'oenologie', collapsed: new Set() }).rows).map((r) => r.objectId), ['o2']);
  assert.deepEqual(items(buildGroupRows(view, { mode: 'exclude', collapsed: new Set() }).rows).map((r) => r.key), ['d:o3:exclude', 'g:o3:allLicensedUsers']);
  assert.equal(items(buildGroupRows(view, { via: 'direct', collapsed: new Set() }).rows).length, 4);
  assert.equal(items(buildGroupRows(view, { via: 'global', collapsed: new Set() }).rows).length, 2);
  assert.deepEqual(items(buildGroupRows(view, { families: new Set(['Conformité']), via: 'direct' }).rows).map((r) => r.objectId), ['o4']);
  assert.equal(buildGroupRows(view, { text: 'zzz' }).rows.length, 0);
});

test('groupe : section repliée masque ses lignes', () => {
  const { rows } = buildGroupRows(view, { collapsed: new Set(['fam:Applications', 'global']) });
  assert.equal(items(rows).filter((r) => r.family === 'Applications').length, 0);
});

test('synthèse par famille', () => {
  assert.deepEqual(familyCounts(view), [['Applications', 2], ['Configuration (modèles)', 1], ['Conformité', 1]]);
});

test('élément → groupes : globales, groupes, groupe supprimé', () => {
  const ov = {
    object: { id: 'o1' }, unassigned: false,
    assignments: [
      { target: 'allDevices', mode: 'include', intent: null, filter: null },
      { target: 'group', groupId: 'g1', groupName: 'GRP-A', groupExists: true, mode: 'include' },
      { target: 'group', groupId: 'gx', groupName: 'Groupe supprimé (gx)', groupExists: false, mode: 'exclude' },
    ],
  };
  const { rows } = buildObjectRows(ov);
  assert.equal(rows[0].name, 'Tous les appareils');
  assert.equal(rows[2].groupExists, false);
  assert.equal(buildObjectRows(ov, { mode: 'exclude' }).rows.length, 1);
});

test('asArray tolère null et objet seul (sérialisation PowerShell)', () => {
  assert.deepEqual(asArray(null), []);
  assert.deepEqual(asArray({ a: 1 }), [{ a: 1 }]);
});

test('CSV : BOM, séparateur ;, guillemets, neutralisation des formules', () => {
  const csv = toCsv(['A', 'B'], [['x;y', 'il dit "oui"'], ['=SOMME(1)', '-2']]);
  assert.ok(csv.startsWith('﻿A;B\r\n'));
  assert.ok(csv.includes('"x;y";"il dit ""oui"""'));
  assert.ok(csv.includes("'=SOMME(1);'-2"));
  assert.ok(csv.endsWith('\r\n'));
});

test('TSV : tabulations et retours ligne neutralisés', () => {
  assert.equal(toTsv(['A'], [['a\tb\nc']]), 'A\r\na b c');
});

test('export groupe : colonnes attendues', () => {
  const { visible } = buildGroupRows(view, { collapsed: new Set() });
  const { headers, rows } = groupExport(visible);
  assert.deepEqual(headers, ['Famille', 'Nom', 'Type', 'Statut', 'Via', 'Intent', 'Filtre', 'Plateforme', 'Identifiant']);
  const app = rows.find((r) => r[8] === 'o2');
  assert.deepEqual(app.slice(2, 7), ['Application Win32', 'Inclus', 'Groupe direct', 'Obligatoire', 'Filtre-Win (inclure)']);
});

test('libellés : type inconnu découpé, filtre', () => {
  assert.equal(typeLabel('#microsoft.graph.someNewPolicyType'), 'Some New Policy Type');
  assert.equal(filterLabel({ name: 'F', mode: 'exclude' }), 'F (exclure)');
});

test('nom de fichier sûr', () => {
  assert.equal(safeFileName('a<b>:c/d\\e|f?g*h'), 'a_b_c_d_e_f_g_h');
});
