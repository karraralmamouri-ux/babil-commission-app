/**
 * طابور مهلة التفعيل المنقضية — GRACE_EXPIRED_REVIEW.
 *
 * القراءة كلّها من page_installation_grace_queue: المصدر الوحيد للحالة يبقى
 * installation_reference_dates() + grace_status_from_dates() على الخادم، لا
 * حساب يومٍ ثلاثين هنا. التجاوز يمرّ عبر override_grace_expired_review (نفس
 * قدرة D-13 المعتمدة) بسببٍ إلزامي ومعرّف طلبٍ جديد لكل نقرة.
 */

import type { Route, View } from '../../app/router';
import { href } from '../../app/router';
import { rpc, pageRpc, can, ApiError } from '../../services/api';
import { count } from '../../domain/money';
import {
  esc, loading, empty, pageHeader, table, pager, chip,
  filterBar, wireFilters, type Column,
} from '../../components/ui';

type Row = Record<string, unknown>;
const s = (r: Row, k: string) => String(r[k] ?? '');
const n = (r: Row, k: string) => Number(r[k] || 0);

function dateOnly(v: unknown): string {
  const str = String(v ?? '');
  return str ? str.slice(0, 10) : '—';
}

function insight(tone: 'good' | 'warn' | 'danger', title: string, detail = ''): string {
  return `<div class="insight ${tone}" style="margin-top:10px"><span class="insight-dot"></span><span>
    <b>${esc(title)}</b>${detail ? `<small>${esc(detail)}</small>` : ''}</span></div>`;
}

const OVERRIDE_BOX_ID = 'graceOverrideBox';

function overridePanel(usernameKey: string): string {
  return `<div class="box" id="graceOverrideConfirm">
    <h3>تجاوز مهلة الانتظار</h3>
    <p class="muted" style="font-size:11px;margin:6px 0 8px">
      المشترك <b dir="ltr">${esc(usernameKey)}</b> تجاوز الثلاثين يوماً بلا تفعيلٍ مؤهَّل مدفوع.
      التجاوز يُبقي المشترك بانتظار تفعيلٍ لاحق (لا يُصيّره «نشطاً» ولا يُنشئ استحقاقاً) ويُسجَّل بسببٍ في التدقيق.</p>
    <div class="toolbar">
      <input class="search" id="graceReason" placeholder="السبب (إلزامي)" aria-label="السبب">
      <button class="btn gold" id="graceConfirmBtn">تأكيد التجاوز</button>
      <button class="btn" id="graceCancelBtn">إلغاء</button>
    </div>
    <div id="graceOverrideResult"></div>
  </div>`;
}

function wireOverride(view: View, root: HTMLElement): void {
  const container = root.querySelector<HTMLElement>(`#${OVERRIDE_BOX_ID}`);
  if (!container) return;

  root.addEventListener('click', (ev) => {
    const btn = (ev.target as HTMLElement)?.closest<HTMLButtonElement>('.grace-override-action');
    if (!btn || !root.contains(btn)) return;
    const usernameKey = btn.dataset['key'] || '';

    container.innerHTML = overridePanel(usernameKey);
    const reason = container.querySelector<HTMLInputElement>('#graceReason');
    const confirm = container.querySelector<HTMLButtonElement>('#graceConfirmBtn');
    const cancel = container.querySelector<HTMLButtonElement>('#graceCancelBtn');
    const out = container.querySelector<HTMLElement>('#graceOverrideResult');
    if (!confirm || !cancel || !out) return;

    cancel.addEventListener('click', () => { container.innerHTML = ''; });

    confirm.addEventListener('click', async () => {
      const why = reason?.value.trim() || '';
      if (!why) { out.innerHTML = insight('warn', 'السبب إلزامي', 'يُحفظ في التدقيق'); return; }

      confirm.disabled = true;
      out.innerHTML = loading('جارٍ التجاوز…');
      try {
        const result = await rpc<Row>('override_grace_expired_review', {
          p_username_key: usernameKey, p_reason: why, p_request_id: crypto.randomUUID(),
        });
        if (!view.live) return;
        out.innerHTML = result?.['replayed'] === true
          ? insight('good', 'مُنفَّذ مسبقاً', 'لم يتغيّر شيء إضافي')
          : insight('good', 'تمّ التجاوز', 'المشترك بانتظار تفعيلٍ مؤهَّل، لا استحقاق تلقائي.');
        window.setTimeout(() => { if (view.live) window.dispatchEvent(new Event('babil:refresh')); }, 900);
      } catch (error) {
        if (!view.live) return;
        out.innerHTML = insight('danger', 'لم يُنفَّذ التجاوز',
          error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
      } finally {
        confirm.disabled = false;
      }
    });
  });
}

export const graceQueue: Route = {
  pattern: '/installation/grace-queue',
  capability: 'installation.view',
  title: 'مهلة تفعيل منقضية',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'أجور التنصيب', href: href('/installation') },
    { label: 'مهلة التفعيل المنقضية' },
  ],
  async render(view, m) {
    const limit = 50;
    const offset = Number(m.query.get('offset') || 0);
    const search = m.query.get('search') || undefined;
    // الافتراض «مهلة منقضية» — لا «الكل» — فيبقى الرابط من مركز القرار ودورة
    // التنصيب نازلاً مباشرةً على العمل المفتوح، كما تفعل شاشة الاستثناء اليدوي.
    const query = new URLSearchParams(m.query);
    if (!query.get('status')) query.set('status', 'EXPIRED');
    const status = query.get('status') as string;
    const isExpired = status === 'EXPIRED';
    view.write(loading('جارٍ تحميل الطابور…'));

    const page = await pageRpc<Row>('page_installation_grace_queue',
      { p_search: search, p_limit: limit, p_offset: offset, p_status: status }, view.signal);

    const canOverride = can('installation.grace_override');
    const columns: Array<Column<Row>> = isExpired ? [
      { key: 'subscriber', label: 'المشترك', cell: (r) => r['installation_subscriber_id']
        ? `<a href="${esc(href(`/installation/subscribers/${r['installation_subscriber_id']}`))}">${esc(s(r, 'display_name') || s(r, 'username_key'))}</a>`
        : `<b dir="ltr">${esc(s(r, 'username_key'))}</b>` },
      { key: 'ref', label: 'أوّل عملية (تاريخ مرجعي)', cell: (r) => dateOnly(r['reference_at']) },
      { key: 'deadline', label: 'آخر أجل', cell: (r) => dateOnly(r['grace_deadline']) },
      { key: 'overdue', label: 'أيام التجاوز', cell: (r) => chip(count(n(r, 'days_overdue')), n(r, 'days_overdue') > 0 ? 'critical' : 'neutral'), numeric: true },
      { key: 'status', label: 'الحالة', cell: () => chip('مهلة منقضية', 'critical') },
      { key: 'act', label: '', cell: (r) => canOverride
        ? `<button class="smallbtn grace-override-action" data-key="${esc(s(r, 'username_key'))}">تجاوز</button>` : '' },
    ] : [
      { key: 'subscriber', label: 'المشترك', cell: (r) => r['installation_subscriber_id']
        ? `<a href="${esc(href(`/installation/subscribers/${r['installation_subscriber_id']}`))}">${esc(s(r, 'display_name') || s(r, 'username_key'))}</a>`
        : `<b dir="ltr">${esc(s(r, 'username_key'))}</b>` },
      { key: 'when', label: 'تاريخ التجاوز', cell: (r) => `<span dir="ltr">${esc(dateOnly(r['overridden_at']))}</span>` },
      { key: 'who', label: 'من نفّذ', cell: (r) => esc(s(r, 'overridden_by_email') || '—') },
      { key: 'reason', label: 'السبب', cell: (r) => esc(s(r, 'reason')) },
      { key: 'status', label: 'الحالة', cell: () => chip('مُتجاوَز', 'success') },
    ];

    view.write(pageHeader('مهلة تفعيل منقضية', 'مرشّحون تجاوزوا ثلاثين يوماً من أوّل عملية بلا تفعيلٍ مؤهَّل مدفوع — D-12/D-13')
      + filterBar([
        { key: 'search', label: 'بحث بمعرّف المشترك', type: 'search' },
        { key: 'status', label: 'الحالة', type: 'select', options: [
          { value: 'EXPIRED', label: 'مهلة منقضية' },
          { value: 'OVERRIDDEN', label: 'مُتجاوَز' },
        ] },
      ], '/installation/grace-queue', query)
      + (page.rows.length ? table(columns, page.rows) : empty(isExpired ? 'لا مهل منقضية بانتظار مراجعة' : 'لا تجاوزات بعد'))
      + pager(page.total, limit, offset, '/installation/grace-queue', query)
      + (isExpired ? `<div id="${OVERRIDE_BOX_ID}" style="margin-top:12px"></div>` : ''));

    wireFilters(view.el);
    if (isExpired) wireOverride(view, view.el);
  },
};

export const routes: Route[] = [graceQueue];
