/**
 * لبنات العرض المشتركة.
 *
 * لا تحسب مالاً ولا تتّصل بالشبكة. تُصاغ نصّاً وتُدرَج، فالأنماط تأتي من
 * babil-flow.css كما هي — لا إعادة تصميم.
 */

import { href } from '../app/router';

export function esc(value: unknown): string {
  return String(value ?? '')
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

/* ---- الحالات ------------------------------------------------------------
   لكل شاشة أربع حالات صريحة. الفراغ غير الموصوف يُقرأ عطلاً. */

export function loading(label = 'جارٍ التحميل…'): string {
  return `<div class="loading-state" role="status" aria-live="polite">
    <div><div class="spinner"></div><p class="muted">${esc(label)}</p></div></div>`;
}

export function empty(title: string, hint = ''): string {
  return `<div class="empty-state"><div>
    <div style="font-size:34px" aria-hidden="true">◎</div>
    <h2>${esc(title)}</h2>${hint ? `<p class="muted">${esc(hint)}</p>` : ''}</div></div>`;
}

export function errorState(message: string, retry?: string): string {
  return `<div class="error-state" role="alert"><div>
    <div style="font-size:34px" aria-hidden="true">⚠</div>
    <h2>تعذّر تحميل الشاشة</h2>
    <p class="muted">${esc(message)}</p>
    ${retry ? `<div class="actions" style="justify-content:center;margin-top:12px">
      <button class="btn" onclick="${esc(retry)}">إعادة المحاولة</button></div>` : ''}
  </div></div>`;
}

export function forbidden(capability: string): string {
  return `<div class="no-permission" role="alert">
    <b>لا صلاحية لعرض هذه الشاشة</b>
    <div style="margin-top:6px">القدرة المطلوبة: <code>${esc(capability)}</code></div>
    <div class="muted" style="margin-top:6px;font-size:11px">
      الإخفاء هنا للراحة؛ الخادم يفحص الصلاحية في كل الأحوال.</div>
  </div>`;
}

/* ---- بنية الشاشة ------------------------------------------------------- */

export function pageHeader(title: string, subtitle?: string, actions = ''): string {
  return `<header class="mast">
    <div>
      <h1>${esc(title)}</h1>
      ${subtitle ? `<div class="muted" style="font-size:11px">${esc(subtitle)}</div>` : ''}
    </div>
    ${actions ? `<div class="actions">${actions}</div>` : ''}
  </header>`;
}

export function breadcrumbs(trail: Array<{ label: string; href?: string }>): string {
  if (!trail.length) return '';
  const parts = trail.map((c, i) => {
    const last = i === trail.length - 1;
    if (last || !c.href) return `<span aria-current="${last ? 'page' : 'false'}">${esc(c.label)}</span>`;
    return `<a href="${esc(c.href)}">${esc(c.label)}</a>`;
  });
  return `<nav class="crumbs" aria-label="مسار التنقّل">${parts.join('<span class="sep" aria-hidden="true">›</span>')}</nav>`;
}

/* ---- الشارات ------------------------------------------------------------
   الحالة لا تُقال باللون وحده: لكل شارة نصّها. */

export function chip(label: string, tone: 'success' | 'warning' | 'critical' | 'info' | 'neutral' | 'brand' = 'neutral'): string {
  return `<span class="chip chip-${tone}">${esc(label)}</span>`;
}

/** الرقم غير المعتمد يحمل وسمه أينما ظهر. */
export function projectedTag(): string {
  return `<span class="projected-tag">تقديري</span>`;
}

/* ---- الجداول ----------------------------------------------------------- */

export interface Column<T> {
  key: string;
  label: string;
  /** يُعيد HTML جاهزاً. المسؤولية عن الهروب على المُنفِّذ. */
  cell: (row: T) => string;
  numeric?: boolean;
}

export function table<T>(columns: Array<Column<T>>, rows: T[], onRow?: (row: T) => string): string {
  const head = columns.map((c) => `<th${c.numeric ? ' style="text-align:center"' : ''}>${esc(c.label)}</th>`).join('');
  const body = rows.map((r) => {
    const click = onRow ? ` onclick="${esc(onRow(r))}" style="cursor:pointer"` : '';
    const cells = columns.map((c) => `<td data-label="${esc(c.label)}">${c.cell(r)}</td>`).join('');
    return `<tr${click}>${cells}</tr>`;
  }).join('');
  return `<div class="table-wrap sticky-table responsive-cards">
    <table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table></div>`;
}

/**
 * الترقيم يذكر حدوده دائماً.
 *
 * القائمة التي تُخفي أنها مقصوصة هي العيب الذي أخرجنا منه هذا العمل: 300 صفاً
 * معروضة من 22,727 بلا أي إشارة إلى الباقي.
 */
export function pager(total: number, limit: number, offset: number, path: string, query: URLSearchParams): string {
  if (total <= limit && offset === 0) {
    return `<div class="pager"><span class="info">${total.toLocaleString('en-US')} صفّاً</span></div>`;
  }
  const page = Math.floor(offset / limit) + 1;
  const pages = Math.max(Math.ceil(total / limit), 1);
  const to = (o: number) => {
    const q = new URLSearchParams(query);
    q.set('offset', String(Math.max(o, 0)));
    return `#${path}?${q.toString()}`;
  };
  const from = offset + 1;
  const upto = Math.min(offset + limit, total);
  return `<div class="pager">
    <span class="info">${from.toLocaleString('en-US')}–${upto.toLocaleString('en-US')} من ${total.toLocaleString('en-US')} · صفحة ${page} من ${pages}</span>
    <a class="btn ${offset <= 0 ? 'is-disabled' : ''}" ${offset <= 0 ? 'aria-disabled="true"' : `href="${to(offset - limit)}"`}>السابق</a>
    <a class="btn ${upto >= total ? 'is-disabled' : ''}" ${upto >= total ? 'aria-disabled="true"' : `href="${to(offset + limit)}"`}>التالي</a>
  </div>`;
}

/* ---- بطاقات الأرقام ---------------------------------------------------- */

export interface Kpi {
  label: string;
  value: string;
  sub?: string;
  tone?: 'primary' | 'gold' | 'green' | 'blue' | 'red';
  /** الرقم الذي لا يقود إلى سجلاته رقمٌ ميّت. */
  link?: string;
}

export function kpiRow(items: Kpi[]): string {
  const cls: Record<string, string> = {
    primary: 'card kpi-primary', gold: 'card goldline', green: 'card greenline',
    blue: 'card blueline', red: 'card redline',
  };
  return `<section class="cards cards-4">${items.map((k) => {
    const inner = `<div class="label">${esc(k.label)}</div>
      <div class="value">${k.value}</div>
      ${k.sub ? `<div class="sub">${esc(k.sub)}</div>` : ''}`;
    const c = cls[k.tone || ''] || 'card';
    return k.link
      ? `<a class="${c}" href="${esc(k.link)}" style="text-decoration:none;color:inherit">${inner}</a>`
      : `<div class="${c}">${inner}</div>`;
  }).join('')}</section>`;
}

/* ---- المرشِّحات --------------------------------------------------------- */

export interface FilterField {
  key: string;
  label: string;
  type: 'search' | 'select';
  options?: Array<{ value: string; label: string }>;
}

/** المرشِّحات تعيش في الاستعلام، فالطابور المُصفّى قابل للإرسال كرابط. */
export function filterBar(fields: FilterField[], path: string, query: URLSearchParams): string {
  const controls = fields.map((f) => {
    const current = query.get(f.key) || '';
    if (f.type === 'search') {
      return `<input class="search" id="flt-${esc(f.key)}" placeholder="${esc(f.label)}"
        value="${esc(current)}" aria-label="${esc(f.label)}">`;
    }
    const opts = [{ value: '', label: `كل ${f.label}` }, ...(f.options || [])]
      .map((o) => `<option value="${esc(o.value)}"${o.value === current ? ' selected' : ''}>${esc(o.label)}</option>`)
      .join('');
    return `<select class="select" id="flt-${esc(f.key)}" aria-label="${esc(f.label)}">${opts}</select>`;
  }).join('');
  const keys = fields.map((f) => f.key).join(',');
  return `<div class="toolbar" data-filter-path="${esc(path)}" data-filter-keys="${esc(keys)}">
    ${controls}
    <button class="btn gold" data-filter-apply>تطبيق</button>
    <a class="btn" href="${esc(href(path))}">مسح</a>
  </div>`;
}

/** يربط شريط المرشِّحات بالاستعلام بعد الإدراج. */
export function wireFilters(root: HTMLElement): void {
  const bar = root.querySelector<HTMLElement>('[data-filter-path]');
  if (!bar) return;
  const path = bar.dataset.filterPath as string;
  const keys = (bar.dataset.filterKeys || '').split(',').filter(Boolean);
  const apply = () => {
    const q: Record<string, string | undefined> = {};
    keys.forEach((k) => {
      const el = root.querySelector<HTMLInputElement | HTMLSelectElement>(`#flt-${CSS.escape(k)}`);
      const v = el?.value.trim();
      if (v) q[k] = v;
    });
    window.location.hash = href(path, q).slice(1);
  };
  bar.querySelector('[data-filter-apply]')?.addEventListener('click', apply);
  bar.querySelectorAll('input.search').forEach((el) => {
    el.addEventListener('keydown', (e) => {
      if ((e as KeyboardEvent).key === 'Enter') apply();
    });
  });
  bar.querySelectorAll('select').forEach((el) => el.addEventListener('change', apply));
}
