// chrome.js : calcul PUR (sans DOM) du placement de la barre du haut. Testé sous Node pour toutes les
// largeurs (tests/web/chrome.test.mjs) : aucun chevauchement, aucun débordement, grille de 8 px.

export const ROW_H = 44;         // hauteur des commandes de la barre du haut
export const GAP = 12;           // espacement entre commandes
export const MIN_SEARCH = 300;   // largeur minimale de la recherche sur une ligne partagée
export const MIN_STATUS = 96;    // largeur minimale de la pastille d'état (texte tronqué au-delà)

/**
 * @param {object} m mesures : { W, H, view: 'home'|'result', segW, actW, fullW, shortW, searchH }
 * @returns {{ search, seg, status, actions, useFull: boolean, chromeBottom: number, searchTop?: number, compact: boolean }}
 *          chaque élément : { left, top, width?, hidden? }
 */
export function computeChromeLayout(m) {
  const { W, H, view, segW, actW, fullW, shortW } = m;
  const pad = W >= 900 ? 24 : 16;
  const out = { pad, compact: view === 'result' };

  if (view !== 'result') {
    const maxSt = Math.max(MIN_STATUS, W - 2 * pad - actW - GAP);
    const useFull = fullW <= maxSt;
    const stW = Math.min(useFull ? fullW : shortW, maxSt);
    const sw = Math.min(640, W - 2 * pad);
    const searchH = m.searchH || 56;
    // Sous le titre mesuré (heroBottom) + 32, et toujours sous la barre du haut + 24.
    const floor = pad + ROW_H + 24;
    const searchTop = Math.round(m.heroBottom !== undefined ? Math.max(floor, m.heroBottom + 32) : Math.max(floor + 132, H * 0.36));
    out.actions = { left: W - pad - actW, top: pad };
    out.status = { left: W - pad - actW - GAP - stW, top: pad, width: stW };
    out.search = { left: (W - sw) / 2, top: searchTop, width: sw };
    out.seg = { left: (W - segW) / 2, top: searchTop + searchH + 16 };
    out.useFull = useFull;
    out.searchTop = searchTop;
    out.chromeBottom = pad + ROW_H;
    return out;
  }

  const searchLeft = pad + segW + GAP;
  const rightOf = (stW) => W - pad - actW - GAP - stW - GAP;
  let useFull = null;
  if (rightOf(fullW) - searchLeft >= MIN_SEARCH) useFull = true;
  else if (rightOf(shortW) - searchLeft >= MIN_SEARCH) useFull = false;

  if (useFull !== null) {
    const stW = useFull ? fullW : shortW;
    out.seg = { left: pad, top: pad };
    out.actions = { left: W - pad - actW, top: pad };
    out.status = { left: W - pad - actW - GAP - stW, top: pad, width: stW };
    out.search = { left: searchLeft, top: pad, width: Math.min(560, rightOf(stW) - searchLeft) };
    out.useFull = useFull;
    out.chromeBottom = pad + ROW_H;
    return out;
  }

  // Deux lignes
  const y2 = pad + ROW_H + GAP;
  out.search = { left: pad, top: pad, width: W - 2 * pad };
  out.actions = { left: W - pad - actW, top: y2 };
  let left = pad + segW + GAP;
  let maxSt = W - pad - actW - GAP - left;
  if (maxSt < 140) {
    out.seg = { left: pad, top: y2, hidden: true };
    left = pad;
    maxSt = W - pad - actW - GAP - left;
  } else {
    out.seg = { left: pad, top: y2 };
  }
  maxSt = Math.max(MIN_STATUS, maxSt);
  const useFull2 = fullW <= maxSt;
  const stW = Math.min(useFull2 ? fullW : shortW, maxSt);
  out.status = { left: W - pad - actW - GAP - stW, top: y2, width: stW };
  out.useFull = useFull2;
  out.chromeBottom = y2 + ROW_H;
  return out;
}
