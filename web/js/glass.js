// glass.js : gestion des effets de verre, 100 % CSS (décision de l'utilisateur, 2026-11-12).
//
// La librairie WebGL @ybouane/liquidglass a été essayée (spike M0) puis écartée : le rendu CSS « Léger »
// est préféré en thème clair comme en sombre. Plus aucun module externe n'est chargé.
//
// Modes (classe posée sur la racine) :
//   fx-light : verre CSS « Léger » (toujours) : flou modéré, saturation, liseré lumineux, ombre douce ;
//   fx-off   : surfaces opaques, UNIQUEMENT en contraste élevé Windows (accessibilité).
//
// Les fonctions markChanged / recapture / onContentScroll sont conservées (appelées par l'interface)
// mais n'ont plus rien à faire : le flou CSS (backdrop-filter) est toujours à jour.

let root = null;
let mode = 'light';
const listeners = new Set();

function forcedColors() {
  return matchMedia('(forced-colors: active)').matches;
}

function apply() {
  mode = forcedColors() ? 'off' : 'light';
  if (!root) return;
  root.classList.remove('fx-webgl', 'fx-css', 'fx-light', 'fx-off');
  root.classList.add(`fx-${mode}`);
  for (const fn of listeners) { try { fn(mode); } catch { /* écouteur fautif ignoré */ } }
}

/** @param {{ root: HTMLElement }} opts */
export function init(opts) {
  root = opts.root;
  matchMedia('(forced-colors: active)').addEventListener('change', apply);
  apply();
}

export function getMode() { return mode; }
export function onModeChange(fn) { listeners.add(fn); return () => listeners.delete(fn); }

// Sans effet en CSS pur (conservés pour l'interface).
export function markChanged() { }
export function recapture() { }
export function onContentScroll() { }
export function destroy() { }
