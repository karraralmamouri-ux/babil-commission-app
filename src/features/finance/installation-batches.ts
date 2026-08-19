/**
 * دفعات صرف أجور التنصيب.
 *
 * الدفعة وحدة العمل، والسطر وحدة الحقيقة. وإنشاء الدفعة ليس دفعاً: تولد
 * مسوّدةً، وتحتاج تحقّقاً يُعيد فحص كل سطر، ثم تأكيداً صريحاً يحمل تاريخ
 * الدفع ورقم الإشعار الخارجي.
 *
 * ولا قرار مالي هنا. الشاشة تعرض ما يقوله الخادم وتطلب منه الفعل؛ الرفض
 * يُعرض بنصّه كما ورد — لا يُستبَق بمنطقٍ في المتصفّح.
 */

import type { Route, View } from '../../app/router';
import { href } from '../../app/router';
import { rpc, pageRpc, can, ApiError } from '../../services/api';
import { money, count } from '../../domain/money';
import {
  esc, loading, empty, pageHeader, table, pager, kpiRow, chip, type Column,
} from '../../components/ui';

type Row = Record<string, unknown>;
const num = (r: Row, k: string) => Number(r[k] || 0);
const str = (r: Row, k: string) => String(r[k] ?? '');
const when = (v: unknown) => (v ? String(v).replace('T', ' ').slice(0, 16) : '—');

const STATUS: Record<string, { label: string; tone: 'success' | 'warning' | 'info' | 'neutral' | 'critical' }> = {
  DRAFT:     { label: 'مسوّدة', tone: 'warning' },
  VALIDATED: { label: 'مُتحقَّق منها', tone: 'info' },
  READY:     { label: 'جاهزة للدفع', tone: 'info' },
  PAID:      { label: 'مدفوعة', tone: 'success' },
  CANCELLED: { label: 'ملغاة', tone: 'neutral' },
};

const ITEM_STATUS: Record<string, { label: string; tone: 'success' | 'warning' | 'critical' | 'neutral' }> = {
  PENDING: { label: 'جاهز', tone: 'warning' },
  PAID:    { label: 'مدفوع', tone: 'success' },
  BLOCKED: { label: 'محجوب', tone: 'critical' },
  SKIPPED: { label: 'مُخرَج', tone: 'neutral' },
};

/* ---- قائمة الدفعات ------------------------------------------------------- */

export const installationBatches: Route = {
  pattern: '/finance/installation-batches',
  capability: 'payment.view',
  title: 'دفعات التنصيب',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'المالية' },
    { label: 'دفعات التنصيب' },
  ],
  async render(view, m) {
    const limit = 50;
    const offset = Number(m.query.get('offset') || 0);
    view.innerHTML = loading('جارٍ تحميل الدفعات…');

    const args: Record<string, unknown> = { p_limit: limit, p_offset: offset };
    const status = m.query.get('status');
    if (status) args['p_status'] = status;

    const page = await pageRpc<Row>('page_installation_batches', args, view.signal);
    if (!view.live) return;

    const paid = page.rows.filter((r) => str(r, 'status') === 'PAID');
    const open = page.rows.filter((r) => ['DRAFT', 'VALIDATED', 'READY'].includes(str(r, 'status')));

    const columns: Array<Column<Row>> = [
      { key: 'name', label: 'الدفعة', cell: (r) =>
        `<a href="${esc(href(`/finance/installation-batches/${encodeURIComponent(str(r, 'id'))}`))}">
           <b>${esc(str(r, 'name'))}</b></a>` },
      { key: 'status', label: 'الحالة', cell: (r) => {
        const s = STATUS[str(r, 'status')];
        return chip(s ? s.label : str(r, 'status'), s?.tone || 'neutral');
      } },
      { key: 'items', label: 'السطور', cell: (r) => count(num(r, 'item_count')), numeric: true },
      { key: 'blocked', label: 'محجوب', cell: (r) =>
        num(r, 'blocked_count') ? chip(count(num(r, 'blocked_count')), 'critical') : '—', numeric: true },
      { key: 'amount', label: 'المبلغ', cell: (r) =>
        `<span class="money">${money(num(r, 'total_amount'))}</span>`, numeric: true },
      { key: 'ref', label: 'الإشعار', cell: (r) =>
        str(r, 'payment_ref') ? `<span dir="ltr">${esc(str(r, 'payment_ref'))}</span>` : '—' },
      { key: 'date', label: 'تاريخ الدفع', cell: (r) =>
        str(r, 'payment_date') ? `<span dir="ltr">${esc(str(r, 'payment_date'))}</span>` : '—' },
      { key: 'by', label: 'رحّلها', cell: (r) => esc(str(r, 'posted_by_email') || '—') },
    ];

    view.innerHTML = pageHeader('دفعات صرف التنصيب',
      'الدفعة وحدة العمل، والسطر وحدة الحقيقة — والإنشاء ليس دفعاً')

      + kpiRow([
        { label: 'دفعات مفتوحة', value: count(open.length), tone: 'primary',
          sub: money(open.reduce((a, r) => a + num(r, 'total_amount'), 0)) },
        { label: 'مدفوعة', value: count(paid.length), tone: 'green',
          sub: money(paid.reduce((a, r) => a + num(r, 'total_amount'), 0)) },
        { label: 'سطور محجوبة', value:
          count(page.rows.reduce((a, r) => a + num(r, 'blocked_count'), 0)), tone: 'red',
          sub: 'تمنع تأكيد دفعتها' },
        { label: 'الإجمالي', value: count(page.total), tone: 'blue' },
      ])

      + (can('payment.prepare')
        ? `<div class="box" style="margin-bottom:12px">
            <h3>إنشاء دفعة</h3>
            <p class="muted" style="font-size:11px;margin:0 0 8px">
              تضمّ الاستحقاقات التي تجتاز الفحص وقت الإنشاء. تولد مسوّدةً،
              ويُعاد فحص كل سطر قبل الدفع.</p>
            <div class="toolbar">
              <input class="search" id="nbName" placeholder="اسم الدفعة" aria-label="اسم الدفعة">
              <input class="search" id="nbPeriod" placeholder="الفترة YYYY-MM"
                aria-label="الفترة" dir="ltr">
              <input class="search" id="nbReseller" placeholder="الوكيل (اختياري)"
                aria-label="الوكيل">
              <button class="btn gold" id="nbCreate">أنشئ مسوّدة</button>
            </div>
            <div id="nbResult"></div>
          </div>`
        : '')

      + (page.rows.length ? table(columns, page.rows) : empty('لا دفعات بعد'))
      + pager(page.total, limit, offset, '/finance/installation-batches', m.query);

    wireCreate(view);
  },
};

function wireCreate(view: View): void {
  const create = view.el.querySelector<HTMLButtonElement>('#nbCreate');
  const out = view.el.querySelector<HTMLElement>('#nbResult');
  if (!create || !out) return;

  create.addEventListener('click', async () => {
    const name = view.el.querySelector<HTMLInputElement>('#nbName')?.value.trim() || '';
    const period = view.el.querySelector<HTMLInputElement>('#nbPeriod')?.value.trim() || '';
    const reseller = view.el.querySelector<HTMLInputElement>('#nbReseller')?.value.trim() || '';
    if (!name) {
      out.innerHTML = insight('warn', 'الدفعة تحتاج اسماً');
      return;
    }
    create.disabled = true;
    out.innerHTML = loading('جارٍ الإنشاء…');
    try {
      const r = await rpc<Row>('create_installation_batch', {
        p_name: name,
        p_reseller: reseller || null,
        p_period: period || null,
        p_request_id: crypto.randomUUID(),
      });
      if (!view.live) return;
      out.innerHTML = r?.['idempotent'] === true
        ? insight('good', 'هذه الدفعة منشأة مسبقاً')
        : insight('good', `أُنشئت مسوّدة بـ${count(num(r, 'items'))} سطراً`,
            `${money(num(r, 'amount'))} — لم يُدفع شيء بعد.`);
      window.setTimeout(() => { if (view.live) window.location.reload(); }, 1200);
    } catch (error) {
      if (!view.live) return;
      out.innerHTML = insight('danger', 'لم تُنشأ الدفعة',
        error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
    } finally {
      create.disabled = false;
    }
  });
}

/* ---- تفصيل الدفعة -------------------------------------------------------- */

export const installationBatchDetail: Route = {
  pattern: '/finance/installation-batches/:id',
  capability: 'payment.view',
  title: 'دفعة تنصيب',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'دفعات التنصيب', href: href('/finance/installation-batches') },
    { label: 'التفصيل' },
  ],
  async render(view, m) {
    const id = m.params['id'] as string;
    view.innerHTML = loading('جارٍ تحميل الدفعة…');

    const doc = await rpc<Row>('installation_batch_detail', { p_batch_id: id });
    if (!view.live) return;
    const batch = (doc?.['batch'] || null) as Row | null;
    if (!batch) { view.innerHTML = empty('الدفعة غير موجودة', id); return; }

    const lines = (doc?.['lines'] || []) as Row[];
    const byReseller = (doc?.['by_reseller'] || []) as Row[];
    const byStage = (doc?.['by_stage'] || {}) as Record<string, Row>;
    const status = str(batch, 'status');
    const meta = STATUS[status];
    const blocked = num(batch, 'blocked_count');
    const settled = status === 'PAID' || status === 'CANCELLED';

    const columns: Array<Column<Row>> = [
      { key: 'sid', label: 'المشترك', cell: (r) =>
        `<a dir="ltr" href="${esc(href(`/installation/subscribers/${encodeURIComponent(str(r, 'subscriber_id'))}`))}">${esc(str(r, 'subscriber_id'))}</a>` },
      { key: 'agent', label: 'الوكيل / الأب', cell: (r) => esc(str(r, 'agent_name') || '—') },
      { key: 'stage', label: 'المرحلة', cell: (r) => chip(str(r, 'stage_code'), 'info') },
      { key: 'amount', label: 'المبلغ', cell: (r) =>
        `<span class="money">${money(num(r, 'amount'))}</span>`, numeric: true },
      { key: 'status', label: 'الحالة', cell: (r) => {
        const s = ITEM_STATUS[str(r, 'status')];
        return chip(s ? s.label : str(r, 'status'), s?.tone || 'neutral');
      } },
      { key: 'why', label: 'سبب الحجب', cell: (r) =>
        str(r, 'blocked_reason')
          ? `<span class="muted" dir="ltr" style="font-size:10px">${esc(str(r, 'blocked_reason'))}</span>`
          : '—' },
    ];

    view.innerHTML = pageHeader(str(batch, 'name'),
      `${count(num(batch, 'item_count'))} سطراً · ${money(num(batch, 'total_amount'))}`,
      chip(meta ? meta.label : status, meta?.tone || 'neutral'))

      + kpiRow([
        { label: 'المبلغ', value: money(num(batch, 'total_amount')), tone: 'primary' },
        { label: 'السطور', value: count(num(batch, 'item_count')), tone: 'blue' },
        { label: 'محجوب', value: blocked ? count(blocked) : '—', tone: 'red',
          sub: blocked ? 'يمنع التأكيد' : 'لا حاجب' },
        { label: 'تاريخ الدفع', value: str(batch, 'payment_date') || '—', tone: 'gold',
          sub: str(batch, 'payment_ref') || 'لم تُدفع بعد' },
      ])

      + `<div class="grid2" style="margin-top:12px">
          <div class="box"><h3>حسب المرحلة</h3>
            ${Object.entries(byStage).map(([s, v]) => `<div class="minirow">
              <span>${chip(s, 'info')} <span class="muted">${count(num(v as Row, 'n'))} سطراً</span></span>
              <b class="money">${money(num(v as Row, 'amount'))}</b></div>`).join('')
              || '<p class="muted">لا سطور</p>'}
          </div>
          <div class="box"><h3>حسب الوكيل</h3>
            ${byReseller.map((r) => `<div class="minirow">
              <span>${esc(str(r, 'reseller') || '—')}
                ${num(r, 'blocked') ? chip(`${count(num(r, 'blocked'))} محجوب`, 'critical') : ''}</span>
              <span><b>${count(num(r, 'n'))}</b>
                <span class="money">${money(num(r, 'amount'))}</span></span></div>`).join('')
              || '<p class="muted">لا سطور</p>'}
          </div>
        </div>`

      + `<div class="box" style="margin-top:12px">
          <h3>المسار</h3>
          <div class="minirow"><span class="muted">أُنشئت</span>
            <span>${esc(when(batch['prepared_at']))} · ${esc(str(batch, 'prepared_by') || '—')}</span></div>
          <div class="minirow"><span class="muted">تُحقِّق منها</span>
            <span>${esc(when(batch['validated_at']))}</span></div>
          <div class="minirow"><span class="muted">رُحِّلت</span>
            <span>${esc(when(batch['posted_at']))} · ${esc(str(batch, 'posted_by') || '—')}</span></div>
          ${str(batch, 'cancel_reason')
            ? `<div class="minirow"><span class="muted">أُلغيت</span>
               <span>${esc(when(batch['cancelled_at']))} — ${esc(str(batch, 'cancel_reason'))}</span></div>`
            : ''}
        </div>`

      + (settled ? '' : actionPanel(status, blocked))

      + (lines.length ? table(columns, lines) : empty('لا سطور في هذه الدفعة'));

    if (!settled) wireBatchActions(view, id);
  },
};

/**
 * أفعال الدفعة.
 *
 * التأكيد يطلب تاريخاً وإشعاراً خارجياً لأن الخادم يشترطهما بقيدٍ على
 * الجدول — والشاشة تقولهما إلزاميَّين بدل أن يكتشفهما المستخدم برفض.
 */
function actionPanel(status: string, blocked: number): string {
  const canPrepare = can('payment.prepare');
  const canExecute = can('payment.execute');
  if (!canPrepare && !canExecute) {
    return `<div class="box" style="margin-top:12px">
      <p class="muted">تحتاج صلاحية <code>payment.prepare</code> أو
      <code>payment.execute</code> للتصرّف في هذه الدفعة.</p></div>`;
  }
  const payable = ['VALIDATED', 'READY'].includes(status) && blocked === 0;
  return `<div class="box" style="margin-top:12px" id="batchActions">
    <h3>الإجراءات</h3>
    ${canPrepare ? `<div class="actions" style="margin-bottom:10px">
      <button class="btn" id="baValidate">أعِد التحقّق من كل سطر</button>
      <button class="btn" id="baCancel">ألغِ الدفعة</button>
    </div>` : ''}
    ${canExecute ? `
      <div class="toolbar">
        <input class="search" type="date" id="baDate" aria-label="تاريخ الدفع">
        <input class="search" id="baRef" placeholder="رقم الإشعار الخارجي (إلزامي)"
          aria-label="رقم الإشعار" dir="ltr">
        <input class="search" id="baNote" placeholder="ملاحظة (اختيارية)" aria-label="ملاحظة">
        <button class="btn gold" id="baConfirm"${payable ? '' : ' disabled'}>أكِّد الدفع</button>
      </div>
      <p class="muted" style="font-size:11px;margin-top:6px">
        ${blocked
          ? `فيها ${count(blocked)} سطراً محجوباً — يُحسم أو يُخرَج قبل الدفع.`
          : status === 'DRAFT'
            ? 'مسوّدة: أعِد التحقّق أوّلاً.'
            : 'يُعاد فحص كل سطر داخل معاملة الدفع، فما تغيّر يظهر الآن.'}</p>`
      : ''}
    <div id="baResult"></div>
  </div>`;
}

function wireBatchActions(view: View, id: string): void {
  const box = view.el.querySelector<HTMLElement>('#batchActions');
  if (!box) return;
  const out = box.querySelector<HTMLElement>('#baResult');
  if (!out) return;

  const run = async (btn: HTMLButtonElement | null, label: string,
                     fn: () => Promise<Row>, ok: (r: Row) => string) => {
    if (!btn) return;
    btn.addEventListener('click', async () => {
      btn.disabled = true;
      out.innerHTML = loading(label);
      try {
        const r = await fn();
        if (!view.live) return;
        out.innerHTML = ok(r);
        window.setTimeout(() => { if (view.live) window.location.reload(); }, 1400);
      } catch (error) {
        if (!view.live) return;
        // نصّ الخادم كما ورد: هو الذي يعرف لماذا رُفض.
        out.innerHTML = insight('danger', 'رُفض الإجراء',
          error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
      } finally {
        btn.disabled = false;
      }
    });
  };

  run(box.querySelector('#baValidate'), 'جارٍ إعادة التحقّق…',
    () => rpc<Row>('revalidate_installation_batch', { p_batch_id: id }),
    (r) => insight(num(r, 'blocked') ? 'warn' : 'good',
      `جاهز ${count(num(r, 'ready'))} · محجوب ${count(num(r, 'blocked'))}`,
      `المجموع ${money(num(r, 'total_amount'))}`));

  run(box.querySelector('#baCancel'), 'جارٍ الإلغاء…',
    () => {
      const reason = window.prompt('سبب الإلغاء؟') || '';
      if (!reason.trim()) throw new ApiError('الإلغاء يحتاج سبباً');
      return rpc<Row>('cancel_installation_batch', {
        p_batch_id: id, p_reason: reason, p_request_id: crypto.randomUUID() });
    },
    () => insight('good', 'أُلغيت الدفعة', 'سطورها خرجت منها ولم يُدفع شيء.'));

  const confirm = box.querySelector<HTMLButtonElement>('#baConfirm');
  if (confirm) {
    confirm.addEventListener('click', async () => {
      const date = box.querySelector<HTMLInputElement>('#baDate')?.value || '';
      const ref = box.querySelector<HTMLInputElement>('#baRef')?.value.trim() || '';
      const note = box.querySelector<HTMLInputElement>('#baNote')?.value.trim() || '';
      if (!date) { out.innerHTML = insight('warn', 'الدفع يحتاج تاريخاً'); return; }
      if (!ref) { out.innerHTML = insight('warn', 'الدفع يحتاج رقم إشعار خارجي'); return; }

      confirm.disabled = true;
      out.innerHTML = loading('جارٍ تأكيد الدفع…');
      try {
        const r = await rpc<Row>('confirm_installation_batch_payment', {
          p_batch_id: id, p_payment_date: date, p_reference: ref,
          p_note: note || null, p_request_id: crypto.randomUUID(),
        });
        if (!view.live) return;
        out.innerHTML = r?.['idempotent'] === true
          ? insight('good', 'هذه الدفعة مؤكَّدة مسبقاً')
          : insight('good', `دُفع ${count(num(r, 'lines_paid'))} سطراً`,
              `${money(num(r, 'amount'))} · إشعار ${esc(str(r, 'reference'))}`);
        window.setTimeout(() => { if (view.live) window.location.reload(); }, 1600);
      } catch (error) {
        if (!view.live) return;
        out.innerHTML = insight('danger', 'لم يُؤكَّد الدفع',
          error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
      } finally {
        confirm.disabled = false;
      }
    });
  }
}

function insight(tone: 'good' | 'warn' | 'danger', title: string, detail = ''): string {
  return `<div class="insight ${tone}" style="margin-top:10px"><span class="insight-dot"></span><span>
    <b>${esc(title)}</b>${detail ? `<small>${detail}</small>` : ''}</span></div>`;
}

export const routes: Route[] = [installationBatches, installationBatchDetail];
