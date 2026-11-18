// Tests des liens de partage (node --test).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { shareLink, parseShareLink } from '../../web/js/ui/link.js';

const G = '0f8fad5b-d9cb-469f-a165-70867728950e';

test('lien de partage : type + identifiant, rien d\'autre', () => {
  assert.equal(shareLink('user', G), `intune-lens://user/${G}`);
  assert.equal(shareLink('nope', G), '');
  assert.equal(shareLink('user', ''), '');
});

test('lecture : lien seul, au milieu d\'un message, aller-retour', () => {
  for (const k of ['user', 'device', 'group', 'object']) assert.deepEqual(parseShareLink(shareLink(k, G)), { kind: k, id: G });
  assert.deepEqual(parseShareLink(`Regarde sa fiche : intune-lens://device/${G} merci`), { kind: 'device', id: G });
  assert.deepEqual(parseShareLink(`INTUNE-LENS://User/${G}`), { kind: 'user', id: G });
  assert.deepEqual(parseShareLink(shareLink('object', 'a b/c')), { kind: 'object', id: 'a b/c' });
});

test('lecture : adresse de l\'outil, texte ordinaire refusé', () => {
  assert.deepEqual(parseShareLink(`http://127.0.0.1:51234/#/group/${G}`), { kind: 'group', id: G });
  assert.equal(parseShareLink('camille demo'), null);
  assert.equal(parseShareLink(`https://example.com/#/user/${G}`), null);
  assert.equal(parseShareLink('intune-lens://admin/x'), null);
  assert.equal(parseShareLink(''), null);
  assert.equal(parseShareLink(null), null);
});
