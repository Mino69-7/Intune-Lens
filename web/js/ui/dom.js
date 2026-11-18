// dom.js : petits utilitaires DOM. Le texte passe TOUJOURS par textContent (jamais d'HTML issu des données).

export const $ = (id) => document.getElementById(id);

/**
 * Crée un élément. attrs : { class, text, dataset, on: { click: fn }, ...attributs }.
 * children : éléments ou chaînes (insérées comme texte).
 */
export function h(tag, attrs = {}, children = []) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v === undefined || v === null || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k === 'text') el.textContent = v;
    else if (k === 'dataset') Object.assign(el.dataset, v);
    else if (k === 'on') for (const [ev, fn] of Object.entries(v)) el.addEventListener(ev, fn);
    else if (v === true) el.setAttribute(k, '');
    else el.setAttribute(k, String(v));
  }
  for (const c of [].concat(children)) {
    if (c === null || c === undefined || c === false) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}

const SVG_NS = 'http://www.w3.org/2000/svg';
/** Icônes vectorielles locales (chemins statiques, aucune donnée externe). */
const ICONS = {
  check: ['M5 12.5l4.5 4.5L19 7.5'],
  minus: ['M6 12h12'],
  ban: ['M5.6 5.6l12.8 12.8', 'circle:12,12,8.5'],
  chevron: ['M6 9l6 6 6-6'],
  copy: ['M9 9h10v10H9z', 'M5 15V5h10'],
  users: ['circle:9,8,3.5', 'M2.5 19c.8-3.4 3.4-5 6.5-5s5.7 1.6 6.5 5', 'M16 4.5a3.5 3.5 0 0 1 0 7', 'M18 14c2 .6 3.2 2.3 3.5 5'],
  device: ['M4 5h16v11H4z', 'M9 19.5h6', 'M12 16v3.5'],
  group: ['circle:12,8,3.5', 'M5 19.5c1-3.6 3.8-5.5 7-5.5s6 1.9 7 5.5'],
  info: ['circle:12,12,8.5', 'M12 11v5', 'M12 8h.01'],
  swap: ['M4 8h15', 'M15 4l4 4-4 4', 'M20 16H5', 'M9 12l-4 4 4 4'],
  person: ['circle:12,8,3.6', 'M5 20c.9-3.8 3.7-6 7-6s6.1 2.2 7 6'],
  wrench: ['M14.7 6.3a4 4 0 0 0-5.4 5.4L4 17l3 3 5.3-5.3a4 4 0 0 0 5.4-5.4l-2.5 2.5-2.4-.6-.6-2.4z'],
  laptop: ['M5 6h14v9H5z', 'M3 18h18'],
  phone: ['M8 3h8v18H8z', 'M11 18h2'],
  chevronLeft: ['M15 6l-6 6 6 6'],
  chevronRight: ['M9 6l6 6-6 6'],
};

export function icon(name, cls = 'icon') {
  const svg = document.createElementNS(SVG_NS, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('class', cls);
  svg.setAttribute('aria-hidden', 'true');
  for (const d of ICONS[name] || []) {
    if (d.startsWith('circle:')) {
      const [cx, cy, r] = d.slice(7).split(',');
      const c = document.createElementNS(SVG_NS, 'circle');
      c.setAttribute('cx', cx); c.setAttribute('cy', cy); c.setAttribute('r', r);
      svg.append(c);
    } else {
      const p = document.createElementNS(SVG_NS, 'path');
      p.setAttribute('d', d);
      svg.append(p);
    }
  }
  return svg;
}

let toastTimer = 0;
export function toast(message) {
  const t = $('toast');
  t.textContent = message;
  t.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.remove('show'), 2600);
}

export async function copyText(text, okMessage = 'Copié dans le presse-papiers') {
  try {
    await navigator.clipboard.writeText(text);
    toast(okMessage);
  } catch {
    toast('Copie impossible : le navigateur a refusé l’accès au presse-papiers.');
  }
}

/** Télécharge un texte comme fichier (Blob local, aucune requête réseau). */
export function downloadText(filename, text, mime) {
  const blob = new Blob([text], { type: mime });
  const url = URL.createObjectURL(blob);
  const a = h('a', { href: url, download: filename });
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export function debounce(fn, ms) {
  let t = 0;
  return (...args) => { clearTimeout(t); t = setTimeout(() => fn(...args), ms); };
}

/** Position d'un élément relative à la racine du verre. */
export function rectIn(el, root) {
  const a = el.getBoundingClientRect();
  const b = root.getBoundingClientRect();
  return { left: a.left - b.left, top: a.top - b.top, right: a.right - b.left, bottom: a.bottom - b.top, width: a.width, height: a.height };
}
