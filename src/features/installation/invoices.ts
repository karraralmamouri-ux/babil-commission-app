/**
 * مراجعة الفواتير — الحاجب الأكبر أمام صرف تموز.
 *
 * كل مرحلة تشترط فاتورة مدقَّقة، ولا فاتورة مدقَّقة واحدة. فالمرشّحون كلّهم
 * محجوبون بهذا السبب وحده، وهذه الشاشة هي التي تفتحه.
 *
 * القرار مالي: تدقيقُ فاتورةٍ يرفع الحاجب عن قسط. فيُطلب سببٌ مكتوب في كل
 * الحالات — التدقيق والنقص والرفض — ويُسجَّل باسم صاحبه.
 */

import type { Route, View } from '../../app/router';
import { href } from '../../app/router';
import { rpc, pageRpc, can, ApiError } from '../../services/api';
import { money, count } from '../../domain/money';
import {
  esc, loading, empty, pageHeader, table, pager, kpiRow, chip,
  filterBar, wireFilters, type Column,
} from '../../components/ui';

type Row = Record<string, unknown>;
const num = (r: Row, k: string) => Number(r[k] || 0);
const str = (r: Row, k: string) => String(r[k] ?? '');

/** الحالات كما تُعرض. «لم تُفحص» غيابُ صفّ لا قيمةٌ مخزَّنة. */
export const INVOICE_STATE: Record<string,
  { label: string; tone: 'success' | 'warning' | 'critical' | 'neutral' }> = {
  NOT_CHECKED: { label: 'لم تُفحص', tone: 'neutral' },
  PENDING:     { label: 'قيد المراجعة', tone: 'warning' },
  VERIFIED:    { label: 'مدقَّقة', tone: 'success' },
  MISSING:     { label: 'لا فاتورة', tone: 'critical' },
  REJECTED:    { label: 'مرفوضة', tone: 'critical' },
};

/** القرارات المتاحة للمراجع. «قيد المراجعة» حالةٌ لا قرار. */
const DECISIONS = [
  { value: 'VERIFIED', label: 'مدقَّقة — ترفع الحاجب' },
  { value: 'MISSING', label: 'لا فاتورة في المصدر' },
  { value: 'REJECTED', label: 'مرفوضة' },
];

function invoiceStateChip(state: string): string {
  const meta = INVOICE_STATE[state];
  return chip(meta ? meta.label : state || '—', meta?.tone || 'neutral');
}

export const invoiceReview: Route = {
  pattern: '/installation/invoices',
  capability: 'invoice.view',
  title: 'مراجعة الفواتير',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'أجور التنصيب', href: href('/installation') },
    { label: 'مراجعة الفواتير' },
  ],
  async render(view, m) {
    const limit = 50;
    const offset = Number(m.query.get('offset') || 0);
    view.innerHTML = loading('جارٍ تحميل طابور المراجعة…');

    const args: Record<string, unknown> = { p_limit: limit, p_offset: offset };
    for (const [q, p] of [['status', 'p_status'], ['reseller', 'p_reseller'],
      ['stage', 'p_stage'], ['search', 'p_search']] as const) {
      const v = m.query.get(q);
      if (v) args[p] = v;
    }

    const [page, summary] = await Promise.all([
      pageRpc<Row>('page_invoice_review', args, view.signal),
      rpc<Row>('invoice_review_summary', {}),
    ]);
    if (!view.live) return;

    const byStatus = (summary?.['by_status'] || {}) as Record<string, Row>;
    const notChecked = byStatus['NOT_CHECKED'];
    const editable = can('invoice.verify') || can('invoice.reject');

    const columns: Array<Column<Row>> = [
      { key: 'sid', label: 'المشترك', cell: (r) =>
        `<a dir="ltr" href="${esc(href(`/installation/subscribers/${encodeURIComponent(str(r, 'subscriber_id'))}`))}">${esc(str(r, 'subscriber_id'))}</a>` },
      // الاسم كما ورد من المصدر.
      { key: 'res', label: 'الوكيل / الأب', cell: (r) => esc(str(r, 'reseller') || '—') },
      { key: 'stage', label: 'المرحلة', cell: (r) => chip(str(r, 'stage'), 'info') },
      { key: 'amt', label: 'المبلغ', cell: (r) =>
        `<span class="money">${money(num(r, 'amount'))}</span>`, numeric: true },
      { key: 'state', label: 'الفاتورة', cell: (r) => {
        return invoiceStateChip(str(r, 'invoice_status'));
      } },
      { key: 'num', label: 'رقم الفاتورة', cell: (r) =>
        str(r, 'invoice_number') ? `<span dir="ltr">${esc(str(r, 'invoice_number'))}</span>` : '—' },
      { key: 'who', label: 'المراجع', cell: (r) =>
        esc(str(r, 'verified_by_email') || str(r, 'rejected_by_email') || '—') },
      // الشواهد المجاورة: تُقرأ مع الفاتورة لأن القرار يُتّخذ بها معاً.
      { key: 'other', label: 'شواهد أخرى', cell: (r) => {
        const bits: string[] = [];
        if (r['held'] === true) bits.push(chip('معلَّق', 'critical'));
        if (str(r, 'ownership') !== 'RESELLER') bits.push(chip('عائدية', 'warning'));
        if (r['eligible'] !== true) bits.push(chip('أهلية', 'warning'));
        return bits.length ? bits.join(' ') : '<span class="muted">لا مانع آخر</span>';
      } },
      { key: 'go', label: 'الإجراء', cell: (r) => editable
        ? `<button class="smallbtn" data-review-index="${page.rows.indexOf(r)}">راجِع</button>`
        : '' },
    ];

    view.innerHTML = pageHeader('مراجعة الفواتير',
      'تدقيق الفاتورة يرفع الحاجب عن قسط — قرارٌ ماليّ يُسجَّل باسم صاحبه')

      + kpiRow([
        { label: 'في الطابور', value: count(num(summary || {}, 'total')), tone: 'primary',
          sub: money(num(summary || {}, 'total_amount')) },
        { label: 'لم تُفحص', value: count(Number(notChecked?.['n'] || 0)), tone: 'red',
          sub: money(Number(notChecked?.['amount'] || 0)),
          link: href('/installation/invoices', { status: 'NOT_CHECKED' }) },
        { label: 'مدقَّقة', value: count(num(summary || {}, 'verified')), tone: 'green',
          sub: money(num(summary || {}, 'verified_amount')),
          link: href('/installation/invoices', { status: 'VERIFIED' }) },
        { label: 'تفتح الصرف', value: money(num(summary || {}, 'verified_amount')), tone: 'gold',
          sub: 'ما رُفع عنه حاجب الفاتورة', link: href('/installation/ready') },
      ])

      + `<div class="actions" style="margin-bottom:12px">
          <a class="btn gold" href="${esc(href('/installation/invoices/bulk'))}">تدقيق فواتير بالجملة من ملف</a>
        </div>`

      + filterBar([
        { key: 'search', label: 'بحث بالمشترك أو الرقم', type: 'search' },
        { key: 'status', label: 'حالة الفاتورة', type: 'select',
          options: Object.entries(INVOICE_STATE).map(([k, v]) => ({ value: k, label: v.label })) },
        { key: 'stage', label: 'المرحلة', type: 'select',
          options: ['P1', 'P2', 'P3', 'P4'].map((s) => ({ value: s, label: s })) },
      ], '/installation/invoices', m.query)

      + (page.outOfRange
        ? `<div class="insight warn"><span class="insight-dot"></span><span><b>الصفحة خارج المدى</b>
           <small>الطابور فيه ${count(page.total)} صفّاً.</small></span></div>`
        : '')
      + (page.rows.length ? table(columns, page.rows) : empty('لا فواتير في الطابور'))
      + pager(page.total, limit, offset, '/installation/invoices', m.query)
      + `<button class="review-drawer-backdrop" id="reviewBackdrop" type="button"
          aria-label="إغلاق مراجعة الفاتورة"></button>
        <aside class="drawer review-drawer" id="reviewDrawer" aria-hidden="true"
          aria-label="مراجعة الفاتورة"></aside>`;

    wireFilters(view.el);
    wireReview(view, page.rows);
  },
};

function wireReview(view: View, rows: Row[]): void {
  const drawer = view.el.querySelector<HTMLElement>('#reviewDrawer');
  const backdrop = view.el.querySelector<HTMLButtonElement>('#reviewBackdrop');
  if (!drawer || !backdrop) return;

  let activeIndex = -1;
  const close = () => {
    drawer.classList.remove('open');
    backdrop.classList.remove('open');
    drawer.setAttribute('aria-hidden', 'true');
  };

  const open = (index: number) => {
    const row = rows[index];
    if (!row) return;
    activeIndex = index;
    drawer.innerHTML = reviewDrawer(row, index, rows.length);
    drawer.classList.add('open');
    backdrop.classList.add('open');
    drawer.setAttribute('aria-hidden', 'false');

    drawer.querySelector<HTMLButtonElement>('[data-review-close]')?.addEventListener('click', close);
    drawer.querySelector<HTMLButtonElement>('[data-review-prev]')?.addEventListener('click', () => open(index - 1));
    drawer.querySelector<HTMLButtonElement>('[data-review-next]')?.addEventListener('click', () => open(index + 1));

    const status = drawer.querySelector<HTMLSelectElement>('#rvStatus');
    const number = drawer.querySelector<HTMLInputElement>('#rvNumber');
    const note = drawer.querySelector<HTMLTextAreaElement>('#rvNote');
    const apply = drawer.querySelector<HTMLButtonElement>('#rvApply');
    const out = drawer.querySelector<HTMLElement>('#rvResult');
    if (!status || !apply || !out) return;

    apply.addEventListener('click', async () => {
        if (!status.value) {
          out.innerHTML = insight('warn', 'اختر القرار', 'لا يوجد قرار محدد مسبقاً');
          status.focus();
          return;
        }
        const why = note?.value.trim() || '';
        if (!why) {
          out.innerHTML = insight('warn', 'السبب إلزامي', 'يُحفظ مع القرار ويظهر في التدقيق');
          return;
        }
        apply.disabled = true;
        out.innerHTML = loading('جارٍ حفظ القرار…');
        try {
          const result = await rpc<Row>('review_invoice', {
            p_subscriber_id: str(row, 'subscriber_id'),
            p_stage_code: str(row, 'stage'),
            p_status: status.value,
            p_note: why,
            p_invoice_number: number?.value.trim() || null,
            p_request_id: crypto.randomUUID(),
          });
          if (!view.live) return;
          const after = str(result, 'status_after');
          out.innerHTML = result?.['idempotent'] === true
            ? insight('good', 'هذا القرار مسجَّل مسبقاً')
            : insight('good', `حُفظ: ${INVOICE_STATE[after]?.label || after}`,
                after === 'VERIFIED'
                  ? `رُفع حاجب الفاتورة عن ${money(num(result, 'amount'))}.`
                  : 'يبقى الحاجب قائماً حتى تُدقَّق.');
          if (after) {
            row['invoice_status'] = after;
            if (number?.value.trim()) row['invoice_number'] = number.value.trim();
            updateVisibleRow(view, index, row);
            const state = drawer.querySelector<HTMLElement>('[data-current-invoice-state]');
            if (state) state.innerHTML = invoiceStateChip(after);
          }
        } catch (error) {
          if (!view.live) return;
          out.innerHTML = insight('danger', 'لم يُحفظ القرار',
            error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
        } finally {
          apply.disabled = false;
        }
      });
    window.setTimeout(() => status.focus(), 0);
  };

  view.el.querySelectorAll<HTMLButtonElement>('[data-review-index]').forEach((btn) => {
    btn.addEventListener('click', () => open(Number(btn.dataset['reviewIndex'])));
  });
  backdrop.addEventListener('click', close);
  view.signal.addEventListener('abort', close, { once: true });
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && activeIndex >= 0) close();
  }, { signal: view.signal });
}

function reviewDrawer(row: Row, index: number, total: number): string {
  const decisions = DECISIONS.filter((d) => d.value === 'VERIFIED'
    ? can('invoice.verify') : can('invoice.reject'));
  const evidence = [
    ['المصدر', str(row, 'invoice_source') || '—'],
    ['مرجع المصدر', str(row, 'invoice_reference') || '—'],
    ['تاريخ الفاتورة', str(row, 'invoice_date') || '—'],
    ['العائدية', str(row, 'ownership') === 'RESELLER' ? 'وكيل' : 'تحتاج حسم'],
    ['التعليق', row['held'] === true ? 'يوجد تعليق فعّال' : 'لا يوجد'],
    ['الأهلية', row['eligible'] === true ? 'مستوفاة' : 'تحتاج مراجعة'],
  ];
  return `<div class="modalhead">
      <div><h2>مراجعة فاتورة</h2><div class="muted review-position">${index + 1} من ${total}</div></div>
      <button class="smallbtn" type="button" data-review-close aria-label="إغلاق">إغلاق</button>
    </div>
    <section class="review-result" aria-label="بيانات القرار">
      <div><span class="muted">المشترك</span><b dir="ltr">${esc(str(row, 'subscriber_id'))}</b></div>
      <div><span class="muted">الوكيل / الأب</span><b>${esc(str(row, 'reseller') || '—')}</b></div>
      <div><span class="muted">المرحلة</span><b>${chip(str(row, 'stage'), 'info')}</b></div>
      <div><span class="muted">المبلغ</span><b class="money">${money(num(row, 'amount'))}</b></div>
      <div><span class="muted">حالة الفاتورة</span><b data-current-invoice-state>${invoiceStateChip(str(row, 'invoice_status'))}</b></div>
      <div><span class="muted">رقم الفاتورة</span><b dir="ltr">${esc(str(row, 'invoice_number') || '—')}</b></div>
    </section>
    <section class="review-evidence"><h3>الأدلة المتاحة</h3>
      ${evidence.map(([label, value]) => `<div class="minirow"><span class="muted">${esc(label)}</span><b>${esc(value)}</b></div>`).join('')}
    </section>
    <section class="review-decision"><h3>القرار</h3>
      <label for="rvStatus">اختر القرار</label>
      <select class="select" id="rvStatus"><option value="" selected disabled>اختر القرار</option>
        ${decisions.map((d) => `<option value="${esc(d.value)}">${esc(d.label)}</option>`).join('')}
      </select>
      <label for="rvNumber">رقم الفاتورة <span class="muted">(اختياري)</span></label>
      <input class="search" id="rvNumber" value="${esc(str(row, 'invoice_number'))}" dir="ltr">
      <label for="rvNote">سبب القرار</label>
      <textarea class="search review-note" id="rvNote" rows="3" placeholder="سبب القرار (إلزامي)"></textarea>
      <p class="field-help">«مدقَّقة» ترفع حاجب الفاتورة عن هذا القسط وحده. لا يُنشئ هذا الإجراء دفعة.</p>
      <button class="btn gold review-apply" id="rvApply" type="button">احفظ القرار</button>
      <div id="rvResult" aria-live="polite"></div>
    </section>
    <div class="review-navigation">
      <button class="btn" type="button" data-review-prev${index <= 0 ? ' disabled' : ''}>السابق</button>
      <button class="btn" type="button" data-review-next${index >= total - 1 ? ' disabled' : ''}>التالي</button>
    </div>`;
}

function updateVisibleRow(view: View, index: number, row: Row): void {
  const btn = view.el.querySelector<HTMLButtonElement>(`[data-review-index="${index}"]`);
  const tr = btn?.closest('tr');
  const stateCell = tr?.querySelector<HTMLElement>('td[data-label="الفاتورة"]');
  const numberCell = tr?.querySelector<HTMLElement>('td[data-label="رقم الفاتورة"]');
  if (stateCell) stateCell.innerHTML = invoiceStateChip(str(row, 'invoice_status'));
  if (numberCell) numberCell.innerHTML = str(row, 'invoice_number')
    ? `<span dir="ltr">${esc(str(row, 'invoice_number'))}</span>` : '—';
}

function insight(tone: 'good' | 'warn' | 'danger', title: string, detail = ''): string {
  return `<div class="insight ${tone}" style="margin-top:10px"><span class="insight-dot"></span><span>
    <b>${esc(title)}</b>${detail ? `<small>${esc(detail)}</small>` : ''}</span></div>`;
}

/* ---- تدقيق الفواتير بالجملة ------------------------------------------------
 *
 * نفس بنية تعليق الجملة تماماً (holds.ts): ملفٌ يُقرأ → معاينة مبوَّبة قبل أي
 * تطبيق → تطبيق دفعة واحدة. المطابقة والتطبيق يستدعيان review_invoice نفسها
 * على الخادم، فأثر «مدقَّقة» هنا مطابقٌ حرفياً لأثر المراجعة اليدوية.
 */

const INVOICE_BUCKET_AR: Record<string, string> = {
  matched: 'ستُدقَّق',
  unknown: 'معرّف غير معروف',
  conflict: 'تعارض — أكثر من فاتورة لنفس المشترك في الرفعة',
  duplicate: 'رقم فاتورة مكرَّر في الرفعة',
  already_used: 'لا مرحلة مفتوحة أو مدقَّقة سلفاً',
  invalid: 'صفّ ناقص',
};

const INVOICE_BUCKET_TONE: Record<string, 'success' | 'critical' | 'warning' | 'neutral'> = {
  matched: 'success',
  unknown: 'critical',
  conflict: 'critical',
  duplicate: 'warning',
  already_used: 'neutral',
  invalid: 'critical',
};

export const bulkInvoiceAudit: Route = {
  pattern: '/installation/invoices/bulk',
  capability: 'invoice.verify',
  title: 'تدقيق فواتير بالجملة',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'أجور التنصيب', href: href('/installation') },
    { label: 'مراجعة الفواتير', href: href('/installation/invoices') },
    { label: 'تدقيق بالجملة' },
  ],
  render(view) {
    view.innerHTML = pageHeader('تدقيق فواتير بالجملة',
      'ارفع ملفاً فيه معرّف المشترك ورقم الفاتورة وتاريخها — يُعايَن قبل أن يُطبَّق شيء')

      + `<div class="box">
        <h3>١ · الملف</h3>
        <p class="muted" style="font-size:11px;margin:0 0 8px">
          ثلاثة أعمدة بهذا الترتيب: معرّف المشترك، رقم الفاتورة، تاريخها
          (YYYY-MM-DD). الصيغ المقبولة: CSV أو إكسل (xlsx/xls) — الورقة
          الأولى فقط — أو نصّ بسطرٍ لكل فاتورة.
          مشتركٌ له أكثر من فاتورة في الملف نفسه يُرفض تعارضاً — لا تخمين
          لأيّ مرحلة تليها.</p>
        <div class="toolbar">
          <input type="file" id="biFile" accept=".csv,.txt,.xlsx,.xls" class="search"
            aria-label="ملف الفواتير">
          <button class="btn" id="biParse">اقرأ الملف</button>
        </div>
        <textarea id="biRows" class="search" rows="6" dir="ltr"
          style="width:100%;margin-top:10px;font-family:ui-monospace,Consolas,monospace"
          placeholder="أو الصق الصفوف هنا: subscriber_id,invoice_number,invoice_date"
          aria-label="صفوف الفواتير"></textarea>
        <div id="biFileInfo" class="muted" style="font-size:11px;margin-top:6px"></div>
      </div>

      <div class="box" style="margin-top:12px">
        <h3>٢ · سبب التدقيق</h3>
        <input class="search" id="biReason" placeholder="سبب القرار (إلزامي — يُحفظ في التدقيق)"
          aria-label="سبب القرار" style="width:100%">
      </div>

      <div class="actions" style="margin-top:12px">
        <button class="btn" id="biPreview">٣ · عايِن</button>
        <button class="btn gold" id="biApply" disabled>٤ · طبّق التدقيق</button>
      </div>

      <div id="biResult" style="margin-top:12px"></div>`;

    wireBulkInvoiceAudit(view);
  },
};

/** المحلِّل الفعلي — يعمل على خلايا مجرَّدة مهما كان مصدرها: نصٌّ مفصولٌ
 * بفواصل، أو صفوف ورقة إكسل. مصدرٌ واحدٌ للقاعدة، لا محلِّلان يمكن أن ينحرفا. */
function rowsFromCells(cellRows: string[][]): Array<Record<string, string>> {
  const rows = cellRows.map((cols) => ({
    subscriber_id: (cols[0] || '').trim(),
    invoice_number: (cols[1] || '').trim(),
    invoice_date: (cols[2] || '').trim(),
  })).filter((r) => r.subscriber_id);
  if (rows.length && /^(subscriber[\s_-]?id|id|المشترك|معرّف)$/i.test(rows[0]?.subscriber_id || '')) {
    rows.shift();
  }
  return rows;
}

function parseInvoiceRows(text: string): Array<Record<string, string>> {
  const lines = text.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  const cellRows = lines.map((line) => line.split(/[,;\t]/));
  return rowsFromCells(cellRows);
}

declare global {
  interface Window {
    XLSX?: {
      read: (data: ArrayBuffer, opts: { type: string }) => { SheetNames: string[]; Sheets: Record<string, unknown> };
      utils: { sheet_to_json: (sheet: unknown, opts: { defval: string; header?: number; raw?: boolean }) => Row[] };
    };
  }
}

/** يقرأ أول ورقة من ملف xlsx/xls عبر SheetJS المُحمَّلة سلفاً (raw: false —
 * القيم كما تُعرض في إكسل، لا الرقم التسلسلي الخام لتاريخٍ مثلاً)، ويمرّرها
 * لنفس محلِّل الخلايا الذي يقرأ CSV — لا قاعدة مطابقة أو تكرار ثانية. */
async function parseInvoiceWorkbook(file: File): Promise<Array<Record<string, string>>> {
  const xlsx = window.XLSX;
  if (!xlsx) throw new Error('مكتبة قراءة إكسل غير محمَّلة — أعِد تحميل الصفحة ثم حاول مرّةً أخرى.');
  const buffer = await file.arrayBuffer();
  const book = xlsx.read(buffer, { type: 'array' });
  const sheet = book.Sheets[book.SheetNames[0] || ''];
  if (!sheet) return [];
  const raw = xlsx.utils.sheet_to_json(sheet, { defval: '', header: 1, raw: false }) as unknown as unknown[][];
  const cellRows = raw.map((cols) => cols.map((c) => String(c ?? '').trim()));
  return rowsFromCells(cellRows);
}

/** يُعيد صفوفاً مُحلَّلة إلى نصّ الصندوق — يبقى مربّع النصّ مصدر الحقيقة
 * الوحيد الذي يراه المستخدم ويعدّله قبل المعاينة، مهما كان مصدر الملف. */
function rowsToText(rows: Array<Record<string, string>>): string {
  return rows.map((r) => `${r.subscriber_id},${r.invoice_number},${r.invoice_date}`).join('\n');
}

function wireBulkInvoiceAudit(view: View): void {
  const root = view.el;
  const file = root.querySelector<HTMLInputElement>('#biFile');
  const parse = root.querySelector<HTMLButtonElement>('#biParse');
  const rowsBox = root.querySelector<HTMLTextAreaElement>('#biRows');
  const info = root.querySelector<HTMLElement>('#biFileInfo');
  const reason = root.querySelector<HTMLInputElement>('#biReason');
  const preview = root.querySelector<HTMLButtonElement>('#biPreview');
  const apply = root.querySelector<HTMLButtonElement>('#biApply');
  const out = root.querySelector<HTMLElement>('#biResult');
  if (!rowsBox || !preview || !apply || !out) return;

  let filename = '';
  let previewed: Array<Record<string, string>> = [];

  parse?.addEventListener('click', async () => {
    const f = file?.files?.[0];
    if (!f) { if (info) info.textContent = 'اختر ملفاً أولاً'; return; }
    filename = f.name;
    if (/\.xlsx?$/i.test(f.name)) {
      if (info) info.textContent = 'جارٍ قراءة ملف الإكسل…';
      try {
        const rows = await parseInvoiceWorkbook(f);
        rowsBox.value = rowsToText(rows);
        if (info) info.textContent = `${f.name} — ${rows.length.toLocaleString('en-US')} صفّاً`;
      } catch (e) {
        if (info) info.textContent = e instanceof Error ? e.message : 'تعذّرت قراءة ملف الإكسل';
      }
      return;
    }
    const reader = new FileReader();
    reader.onload = () => {
      rowsBox.value = String(reader.result || '');
      const n = parseInvoiceRows(rowsBox.value).length;
      if (info) info.textContent = `${f.name} — ${n.toLocaleString('en-US')} صفّاً`;
    };
    reader.readAsText(f, 'utf-8');
  });

  preview.addEventListener('click', async () => {
    const list = parseInvoiceRows(rowsBox.value);
    if (!list.length) {
      out.innerHTML = insight('warn', 'لا صفوف', 'ارفع ملفاً أو الصق الصفوف');
      return;
    }
    preview.disabled = true;
    out.innerHTML = loading('جارٍ المعاينة…');
    try {
      const doc = await rpc<Row>('preview_bulk_invoice_upload', { p_rows: list });
      if (!view.live) return;
      previewed = list;
      out.innerHTML = renderInvoicePreview(doc);
      const counts = (doc?.['counts'] || {}) as Record<string, number>;
      apply.disabled = Number(counts['matched'] || 0) === 0;
    } catch (error) {
      if (!view.live) return;
      out.innerHTML = insight('danger', 'تعذّرت المعاينة',
        error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
    } finally {
      preview.disabled = false;
    }
  });

  apply.addEventListener('click', async () => {
    if (!can('invoice.verify')) {
      out.innerHTML = insight('warn', 'لا صلاحية', 'التدقيق بالجملة يحتاج invoice.verify');
      return;
    }
    const why = reason?.value.trim() || '';
    if (!why) {
      out.innerHTML = insight('warn', 'السبب إلزامي', 'يُحفظ مع كل قرار ويظهر في التدقيق');
      return;
    }
    if (!previewed.length) {
      out.innerHTML = insight('warn', 'عايِن أولاً', 'لا يُطبَّق شيء قبل أن يُعرض أثره');
      return;
    }

    apply.disabled = true;
    out.innerHTML = loading('جارٍ تطبيق التدقيق…');
    try {
      const result = await rpc<Row>('apply_bulk_invoice_upload', {
        p_rows: previewed,
        p_filename: filename || 'لصق يدوي',
        p_note: why,
        p_request_id: crypto.randomUUID(),
      });
      if (!view.live) return;
      out.innerHTML = result?.['idempotent'] === true
        ? insight('good', 'هذا الرفع مسجَّل مسبقاً', 'لم يُدقَّق شيء مرّةً ثانية')
        : insight('good', `دُقِّقت ${count(Number(result?.['applied'] || 0))} فاتورة`,
            `تُرك ${count(Number(result?.['skipped'] || 0))} — تعارض أو مكرَّر أو غير مطابق.`)
          + `<div class="actions" style="margin-top:10px">
              <a class="btn" href="${esc(href('/installation/invoices'))}">افتح طابور المراجعة</a></div>`;
    } catch (error) {
      if (!view.live) return;
      out.innerHTML = insight('danger', 'لم يُطبَّق التدقيق',
        error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
    } finally {
      apply.disabled = false;
    }
  });
}

function renderInvoicePreview(doc: Row | null): string {
  const counts = (doc?.['counts'] || {}) as Record<string, number>;
  const rows = (doc?.['rows'] || []) as Row[];
  const submitted = Number(doc?.['submitted'] || 0);

  const order = ['matched', 'conflict', 'duplicate', 'already_used', 'unknown', 'invalid'];
  const chips = order
    .filter((k) => Number(counts[k] || 0) > 0)
    .map((k) => `<div class="minirow">
      <span>${chip(INVOICE_BUCKET_AR[k] || k, INVOICE_BUCKET_TONE[k] || 'neutral')}</span>
      <b>${count(Number(counts[k]))}</b></div>`).join('');

  return `<div class="box">
    <h3>المعاينة</h3>
    <div class="minirow"><span class="muted">في الملف</span><b>${count(submitted)}</b></div>
    ${chips}
    <p class="muted" style="font-size:11px;margin-top:8px">
      لن تُدقَّق إلا «ستُدقَّق». الباقي يُترك كما هو، ولا شيء يُحذف.</p>
    ${rows.length ? table<Row>([
      { key: 'id', label: 'المعرّف', cell: (r) => `<span dir="ltr">${esc(str(r, 'subscriber_id'))}</span>` },
      { key: 'inv', label: 'رقم الفاتورة', cell: (r) => `<span dir="ltr">${esc(str(r, 'invoice_number'))}</span>` },
      { key: 'stage', label: 'المرحلة', cell: (r) => str(r, 'stage') ? chip(str(r, 'stage'), 'info') : '—' },
      { key: 'b', label: 'النتيجة', cell: (r) => {
        const b = str(r, 'bucket');
        return chip(INVOICE_BUCKET_AR[b] || b, INVOICE_BUCKET_TONE[b] || 'neutral');
      } },
    ], rows.slice(0, 200)) : ''}
    ${rows.length > 200
      ? `<p class="muted" style="font-size:11px">تُعرض أوّل 200 صفّاً من ${count(rows.length)}.</p>`
      : ''}
  </div>`;
}

export const routes: Route[] = [invoiceReview, bulkInvoiceAudit];
