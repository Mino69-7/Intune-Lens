// Barre du haut : aucun chevauchement, aucun débordement, pour toutes les largeurs de 320 à 2 560 px.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { computeChromeLayout, ROW_H } from '../../web/js/ui/chrome.js';

const SEG_W = 236;     // « Groupe Entra | Configuration » (mesuré dans Edge, ordre de grandeur)
const ACT_W = 128;     // 3 boutons ronds
const FULL_W = 470;    // « Données du 12/11 à 13:45 · 13 002 groupes · 2 115 éléments »
const SHORT_W = 140;   // « 12/11 13:45 »
const SEARCH_H = { home: 56, result: 44 };

function boxes(L) {
  const b = [];
  const add = (name, e, w, h) => { if (e && !e.hidden) b.push({ name, x: e.left, y: e.top, w, h }); };
  add('recherche', L.search, L.search.width, L.compact ? 44 : 56);
  add('selecteur', L.seg, SEG_W, ROW_H);
  add('etat', L.status, L.status.width, ROW_H);
  add('actions', L.actions, ACT_W, ROW_H);
  return b;
}
const overlap = (a, b) => a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;

for (const view of ['home', 'result']) {
  for (const [label, fullW] of [['texte long', FULL_W], ['texte très long', 900]]) {
    test(`${view} / ${label} : aucun chevauchement ni débordement de 320 à 2560 px`, () => {
      const problems = [];
      for (let W = 320; W <= 2560; W += 4) {
        for (const H of [560, 900]) {
          const L = computeChromeLayout({ W, H, view, segW: SEG_W, actW: ACT_W, fullW, shortW: SHORT_W, searchH: SEARCH_H[view] });
          const bx = boxes(L);
          for (let i = 0; i < bx.length; i++) {
            const a = bx[i];
            if (a.x < L.pad - 0.5 || a.x + a.w > W - L.pad + 0.5) problems.push(`W=${W} ${a.name} déborde (${a.x}..${a.x + a.w})`);
            if (a.w <= 0) problems.push(`W=${W} ${a.name} largeur nulle`);
            for (let j = i + 1; j < bx.length; j++) {
              if (overlap(a, bx[j])) problems.push(`W=${W} H=${H} ${a.name} chevauche ${bx[j].name}`);
            }
          }
          if (view === 'result') {
            // Le bas de la barre (chromeBottom) est sous tous les éléments : l'en-tête ne peut pas les recouvrir.
            for (const a of bx) if (a.y + a.h > L.chromeBottom + 0.5) problems.push(`W=${W} ${a.name} sous chromeBottom`);
          }
        }
      }
      assert.deepEqual(problems.slice(0, 10), []);
    });
  }
}

test('résultat, écran large : une seule ligne avec le texte complet', () => {
  const L = computeChromeLayout({ W: 1600, H: 900, view: 'result', segW: SEG_W, actW: ACT_W, fullW: FULL_W, shortW: SHORT_W });
  assert.equal(L.useFull, true);
  assert.equal(L.chromeBottom, L.pad + ROW_H);
  assert.ok(L.search.width >= 300);
});

test('résultat, écran moyen : une ligne avec le texte court plutôt que deux lignes', () => {
  const L = computeChromeLayout({ W: 1000, H: 900, view: 'result', segW: SEG_W, actW: ACT_W, fullW: FULL_W, shortW: SHORT_W });
  assert.equal(L.useFull, false);
  assert.equal(L.chromeBottom, L.pad + ROW_H);
});

test('résultat, écran étroit : deux lignes, recherche en pleine largeur', () => {
  const L = computeChromeLayout({ W: 600, H: 900, view: 'result', segW: SEG_W, actW: ACT_W, fullW: FULL_W, shortW: SHORT_W });
  assert.equal(L.search.width, 600 - 2 * L.pad);
  assert.ok(L.chromeBottom > L.pad + ROW_H);
});

test('accueil : la recherche est toujours 32 px sous le titre mesuré, quelle que soit sa position', () => {
  for (const heroBottom of [120, 300, 360, 520, 800]) {
    for (const W of [360, 800, 1400, 1920]) {
      const L = computeChromeLayout({ W, H: 951, view: 'home', segW: SEG_W, actW: ACT_W, fullW: FULL_W, shortW: SHORT_W, searchH: 56, heroBottom });
      assert.ok(L.search.top >= heroBottom + 32, `W=${W} heroBottom=${heroBottom} : recherche à ${L.search.top}`);
      assert.ok(L.search.top >= L.chromeBottom + 24, 'recherche sous la barre du haut');
      assert.ok(L.seg.top >= L.search.top + 56 + 16, 'sélecteur sous la recherche');
    }
  }
});

test('marges : 16 px sous 900 px, 24 px au-delà (grille de 8 px)', () => {
  assert.equal(computeChromeLayout({ W: 800, H: 900, view: 'home', segW: SEG_W, actW: ACT_W, fullW: FULL_W, shortW: SHORT_W }).pad, 16);
  assert.equal(computeChromeLayout({ W: 1200, H: 900, view: 'home', segW: SEG_W, actW: ACT_W, fullW: FULL_W, shortW: SHORT_W }).pad, 24);
});
