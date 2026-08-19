/**
 * جاهز للصرف — بالوكيل للمراجعة، وبالسطر للحقيقة.
 *
 * المراجعة المحاسبية تجري على الوكيل: كم مشتركاً، وكم من كل مرحلة، وكم
 * المجموع. لكن ما يُخزَّن ويُدقَّق سطرٌ لكل (مشترك + مرحلة + مبلغ)، فيُعرف
 * لاحقاً أيّ مشترك قُبض له وعن أيّ مرحلة وتحت أيّ دفعة.
 *
 * والأرقام هنا مرشّحة لا مستحقّة: مشتقّة من المتبقّي التاريخي المسجَّل، أي
 * من القسط التالي الذي لم يُدفع بعد. التسمية مقصودة كي لا يُقرأ رقمٌ
 * استكشافي على أنه التزامٌ مُقرّ.
 */

import type { Route } from '../../app/router';
import { href } from '../../app/router';
import { rpc, pageRpc } from '../../services/api';
import { money, count } from '../../domain/money';
import {
  esc, loading, empty, pageHeader, table, pager, kpiRow, chip,
  filterBar, wireFilters, type Column,
} from '../../components/ui';

type Row = Record<string, unknown>;
const num = (r: Row, k: string) => Number(r[k] || 0);
const str = (r: Row, k: string) => String(r[k] ?? '');

const STAGE_AMOUNT: Record<string, number> = { P1: 3000, P2: 3000, P3: 3000, P4: 4000 };

/* ---- التجميع بالوكيل ----------------------------------------------------- */

export const readyForPayment: Route = {
  pattern: '/installation/ready',
  capability: 'installation.view',
  title: 'جاهز للصرف',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'أجور التنصيب', href: href('/installation') },
    { label: 'جاهز للصرف' },
  ],
  async render(view) {
    view.write(loading('جارٍ حساب المرشّحين…'));

    const doc = await rpc<Row>('installation_payout_candidates');
    if (!view.live) return;

    const resellers = (doc?.['by_reseller'] || []) as Row[];
    const byStage = (doc?.['by_stage'] || {}) as Record<string, Row>;
    const held = num(doc || {}, 'held');
    const unresolved = num(doc || {}, 'unresolved');

    const columns: Array<Column<Row>> = [
      { key: 'r', label: 'الوكيل', cell: (r) => `<b>${esc(str(r, 'reseller'))}</b>` },
      { key: 'n', label: 'المشتركون', cell: (r) => count(num(r, 'subscribers')), numeric: true },
      { key: 'p1', label: 'P1', cell: (r) => count(num(r, 'p1')), numeric: true },
      { key: 'p2', label: 'P2', cell: (r) => count(num(r, 'p2')), numeric: true },
      { key: 'p3', label: 'P3', cell: (r) => count(num(r, 'p3')), numeric: true },
      { key: 'p4', label: 'P4', cell: (r) => count(num(r, 'p4')), numeric: true },
      { key: 'held', label: 'محجوب', cell: (r) =>
        num(r, 'held') ? chip(count(num(r, 'held')), 'critical') : '—', numeric: true },
      { key: 'ready', label: 'جاهز', cell: (r) => count(num(r, 'ready')), numeric: true },
      { key: 'amt', label: 'المجموع', cell: (r) =>
        `<span class="money">${money(num(r, 'amount'))}</span>`, numeric: true },
      { key: 'go', label: '', cell: (r) =>
        `<a class="smallbtn" href="${esc(href('/installation/ready/lines', { reseller: str(r, 'reseller') }))}">افتح السطور</a>` },
    ];

    view.innerHTML = pageHeader('جاهز للصرف',
      'مرشّحون من المتبقّي التاريخي — القسط التالي لكل مشترك، لا إعادة بناءٍ لما دُفع')

      + kpiRow([
        { label: 'المشتركون المرشّحون', value: count(num(doc || {}, 'subscribers')), tone: 'primary' },
        { label: 'المبلغ المرشّح', value: money(num(doc || {}, 'amount')), tone: 'gold',
          sub: 'قسطٌ واحد لكل مشترك' },
        { label: 'محجوب بتعليق', value: held ? count(held) : '—', tone: 'red',
          sub: held ? money(num(doc || {}, 'held_amount')) : 'لا تعليقات سارية',
          link: href('/installation/holds', { status: 'EFFECTIVE' }) },
        { label: 'غير محسوم', value: unresolved ? count(unresolved) : '—', tone: 'blue',
          sub: 'حالة تاريخية غير محسومة لا تُدفع' },
      ])

      + `<div class="box" style="margin-top:12px">
        <h3>حسب المرحلة</h3>
        ${['P1', 'P2', 'P3', 'P4'].filter((s) => byStage[s]).map((s) => {
          const row = byStage[s] as Row;
          return `<div class="minirow">
            <span>${chip(s, 'info')}
              <span class="muted">${count(num(row, 'subscribers'))} × ${money(STAGE_AMOUNT[s] || 0)}</span></span>
            <b class="money">${money(num(row, 'amount'))}</b></div>`;
        }).join('') || '<p class="muted">لا مرشّحين</p>'}
      </div>`

      + `<div class="insight warn" style="margin-top:12px"><span class="insight-dot"></span><span>
          <b>مرشّح لا مستحقّ</b>
          <small>هذه الأرقام مشتقّة من المتبقّي المسجَّل. لا تصير مستحقّة إلا بعد
          فحص الفاتورة والتعليق والأهلية على الخادم، ولا تُدفع إلا بتأكيدٍ
          صريح يحمل تاريخ الدفع ورقم الإشعار.</small></span></div>`

      + (resellers.length ? table(columns, resellers) : empty('لا مرشّحين للصرف'));
  },
};

/* ---- سطور وكيلٍ واحد ----------------------------------------------------- */

export const readyLines: Route = {
  pattern: '/installation/ready/lines',
  capability: 'installation.view',
  title: 'سطور الصرف',
  breadcrumb: (m) => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'أجور التنصيب', href: href('/installation') },
    { label: 'جاهز للصرف', href: href('/installation/ready') },
    { label: m.query.get('reseller') || 'السطور' },
  ],
  async render(view, m) {
    const limit = 50;
    const offset = Number(m.query.get('offset') || 0);
    view.innerHTML = loading('جارٍ تحميل السطور…');

    const args: Record<string, unknown> = { p_limit: limit, p_offset: offset };
    const reseller = m.query.get('reseller');
    const stage = m.query.get('stage');
    const only = m.query.get('ready');
    if (reseller) args['p_reseller'] = reseller;
    if (stage) args['p_stage'] = stage;
    if (only === 'true') args['p_only_ready'] = true;
    if (only === 'false') args['p_only_ready'] = false;

    const page = await pageRpc<Row>('page_payout_candidate_lines', args, view.signal);
    if (!view.live) return;

    const columns: Array<Column<Row>> = [
      { key: 'sid', label: 'المشترك', cell: (r) =>
        `<a dir="ltr" href="${esc(href(`/installation/subscribers/${encodeURIComponent(str(r, 'subscriber_id'))}`))}">${esc(str(r, 'subscriber_id'))}</a>` },
      // الاسم كما ورد من المصدر — لا يُستبدل بتسمية تصنيف.
      { key: 'res', label: 'الوكيل / الأب', cell: (r) => esc(str(r, 'reseller') || '—') },
      { key: 'stage', label: 'المرحلة', cell: (r) => chip(str(r, 'stage'), 'info') },
      { key: 'amt', label: 'المبلغ', cell: (r) =>
        `<span class="money">${money(num(r, 'amount'))}</span>`, numeric: true },
      { key: 'inv', label: 'الفاتورة', cell: (r) =>
        r['invoice_ok'] === true ? chip('مدقَّقة', 'success') : chip('غير مدقَّقة', 'warning') },
      { key: 'hold', label: 'التعليق', cell: (r) => {
        if (r['held'] !== true) return '—';
        const why = str(r, 'hold_reason');
        return `${chip('معلَّق', 'critical')}${why ? ` <span class="muted">${esc(why)}</span>` : ''}`;
      } },
      { key: 'elig', label: 'الأهلية', cell: (r) =>
        r['payment_eligible'] === true && str(r, 'resolution') === 'resolved'
          ? chip('محسوم', 'success') : chip('غير محسوم', 'warning') },
      { key: 'state', label: 'الحالة', cell: (r) =>
        r['is_ready'] === true ? chip('جاهز', 'success') : chip('محجوب', 'critical') },
    ];

    view.innerHTML = pageHeader(reseller ? `سطور ${reseller}` : 'سطور الصرف',
      'سطرٌ لكل مشترك ومرحلة — هذه وحدة التخزين والتدقيق')
      + filterBar([
        { key: 'stage', label: 'المرحلة', type: 'select',
          options: ['P1', 'P2', 'P3', 'P4'].map((s) => ({ value: s, label: s })) },
        { key: 'ready', label: 'الحالة', type: 'select', options: [
          { value: 'true', label: 'الجاهزون فقط' },
          { value: 'false', label: 'المحجوبون فقط' },
        ] },
      ], '/installation/ready/lines', m.query)
      + (page.outOfRange
        ? `<div class="insight warn"><span class="insight-dot"></span><span><b>الصفحة خارج المدى</b>
           <small>المجموعة فيها ${count(page.total)} سطراً.</small></span></div>`
        : '')
      + (page.rows.length ? table(columns, page.rows) : empty('لا سطور مطابقة'))
      + pager(page.total, limit, offset, '/installation/ready/lines', m.query);

    wireFilters(view.el);
  },
};

export const routes: Route[] = [readyForPayment, readyLines];
