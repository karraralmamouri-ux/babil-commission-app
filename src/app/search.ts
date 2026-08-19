/**
 * البحث الشامل — صندوقٌ واحد في الترويسة.
 *
 * قبله كان الوصول إلى مشتركٍ يمرّ بشاشةٍ ثم مرشِّحٍ ثم صفحة. والمشغّل يعرف
 * الاسم لا الشاشة.
 *
 * الطلب مؤجَّل ومُلغى: كل ضغطة تُلغي طلب سابقتها، فلا يصل ردٌّ قديم بعد ردٍّ
 * جديد فيكتب نتائج حرفٍ مضى فوق نتائج ما كُتب الآن.
 */

import { rpc } from '../services/api';
import { esc } from '../components/ui';
import { href } from './router';

type Row = Record<string, unknown>;
const str = (r: Row, k: string) => String(r[k] ?? '');

const KIND_LABEL: Record<string, string> = {
  subscriber: 'مشترك',
  parent: 'أب',
  agent: 'وكيل',
  fdt: 'كابينة',
};

/** الأسماء اللاتينية تُعرض بمحاذاة لاتينية كي تُقرأ كما كُتبت. */
const LTR_KINDS = new Set(['subscriber', 'parent', 'fdt']);

let controller: AbortController | null = null;
let timer: number | undefined;

export function mountSearch(host: HTMLElement): void {
  if (host.dataset['mounted'] === 'true') return;
  host.dataset['mounted'] = 'true';

  host.innerHTML = `
    <div class="omni">
      <input id="omniInput" class="omni-input" type="search" autocomplete="off"
        placeholder="ابحث عن مشترك أو أب أو وكيل أو كابينة…"
        aria-label="بحث شامل" aria-expanded="false" aria-controls="omniResults">
      <div id="omniResults" class="omni-results" role="listbox" hidden></div>
    </div>`;

  const input = host.querySelector<HTMLInputElement>('#omniInput');
  const results = host.querySelector<HTMLElement>('#omniResults');
  if (!input || !results) return;

  const close = () => {
    results.hidden = true;
    results.innerHTML = '';
    input.setAttribute('aria-expanded', 'false');
  };

  const show = (html: string) => {
    results.innerHTML = html;
    results.hidden = false;
    input.setAttribute('aria-expanded', 'true');
  };

  const run = async (q: string) => {
    controller?.abort();
    const mine = new AbortController();
    controller = mine;

    if (q.trim().length < 2) { close(); return; }
    show('<div class="omni-note">جارٍ البحث…</div>');

    try {
      const doc = await rpc<Row>('global_search', { p_query: q, p_limit: 8 });
      // ردُّ طلبٍ ألغي لا يُكتب: المستخدم كتب حرفاً بعده.
      if (mine.signal.aborted || controller !== mine) return;

      if (doc?.['too_short'] === true) {
        show('<div class="omni-note">اكتب حرفين على الأقل</div>');
        return;
      }
      const rows = (doc?.['results'] || []) as Row[];
      if (!rows.length) {
        show(`<div class="omni-note">لا نتائج لـ«${esc(q)}»</div>`);
        return;
      }
      show(rows.map((r) => {
        const kind = str(r, 'kind');
        const ltr = LTR_KINDS.has(kind);
        return `<a class="omni-row" role="option" href="${esc(href(str(r, 'path')))}">
          <span class="omni-kind">${esc(KIND_LABEL[kind] || kind)}</span>
          <span class="omni-title"${ltr ? ' dir="ltr"' : ''}>${esc(str(r, 'title'))}</span>
          <span class="omni-sub"${ltr ? '' : ' dir="ltr"'}>${esc(str(r, 'subtitle'))}</span>
        </a>`;
      }).join(''));
    } catch {
      if (mine.signal.aborted || controller !== mine) return;
      show('<div class="omni-note">تعذّر البحث</div>');
    }
  };

  input.addEventListener('input', () => {
    window.clearTimeout(timer);
    const q = input.value;
    timer = window.setTimeout(() => void run(q), 220);
  });

  input.addEventListener('keydown', (e) => {
    const key = (e as KeyboardEvent).key;
    if (key === 'Escape') { close(); input.blur(); return; }
    if (key === 'ArrowDown') {
      const first = results.querySelector<HTMLAnchorElement>('.omni-row');
      if (first) { e.preventDefault(); first.focus(); }
    }
  });

  results.addEventListener('keydown', (e) => {
    const ev = e as KeyboardEvent;
    const rows = [...results.querySelectorAll<HTMLAnchorElement>('.omni-row')];
    const at = rows.indexOf(document.activeElement as HTMLAnchorElement);
    if (ev.key === 'ArrowDown' && at > -1 && rows[at + 1]) { ev.preventDefault(); rows[at + 1]?.focus(); }
    if (ev.key === 'ArrowUp') {
      ev.preventDefault();
      if (at > 0) rows[at - 1]?.focus(); else input.focus();
    }
    if (ev.key === 'Escape') { close(); input.focus(); }
  });

  // النقر خارج القائمة يُغلقها؛ والاختيار يُغلقها ويترك التنقّل للموجِّه.
  document.addEventListener('click', (e) => {
    if (!host.contains(e.target as Node)) close();
  });
  results.addEventListener('click', () => window.setTimeout(close, 0));

  // اختصار عالمي: Ctrl+K — ولا يسرق الكتابة من حقلٍ آخر.
  document.addEventListener('keydown', (e) => {
    const ev = e as KeyboardEvent;
    if ((ev.ctrlKey || ev.metaKey) && ev.key.toLowerCase() === 'k') {
      ev.preventDefault();
      input.focus();
      input.select();
    }
  });
}
