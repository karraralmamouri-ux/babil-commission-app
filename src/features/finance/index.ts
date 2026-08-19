/**
 * المالية — دفعات الصرف.
 *
 * لا قرار مالي في المتصفح. الشاشة تعرض حالة الخادم، والترحيل يمرّ بـ
 * post_commission_batch بعد إعادة تحقّق الخادم — والرفض يُعرَض بنصّه لا
 * يُستبَق بمنطق في الواجهة.
 */

import type { Route } from '../../app/router';
import { href } from '../../app/router';
import { rpc, select, toPage } from '../../services/api';
import { money, count } from '../../domain/money';
import {
  esc, loading, empty, pageHeader, table, pager, chip, kpiRow, type Column,
} from '../../components/ui';
import { routes as installationBatchRoutes } from './installation-batches';

type Row = Record<string, unknown>;
const num = (r: Row, k: string) => Number(r[k] || 0);
const str = (r: Row, k: string) => String(r[k] ?? '');

const BATCH_TONE: Record<string, 'success' | 'warning' | 'info' | 'neutral'> = {
  POSTED: 'success', PAID: 'success', DRAFT: 'warning', VALIDATED: 'info', CANCELLED: 'neutral',
};

export const batches: Route = {
  pattern: '/finance/payment-batches',
  capability: 'payment.view',
  title: 'دفعات الصرف',
  breadcrumb: () => [{ label: 'الرئيسية', href: href('/') }, { label: 'المالية' }, { label: 'دفعات الصرف' }],
  async render(view, m) {
    const limit = 50;
    const offset = Number(m.query.get('offset') || 0);
    view.write(loading('جارٍ تحميل الدفعات…'));

    const rows = await rpc<Row[]>('list_payment_batches', { p_limit: limit, p_offset: offset });
    const page = toPage(rows as never, limit, offset);

    const columns: Array<Column<Row>> = [
      { key: 'name', label: 'الدفعة', cell: (r) => `<b>${esc(str(r, 'name') || '—')}</b>` },
      { key: 'status', label: 'الحالة', cell: (r) => chip(str(r, 'status'), BATCH_TONE[str(r, 'status')] || 'neutral') },
      { key: 'items', label: 'السطور', cell: (r) => count(num(r, 'item_count')), numeric: true },
      { key: 'amount', label: 'المبلغ', cell: (r) => `<span class="money">${money(num(r, 'total_amount'))}</span>`, numeric: true },
      { key: 'prepared', label: 'التجهيز', cell: (r) => esc(str(r, 'prepared_at').slice(0, 10) || '—') },
      { key: 'posted', label: 'الترحيل', cell: (r) => esc(str(r, 'posted_at').slice(0, 10) || '—') },
      { key: 'go', label: '', cell: (r) => `<a class="smallbtn" href="${esc(href(`/finance/payment-batches/${str(r, 'id')}`))}">فتح</a>` },
    ];

    view.write(pageHeader('دفعات الصرف', 'الترحيل بيد الخادم — الشاشة تعرض قراره')
      + (page.rows.length
        ? table(columns, page.rows as Row[])
        : empty('لا دفعات', 'تُجهَّز الدفعة من دورة معتمدة'))
      + pager(page.total, limit, offset, '/finance/payment-batches', m.query));
  },
};

export const batchDetail: Route = {
  pattern: '/finance/payment-batches/:id',
  capability: 'payment.view',
  title: 'دفعة صرف',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'المالية' },
    { label: 'دفعات الصرف', href: href('/finance/payment-batches') },
    { label: 'دفعة' },
  ],
  async render(view, m) {
    const id = m.params['id'] as string;
    view.write(loading());

    const [batchRows, items] = await Promise.all([
      select<Row[]>(`commission_payment_batches?select=*&id=eq.${encodeURIComponent(id)}`),
      select<Row[]>(`commission_payment_batch_items?select=*&batch_id=eq.${encodeURIComponent(id)}&order=amount.desc`),
    ]);
    const batch = (batchRows || [])[0];
    if (!batch) { view.write(empty('الدفعة غير موجودة')); return; }

    const lines = items || [];
    const blocked = lines.filter((l) => str(l, 'status') === 'BLOCKED');
    const pending = lines.filter((l) => str(l, 'status') === 'PENDING');

    const columns: Array<Column<Row>> = [
      { key: 'scope', label: 'النطاق', cell: (r) => `<b>${esc(str(r, 'scope_label') || str(r, 'scope_id'))}</b>
        <div class="muted" style="font-size:10px">${esc(str(r, 'scope_type'))}</div>` },
      { key: 'agent', label: 'الوكيل', cell: (r) => esc(str(r, 'agent_name') || '—') },
      { key: 'gross', label: 'الإجمالي', cell: (r) => money(num(r, 'gross_amount')), numeric: true },
      { key: 'paid', label: 'مدفوع سابقاً', cell: (r) => money(num(r, 'already_paid')), numeric: true },
      { key: 'amount', label: 'المبلغ', cell: (r) => `<span class="money">${money(num(r, 'amount'))}</span>`, numeric: true },
      { key: 'status', label: 'الحالة', cell: (r) => str(r, 'status') === 'BLOCKED'
        ? chip('مرفوض', 'critical') : chip(str(r, 'status') || '—', 'info') },
      // سبب الرفض يأتي من الخادم بنصّه: الواجهة لا تُعيد صياغته ولا تُخمّنه.
      { key: 'reason', label: 'سبب الرفض', cell: (r) => esc(str(r, 'blocked_reason') || '—') },
    ];

    view.write(pageHeader(str(batch, 'name') || 'دفعة',
      `${esc(str(batch, 'payment_reference') || 'بلا مرجع')}`,
      chip(str(batch, 'status'), BATCH_TONE[str(batch, 'status')] || 'neutral'))
      + kpiRow([
        { label: 'إجمالي الدفعة', value: money(num(batch, 'total_amount')), tone: 'primary' },
        { label: 'السطور', value: count(lines.length), tone: 'gold' },
        { label: 'بانتظار', value: count(pending.length), tone: 'blue' },
        { label: 'مرفوض', value: count(blocked.length), tone: 'red' },
      ])
      + (blocked.length
        ? `<div class="insight danger" style="margin-bottom:12px"><span class="insight-dot"></span><span>
            <b>${count(blocked.length)} سطراً مرفوضاً</b>
            <small>الخادم رفضها عند التحقّق. لا يُرحَّل سطر مرفوض مهما ظهر في الشاشة.</small></span></div>`
        : '')
      + (lines.length ? table(columns, lines) : empty('لا سطور في هذه الدفعة')));
  },
};

export const routes: Route[] = [batches, batchDetail, ...installationBatchRoutes];
