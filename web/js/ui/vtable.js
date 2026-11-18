// vtable.js : tableau sémantique virtualisé (spec 7.3 : 60 lignes DOM maximum, fenêtre glissante).
// Rôles ARIA table/row/cell avec aria-rowcount et aria-rowindex ; navigation clavier complète.
//
// Lignes : { type: 'section' | 'item' | 'note', key, ... }
//   section : { label, count, expanded }   -> clic / Entrée = replier / déplier
//   note    : { text }
//   item    : données libres, rendues par columns[].render(row)

import { h, icon } from './dom.js';

const MAX_DOM_ROWS = 60;
const OVERSCAN = 6;

export class VTable {
  /**
   * @param {object} o
   * @param {HTMLElement} o.host      conteneur du tableau
   * @param {HTMLElement} o.scroller  élément qui défile (main#content)
   * @param {{key:string,label:string,width:string,render:(row:object)=>(Node|string)}[]} o.columns
   * @param {string} o.label          nom accessible du tableau
   * @param {(row:object)=>void} o.onActivate
   * @param {(row:object)=>void} o.onToggle
   */
  constructor(o) {
    this.o = o;
    this.rows = [];
    this.focusIndex = 0;
    this.range = [-1, -1];
    this.rowH = parseInt(getComputedStyle(document.documentElement).getPropertyValue('--row-h'), 10) || 48;

    this.el = h('div', { class: `vt surface${o.className ? ` ${o.className}` : ''}`, role: 'table', 'aria-label': o.label });
    this.el.style.setProperty('--vt-cols', o.columns.map((c) => c.width).join(' '));
    const head = h('div', { class: 'vt-head', role: 'row', 'aria-rowindex': '1' },
      o.columns.map((c) => h('div', { class: `cell ${c.key}`, role: 'columnheader', text: c.label })));
    this.body = h('div', { class: 'vt-body', role: 'rowgroup' });
    this.el.append(h('div', { role: 'rowgroup' }, head), this.body);
    o.host.replaceChildren(this.el);

    this.onScroll = () => this.schedule();
    o.scroller.addEventListener('scroll', this.onScroll, { passive: true });
    this.ro = new ResizeObserver(() => this.schedule());
    this.ro.observe(o.scroller);
    this.body.addEventListener('keydown', (e) => this.onKey(e));
    this.body.addEventListener('click', (e) => {
      const r = e.target.closest('.vt-row');
      if (!r || e.target.closest('button, a')) return;
      this.focusIndex = Number(r.dataset.index);
      this.activate(this.rows[this.focusIndex]);
    });
  }

  setRows(rows, { keepFocus = false } = {}) {
    this.rows = rows;
    if (!keepFocus || this.focusIndex >= rows.length) this.focusIndex = 0;
    this.el.setAttribute('aria-rowcount', String(rows.length + 1));
    this.body.style.height = `${rows.length * this.rowH}px`;
    this.range = [-1, -1];
    this.render();
  }

  schedule() {
    if (this.pending) return;
    this.pending = true;
    requestAnimationFrame(() => { this.pending = false; this.render(); });
  }

  bodyTop() {
    const s = this.o.scroller;
    return this.body.getBoundingClientRect().top - s.getBoundingClientRect().top + s.scrollTop;
  }

  render() {
    const s = this.o.scroller;
    const n = this.rows.length;
    const top = s.scrollTop - this.bodyTop();
    let first = Math.max(0, Math.floor(top / this.rowH) - OVERSCAN);
    const visible = Math.ceil(s.clientHeight / this.rowH) + OVERSCAN * 2;
    let last = Math.min(n - 1, first + Math.min(visible, MAX_DOM_ROWS) - 1);
    // La ligne active reste dans le DOM pour conserver le focus clavier.
    if (this.focusIndex < first || this.focusIndex > last) {
      if (this.body.contains(document.activeElement)) {
        first = Math.max(0, Math.min(first, this.focusIndex));
        last = Math.min(n - 1, Math.max(last, this.focusIndex), first + MAX_DOM_ROWS - 1);
      }
    }
    if (first === this.range[0] && last === this.range[1] && !this.dirty) return;
    this.range = [first, last];
    this.dirty = false;

    const hadFocus = this.body.contains(document.activeElement);
    const frag = document.createDocumentFragment();
    for (let i = first; i <= last; i++) frag.append(this.renderRow(this.rows[i], i));
    this.body.replaceChildren(frag);
    if (hadFocus) {
      const f = this.body.querySelector(`[data-index="${this.focusIndex}"]`);
      if (f) f.focus({ preventScroll: true });
    }
  }

  renderRow(row, i) {
    const extra = row.type === 'item' && this.o.rowClass ? ` ${this.o.rowClass(row) || ''}` : '';
    const attrs = {
      class: `vt-row ${row.type}${extra}`,
      role: 'row',
      'aria-rowindex': String(i + 2),
      tabindex: i === this.focusIndex ? '0' : '-1',
      dataset: { index: String(i) },
    };
    let el;
    if (row.type === 'section') {
      el = h('div', { ...attrs, 'aria-expanded': row.expanded ? 'true' : 'false' }, [
        h('div', { class: 'cell', role: 'cell', 'aria-colspan': String(this.o.columns.length) }, [
          h('span', { class: 'sec' }, [icon('chevron', 'icon chev'), row.label, h('span', { class: 'muted num', text: `· ${row.countText}` })]),
        ]),
      ]);
    } else if (row.type === 'note') {
      el = h('div', attrs, [h('div', { class: 'cell', role: 'cell', 'aria-colspan': String(this.o.columns.length), text: row.text })]);
    } else {
      el = h('div', attrs, this.o.columns.map((c) => {
        const v = c.render(row);
        return h('div', { class: `cell ${c.key}`, role: 'cell', title: typeof v === 'string' ? v : null }, [v]);
      }));
    }
    el.style.transform = `translateY(${i * this.rowH}px)`;
    return el;
  }

  activate(row) {
    if (!row) return;
    if (row.type === 'section') this.o.onToggle?.(row);
    else if (row.type === 'item') this.o.onActivate?.(row);
  }

  focusRow(i) {
    const n = this.rows.length;
    if (!n) return;
    this.focusIndex = Math.max(0, Math.min(n - 1, i));
    const s = this.o.scroller;
    const y = this.bodyTop() + this.focusIndex * this.rowH;
    const pad = parseInt(getComputedStyle(s).scrollPaddingTop, 10) || 0;
    if (y < s.scrollTop + pad) s.scrollTop = y - pad;
    else if (y + this.rowH > s.scrollTop + s.clientHeight) s.scrollTop = y + this.rowH - s.clientHeight;
    this.dirty = true;
    this.render();
    const f = this.body.querySelector(`[data-index="${this.focusIndex}"]`);
    if (f) f.focus({ preventScroll: true });
  }

  focusFirst() { this.focusRow(this.focusIndex || 0); }

  onKey(e) {
    const page = Math.max(1, Math.floor(this.o.scroller.clientHeight / this.rowH) - 1);
    const k = e.key;
    if (k === 'ArrowDown') this.focusRow(this.focusIndex + 1);
    else if (k === 'ArrowUp') this.focusRow(this.focusIndex - 1);
    else if (k === 'PageDown') this.focusRow(this.focusIndex + page);
    else if (k === 'PageUp') this.focusRow(this.focusIndex - page);
    else if (k === 'Home') this.focusRow(0);
    else if (k === 'End') this.focusRow(this.rows.length - 1);
    else if (k === 'Enter' || k === ' ') this.activate(this.rows[this.focusIndex]);
    else if (k === 'ArrowLeft' && this.rows[this.focusIndex]?.type === 'section' && this.rows[this.focusIndex].expanded) this.activate(this.rows[this.focusIndex]);
    else if (k === 'ArrowRight' && this.rows[this.focusIndex]?.type === 'section' && !this.rows[this.focusIndex].expanded) this.activate(this.rows[this.focusIndex]);
    else return;
    e.preventDefault();
    e.stopPropagation();
  }

  destroy() {
    this.o.scroller.removeEventListener('scroll', this.onScroll);
    this.ro.disconnect();
    this.o.host.replaceChildren();
  }
}
