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
      rpc<Row>('invoice_review_summary', {}).catch(() => null),
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
        const st = str(r, 'invoice_status');
        const meta = INVOICE_STATE[st];
        return chip(meta ? meta.label : st, meta?.tone || 'neutral');
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
      { key: 'go', label: '', cell: (r) => editable
        ? `<button class="smallbtn" data-review="${esc(str(r, 'subscriber_id'))}"
             data-stage="${esc(str(r, 'stage'))}">راجِع</button>`
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
      + `<div id="reviewHost"></div>`;

    wireFilters(view.el);
    wireReview(view);
  },
};

function wireReview(view: View): void {
  const host = view.el.querySelector<HTMLElement>('#reviewHost');
  if (!host) return;

  view.el.querySelectorAll<HTMLButtonElement>('[data-review]').forEach((btn) => {
    btn.addEventListener('click', () => {
      const id = btn.dataset['review'] || '';
      const stage = btn.dataset['stage'] || '';
      host.innerHTML = `<div class="box" style="margin-top:12px" id="reviewBox">
        <h3>مراجعة فاتورة <span dir="ltr">${esc(id)}</span> — ${esc(stage)}</h3>
        <div class="toolbar">
          <select class="select" id="rvStatus" aria-label="القرار">
            ${DECISIONS.map((d) => `<option value="${esc(d.value)}">${esc(d.label)}</option>`).join('')}
          </select>
          <input class="search" id="rvNumber" placeholder="رقم الفاتورة (اختياري)"
            aria-label="رقم الفاتورة" dir="ltr">
          <input class="search" id="rvNote" placeholder="سبب القرار (إلزامي)"
            aria-label="سبب القرار">
          <button class="btn gold" id="rvApply">احفظ القرار</button>
        </div>
        <p class="muted" style="font-size:11px;margin-top:6px">
          «مدقَّقة» ترفع حاجب الفاتورة عن هذا القسط وحده. المراحل الأخرى تُراجَع كلٌّ في وقتها.</p>
        <div id="rvResult"></div>
      </div>`;
      host.scrollIntoView({ behavior: 'smooth', block: 'nearest' });

      const status = host.querySelector<HTMLSelectElement>('#rvStatus');
      const number = host.querySelector<HTMLInputElement>('#rvNumber');
      const note = host.querySelector<HTMLInputElement>('#rvNote');
      const apply = host.querySelector<HTMLButtonElement>('#rvApply');
      const out = host.querySelector<HTMLElement>('#rvResult');
      if (!status || !apply || !out) return;

      apply.addEventListener('click', async () => {
        const why = note?.value.trim() || '';
        if (!why) {
          out.innerHTML = insight('warn', 'السبب إلزامي', 'يُحفظ مع القرار ويظهر في التدقيق');
          return;
        }
        apply.disabled = true;
        out.innerHTML = loading('جارٍ حفظ القرار…');
        try {
          const result = await rpc<Row>('review_invoice', {
            p_subscriber_id: id,
            p_stage_code: stage,
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
          window.setTimeout(() => { if (view.live) window.location.reload(); }, 1200);
        } catch (error) {
          if (!view.live) return;
          out.innerHTML = insight('danger', 'لم يُحفظ القرار',
            error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
        } finally {
          apply.disabled = false;
        }
      });
    });
  });
}

function insight(tone: 'good' | 'warn' | 'danger', title: string, detail = ''): string {
  return `<div class="insight ${tone}" style="margin-top:10px"><span class="insight-dot"></span><span>
    <b>${esc(title)}</b>${detail ? `<small>${esc(detail)}</small>` : ''}</span></div>`;
}

export const routes: Route[] = [invoiceReview];
