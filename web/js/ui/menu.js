// menu.js : menu contextuel unique (#menu, verre flottant). Navigation au clavier, Échap pour fermer.

import { $, h, rectIn } from './dom.js';
import { markChanged } from '../glass.js';
import { L } from '../i18n.js';

let anchor = null;
let onDocDown = null;

export function isMenuOpen() { return !$('menu').hidden; }

export function closeMenu({ restoreFocus = true } = {}) {
  const m = $('menu');
  if (m.hidden) return;
  m.hidden = true;
  m.replaceChildren();
  if (anchor) {
    anchor.setAttribute('aria-expanded', 'false');
    if (restoreFocus) anchor.focus();
  }
  anchor = null;
  if (onDocDown) document.removeEventListener('pointerdown', onDocDown, true);
  onDocDown = null;
  markChanged();
}

/**
 * items : { type: 'item'|'sep'|'label'|'info', label, onSelect, checked, danger, disabled }
 */
export function openMenu(anchorEl, items, label) {
  if (anchor === anchorEl && isMenuOpen()) { closeMenu(); return; }
  closeMenu({ restoreFocus: false });
  const m = $('menu');
  const root = $('glass-root');
  anchor = anchorEl;
  m.setAttribute('aria-label', label);
  const buttons = [];
  for (const it of items) {
    if (it.type === 'sep') m.append(h('div', { class: 'menu-sep', role: 'separator' }));
    else if (it.type === 'label') m.append(h('div', { class: 'menu-label', role: 'presentation', text: it.label }));
    else if (it.type === 'info') m.append(h('div', { class: 'menu-info', role: 'presentation', text: it.label }));
    else if (it.type === 'state') {
      // Ligne d'état non cliquable : coche bleue à droite quand l'état est bon.
      m.append(h('div', {
        class: `menu-item menu-state${it.checked ? ' is-ok' : ''}`, role: 'presentation',
        'aria-label': `${it.label}${it.checked ? L(' : oui', ': yes') : ''}`, text: it.label,
      }));
    } else if (it.type === 'toggle') {
      // Interrupteur : bascule sur place, le menu reste ouvert.
      const sw = h('span', { class: 'switch', 'aria-hidden': 'true' }, [h('span', { class: 'switch-knob' })]);
      const b = h('button', {
        type: 'button', class: 'menu-item menu-toggle', role: 'menuitemcheckbox',
        'aria-checked': String(!!it.checked), tabindex: '-1',
      }, [h('span', { class: 'menu-toggle-label', text: it.label }), sw]);
      b.addEventListener('click', () => {
        const on = b.getAttribute('aria-checked') !== 'true';
        b.setAttribute('aria-checked', String(on));
        it.onSelect?.(on);
      });
      buttons.push(b);
      m.append(b);
    } else {
      const isCheck = typeof it.checked === 'boolean';
      const b = h('button', {
        type: 'button',
        class: `menu-item${it.danger ? ' danger' : ''}`,
        role: isCheck ? 'menuitemradio' : 'menuitem',
        'aria-checked': isCheck ? String(it.checked) : null,
        tabindex: '-1',
        disabled: it.disabled || null,
        text: it.label,
        on: { click: () => { closeMenu(); it.onSelect?.(); } },
      });
      buttons.push(b);
      m.append(b);
    }
  }
  m.onkeydown = (e) => {
    const i = buttons.indexOf(document.activeElement);
    if (e.key === 'ArrowDown') buttons[(i + 1) % buttons.length]?.focus();
    else if (e.key === 'ArrowUp') buttons[(i - 1 + buttons.length) % buttons.length]?.focus();
    else if (e.key === 'Home') buttons[0]?.focus();
    else if (e.key === 'End') buttons[buttons.length - 1]?.focus();
    else if (e.key === 'Escape') closeMenu();
    else if (e.key === 'Tab') { closeMenu({ restoreFocus: false }); return; }
    else return;
    e.preventDefault();
    e.stopPropagation();
  };
  m.hidden = false;
  anchorEl.setAttribute('aria-expanded', 'true');

  // Placement sous l'ancre, aligné à droite, contenu dans la fenêtre.
  const r = rectIn(anchorEl, root);
  const rootW = root.clientWidth;
  const w = m.offsetWidth;
  m.style.top = `${r.bottom + 8}px`;
  m.style.left = `${Math.max(16, Math.min(r.right - w, rootW - w - 16))}px`;
  buttons[0]?.focus();

  onDocDown = (e) => { if (!m.contains(e.target) && !anchorEl.contains(e.target)) closeMenu({ restoreFocus: false }); };
  document.addEventListener('pointerdown', onDocDown, true);
  markChanged();
}
