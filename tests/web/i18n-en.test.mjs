// English interface (default language) and translation completeness (node --test).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { LANG, L, T, srv, tx, familyLabel, typeLabel, fmt } from '../../web/js/i18n.js';
import { configItems } from '../../web/js/ui/profile.js';
import { GAP_LABEL } from '../../web/js/ui/compare.js';

const root = fileURLToPath(new URL('../../', import.meta.url));
const read = (p) => readFileSync(root + p, 'utf8');

test('English is the default language', () => {
  assert.equal(LANG, 'en');
  assert.equal(L('Utilisateur', 'User'), 'User');
  assert.equal(T.kindLabel.user, 'User');
  assert.equal(T.kindLabel.group, 'Entra group');
  assert.equal(GAP_LABEL.onlyA, 'Only A');
  assert.equal(typeLabel('#microsoft.graph.win32LobApp'), 'Win32 app');
  assert.equal(fmt.ago(new Date().toISOString()), 'today');
});

test('every Intune family sent by the server has an English name', () => {
  const families = [...read('src/Config.ps1').matchAll(/Family\s*=\s*'((?:[^']|'')+)'/g)].map((m) => m[1].replace(/''/g, "'"));
  const fromCollectors = [...read('src/Collectors.ps1').matchAll(/\$family = '((?:[^']|'')+)'/g)].map((m) => m[1].replace(/''/g, "'"));
  const all = [...new Set([...families, ...fromCollectors, 'Appareils (fiches Utilisateur / Machine)', 'Groupes Entra'])];
  assert.ok(all.length >= 15);
  const missing = all.filter((f) => familyLabel(f) === f && !['Autopilot', 'Configuration'].includes(f));
  assert.deepEqual(missing, []);
});

test('every fixed error / status message of the server has an English translation', () => {
  const src = read('src/Server.ps1');
  const msgs = [
    ...[...src.matchAll(/Send-IalError \$C(?:ontext|tx) \d+ '((?:[^']|'')+)'/g)].map((m) => m[1].replace(/''/g, "'")),
    ...[...src.matchAll(/message = '((?:[^']|'')+)'/g)].map((m) => m[1].replace(/''/g, "'")),
    ...[...src.matchAll(/\$msg = (?:if \([^)]*\) \{ )?'((?:[^']|'')+)'/g)].map((m) => m[1].replace(/''/g, "'")),
    ...[...src.matchAll(/'((?:[^']|'')+)' \} else \{ '((?:[^']|'')+)' \}/g)].flatMap((m) => [m[1], m[2]].map((x) => x.replace(/''/g, "'"))),
  ];
  assert.ok(msgs.length >= 25, `messages found: ${msgs.length}`);
  const untranslated = [...new Set(msgs)].filter((m) => / /.test(m) && srv(m) === m);   // header values (no-store…) are not messages
  assert.deepEqual(untranslated, []);
});

test('server warnings, reasons and assignment labels are translated', () => {
  assert.equal(srv('Tous les utilisateurs'), 'All users');
  assert.equal(srv('SG-Finance (utilisateur)'), 'SG-Finance (user)');
  assert.equal(srv('Groupe (balise d\'étendue)'), 'Group (scope tag)');
  assert.equal(srv('Cible non prise en charge (inconnu)'), 'Unsupported target (unknown)');
  assert.equal(srv('Groupe supprimé (abc)'), 'Deleted group (abc)');
  assert.equal(srv("Groupes de l'utilisateur : Accès refusé (403) aux groupes de cet utilisateur."), "User's groups: Access denied (403) to this user's groups.");
  assert.equal(srv('PC-01 : Accès refusé (403) : la permission Device.Read.All est nécessaire pour les groupes des machines.'),
    'PC-01: Access denied (403): the Device.Read.All permission is needed for device groups.');
  assert.equal(srv('PC-01 : appareil non joint à Entra, ses groupes ne sont pas lisibles.'), 'PC-01: device not joined to Entra, its groups cannot be read.');
  assert.equal(srv('Permission DeviceManagementScripts.Read.All déjà présente dans le jeton : activable avec -EnableOptionalTypes deviceHealthScripts'),
    'Permission DeviceManagementScripts.Read.All already in the token: can be enabled with -EnableOptionalTypes deviceHealthScripts');
  assert.equal(srv('Un nom de groupe : sans rapport'), 'Un nom de groupe : sans rapport', 'unknown text is left as is');
  assert.equal(tx({ fr: 'Bonjour', en: 'Hello' }), 'Hello');
});

test('user page in English: devices, exclusions, via', () => {
  const view = {
    devices: [{ id: 'd1', name: 'PC-1', platform: 'Windows' }, { id: 'd2', name: 'PC-2', platform: 'Windows' }],
    configs: [
      { objectId: 'o1', name: 'Wi-Fi', family: 'Configuration (modèles)', targets: [
        { deviceId: 'd1', mode: 'include', via: ['G (utilisateur)'], exclVia: [] },
        { deviceId: 'd2', mode: 'exclude', via: ['G (utilisateur)'], exclVia: ['X (utilisateur)'] }] },
    ],
  };
  const [r] = configItems(view);
  assert.equal(r.viaText, 'G (user)');
  assert.match(r.exclText, /^Excluded on PC-2 \(X \(user\)\)$/);
  assert.equal(familyLabel(r.family), 'Configuration (templates)');
});
