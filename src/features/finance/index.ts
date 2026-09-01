/**
 * المالية — دفعات الصرف.
 *
 * لا قرار مالي في المتصفح. الشاشة تعرض حالة الخادم، والترحيل يمرّ بـ
 * post_commission_batch بعد إعادة تحقّق الخادم — والرفض يُعرَض بنصّه لا
 * يُستبَق بمنطق في الواجهة.
 */

import type { Route, View } from '../../app/router';
import { href } from '../../app/router';
import { rpc, select, toPage, can } from '../../services/api';
import { money, count } from '../../domain/money';
import {
  esc, loading, empty, pageHeader, table, pager, chip, kpiRow, type Column,
} from '../../components/ui';
import { routes as installationBatchRoutes } from './installation-batches';
import { correctionActionsCell, correctionBox, wireCorrectionActions } from './paymentCorrections';

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
      // معرّف الدفع هو snapshot_id لا id السطر: هو ما يقرأه الدفتر
      // (post_commission_batch يكتب source_id = snapshot_id)، فتصحيح أو عكس
      // سطرٍ مدفوع يجب أن يشير إلى القيد نفسه لا إلى سطر الدفعة الوسيط.
      { key: 'act', label: '', cell: (r) =>
        correctionActionsCell('commission', str(r, 'snapshot_id'), str(r, 'status') === 'PAID', num(r, 'amount')) },
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
      + postPanel(batch, blocked.length)
      + (lines.length ? table(columns, lines) : empty('لا سطور في هذه الدفعة'))
      + correctionBox());

    wirePost(view, id, str(batch, 'name') || 'الدفعة');
    wireCorrectionActions(view);
  },
};

/* ---- الترحيل ------------------------------------------------------------- */

/**
 * التحقّق ثم الترحيل — خطوتان لا واحدة.
 *
 * الترحيل يُنشئ مالاً في الدفتر، فلا يُدمج مع التحقّق في زرٍّ واحد: بين
 * تجهيز الدفعة وترحيلها قد يتغيّر ما يجعل سطراً غير مستحقّ، والتحقّق يُظهر
 * ذلك قبل أن يصير قيداً.
 *
 * والمرجع إلزامي: قيدٌ في الدفتر بلا مرجع بنكيّ لا يُطابَق لاحقاً بشيء.
 */
function postPanel(batch: Row, blocked: number): string {
  const status = str(batch, 'status');
  if (status === 'POSTED' || status === 'PAID') {
    return `<div class="insight good" style="margin-bottom:12px"><span class="insight-dot"></span><span>
      <b>رُحِّلت هذه الدفعة</b>
      <small>المرجع ${esc(str(batch, 'payment_reference') || '—')} ·
        ${esc(str(batch, 'posted_at').slice(0, 10) || '—')}. الترحيل لا يُعاد.</small></span></div>`;
  }
  if (status === 'CANCELLED') {
    return `<div class="insight warn" style="margin-bottom:12px"><span class="insight-dot"></span><span>
      <b>أُلغيت هذه الدفعة</b><small>لا تُرحَّل.</small></span></div>`;
  }
  if (!can('commission.execute_payment')) {
    return `<div class="box" style="margin-bottom:12px">
      <p class="muted">العرض فقط — الترحيل يحتاج صلاحية
      <code dir="ltr">commission.execute_payment</code>.</p></div>`;
  }
  return `<div class="box" style="margin-bottom:12px" id="postBox">
    <h3>التحقّق والترحيل</h3>
    <p class="muted" style="font-size:11px;margin:0 0 10px">
      التحقّق يُعيد فحص كل سطر عند الخادم ويُحدِّث المرفوض.
      ${blocked ? `يوجد ${count(blocked)} سطراً مرفوضاً — الخادم لا يُرحّلها.` : ''}
      والترحيل يُنشئ القيد في الدفتر ولا يُعاد.</p>
    <div class="toolbar">
      <button class="btn" id="pbCheck">تحقّق</button>
      <input class="search" id="pbRef" placeholder="المرجع البنكي (إلزامي للترحيل)"
        aria-label="المرجع البنكي" dir="ltr">
      <button class="btn gold" id="pbPost">رحِّل</button>
    </div>
    <div id="pbResult"></div>
  </div>`;
}

function wirePost(view: View, id: string, name: string): void {
  const box = view.el.querySelector<HTMLElement>('#postBox');
  if (!box) return;
  const check = box.querySelector<HTMLButtonElement>('#pbCheck');
  const ref = box.querySelector<HTMLInputElement>('#pbRef');
  const post = box.querySelector<HTMLButtonElement>('#pbPost');
  const out = box.querySelector<HTMLElement>('#pbResult');
  if (!out) return;

  check?.addEventListener('click', async () => {
    check.disabled = true;
    out.innerHTML = loading('جارٍ إعادة التحقّق…');
    try {
      const res = await rpc<Row>('revalidate_commission_batch', { p_batch_id: id });
      if (!view.live) return;
      const stillBlocked = num(res, 'blocked');
      out.innerHTML = insight(stillBlocked ? 'warn' : 'good',
        stillBlocked ? `${count(stillBlocked)} سطراً ما زال مرفوضاً` : 'كل السطور مقبولة',
        stillBlocked ? 'الخادم لن يُرحّل المرفوض.' : '');
      window.setTimeout(() => { if (view.live) window.location.reload(); }, 1500);
    } catch (error) {
      if (!view.live) return;
      out.innerHTML = insight('danger', 'تعذّر التحقّق',
        error instanceof Error ? error.message : 'خطأ غير متوقّع');
    } finally {
      check.disabled = false;
    }
  });

  post?.addEventListener('click', async () => {
    const reference = ref?.value.trim() || '';
    if (!reference) {
      out.innerHTML = insight('warn', 'المرجع إلزامي',
        'قيدٌ في الدفتر بلا مرجع لا يُطابَق لاحقاً');
      return;
    }
    if (!window.confirm(
      `ترحيل «${name}» بالمرجع ${reference}؟ يُنشئ قيداً في الدفتر ولا يُعاد.`)) return;
    post.disabled = true;
    out.innerHTML = loading('جارٍ الترحيل…');
    try {
      await rpc<Row>('post_commission_batch', {
        p_batch_id: id,
        p_payment_reference: reference,
        p_request_id: crypto.randomUUID(),
      });
      if (!view.live) return;
      out.innerHTML = insight('good', 'رُحِّلت الدفعة');
      window.setTimeout(() => { if (view.live) window.location.reload(); }, 1500);
    } catch (error) {
      if (!view.live) return;
      out.innerHTML = insight('danger', 'لم تُرحَّل الدفعة',
        error instanceof Error ? error.message : 'خطأ غير متوقّع');
    } finally {
      post.disabled = false;
    }
  });
}

function insight(tone: 'good' | 'warn' | 'danger', title: string, detail = ''): string {
  return `<div class="insight ${tone}" style="margin-top:10px"><span class="insight-dot"></span><span>
    <b>${esc(title)}</b>${detail ? `<small>${esc(detail)}</small>` : ''}</span></div>`;
}

export const routes: Route[] = [batches, batchDetail, ...installationBatchRoutes];
