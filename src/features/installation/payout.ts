/**
 * جاهز للصرف — بالوكيل للمراجعة، وبالسطر للحقيقة.
 *
 * المراجعة المحاسبية تجري على الوكيل: كم مشتركاً، وكم من كل مرحلة، وكم
 * المجموع. لكن ما يُخزَّن ويُدقَّق سطرٌ لكل (مشترك + مرحلة + مبلغ)، فيُعرف
 * لاحقاً أيّ مشترك قُبض له وعن أيّ مرحلة وتحت أيّ دفعة.
 *
 * والحجب مصنَّف لا رقمٌ واحد. «محجوب = صفر» كانت تعني «لا تعليقات» لا «لا
 * شيء يمنع الصرف»، فيقرأ المشغّل صفراً ويفهم أن المال جاهز بينما كل
 * المرشّحين محجوبون بفاتورةٍ غير مدقَّقة. كل صنفٍ يُعدّ الآن وحده، ولكلٍّ
 * شاشةٌ تحسمه.
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

/** كل صنف حجب: اسمه، ولونه، والشاشة التي تحسمه. */
export const BLOCKER: Record<string, { label: string; tone: 'critical' | 'warning' | 'info'; path: string }> = {
  HOLD:        { label: 'تعليق', tone: 'critical', path: '/installation/holds' },
  INVOICE:     { label: 'فاتورة', tone: 'warning', path: '/installation/invoices' },
  SOURCE:      { label: 'حالة تاريخية', tone: 'warning', path: '/installation/subscribers' },
  IDENTITY:    { label: 'تعارض هوية', tone: 'warning', path: '/installation/subscribers' },
  PARENT:      { label: 'عائدية', tone: 'info', path: '/master/parents' },
  ELIGIBILITY: { label: 'أهلية', tone: 'warning', path: '/installation/subscribers' },
  FDT:         { label: 'كابينة', tone: 'warning', path: '/legacy' },
  OTHER:       { label: 'أخرى', tone: 'warning', path: '/installation/subscribers' },
};

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
    const blocked = (doc?.['blocked'] || {}) as Record<string, number>;
    const blockedAmt = (doc?.['blocked_amount'] || {}) as Record<string, number>;
    const ready = num(doc || {}, 'ready');

    const columns: Array<Column<Row>> = [
      { key: 'r', label: 'الوكيل', cell: (r) => `<b>${esc(str(r, 'reseller'))}</b>` },
      { key: 'n', label: 'المرشّحون', cell: (r) => count(num(r, 'subscribers')), numeric: true },
      { key: 'amt', label: 'المبلغ المرشّح', cell: (r) =>
        `<span class="money">${money(num(r, 'amount'))}</span>`, numeric: true },
      { key: 'p1', label: 'P1', cell: (r) => count(num(r, 'p1')), numeric: true },
      { key: 'p2', label: 'P2', cell: (r) => count(num(r, 'p2')), numeric: true },
      { key: 'p3', label: 'P3', cell: (r) => count(num(r, 'p3')), numeric: true },
      { key: 'p4', label: 'P4', cell: (r) => count(num(r, 'p4')), numeric: true },
      { key: 'bh', label: 'محجوب — تعليق', cell: (r) => blockCell(r, 'blocked_hold'), numeric: true },
      { key: 'bi', label: 'محجوب — فاتورة', cell: (r) => blockCell(r, 'blocked_invoice'), numeric: true },
      { key: 'be', label: 'محجوب — أهلية', cell: (r) => blockCell(r, 'blocked_eligibility'), numeric: true },
      { key: 'bo', label: 'محجوب — أخرى', cell: (r) => blockCell(r, 'blocked_other'), numeric: true },
      { key: 'ready', label: 'جاهز', cell: (r) => {
        const n = num(r, 'ready');
        return n ? `<b>${count(n)}</b>` : '<span class="muted">0</span>';
      }, numeric: true },
      { key: 'ramt', label: 'المبلغ الجاهز', cell: (r) =>
        num(r, 'ready_amount') ? `<span class="money">${money(num(r, 'ready_amount'))}</span>` : '—',
        numeric: true },
      { key: 'go', label: '', cell: (r) =>
        `<a class="smallbtn" href="${esc(href('/installation/ready/lines', { reseller: str(r, 'reseller') }))}">السطور</a>` },
    ];

    view.innerHTML = pageHeader('جاهز للصرف',
      'مرشّحون من المتبقّي التاريخي — القسط التالي لكل مشترك، لا إعادة بناءٍ لما دُفع')

      + kpiRow([
        { label: 'المرشّحون', value: count(num(doc || {}, 'subscribers')), tone: 'primary',
          sub: money(num(doc || {}, 'amount')) },
        { label: 'جاهز فعلاً', value: count(ready), tone: ready ? 'green' : 'blue',
          sub: ready ? money(num(doc || {}, 'ready_amount')) : 'لا أحد اجتاز كل الفحوص بعد' },
        { label: 'محجوب (أيّ سبب)', value: count(Number(blocked['any'] || 0)), tone: 'red',
          sub: money(Number(blockedAmt['any'] || 0)) },
        { label: 'أكبر حاجب', value: topBlocker(blocked), tone: 'gold',
          sub: 'يُحسم في شاشته' },
      ])

      // الحجب مصنَّفاً: صفرٌ في صنفٍ لا يعني أن الطريق سالك.
      + `<div class="box" style="margin-top:12px">
        <h3>ما الذي يمنع الصرف</h3>
        <p class="muted" style="font-size:11px;margin:0 0 8px">
          مشتركٌ واحد قد يحجبه أكثر من سبب، فمجموع الأصناف قد يفوق عدد المحجوبين.
          «جاهز» يعني خلوّه من كل صنف لا من واحد.</p>
        ${['hold', 'invoice', 'source', 'identity', 'parent'].map((k) => {
          const key = k.toUpperCase();
          const meta = BLOCKER[key];
          const n = Number(blocked[k] || 0);
          return `<a class="minirow" style="text-decoration:none;color:inherit"
              href="${esc(href('/installation/ready/lines', { blocker: key }))}">
              <span>${chip(meta ? meta.label : k, n ? (meta?.tone || 'warning') : 'neutral')}
                ${n ? '' : '<span class="muted">لا أحد</span>'}</span>
              <span><b>${count(n)}</b>
                <span class="money">${money(Number(blockedAmt[k] || 0))}</span></span></a>`;
        }).join('')}
      </div>`

      + `<div class="box" style="margin-top:12px">
        <h3>حسب المرحلة</h3>
        ${['P1', 'P2', 'P3', 'P4'].filter((s) => byStage[s]).map((s) => {
          const row = byStage[s] as Row;
          return `<div class="minirow">
            <span>${chip(s, 'info')}
              <span class="muted">${count(num(row, 'subscribers'))} × ${money(STAGE_AMOUNT[s] || 0)}</span></span>
            <span><b class="money">${money(num(row, 'amount'))}</b>
              <span class="muted">جاهز ${count(num(row, 'ready'))}</span></span></div>`;
        }).join('') || '<p class="muted">لا مرشّحين</p>'}
      </div>`

      + `<div class="insight warn" style="margin-top:12px"><span class="insight-dot"></span><span>
          <b>مرشّح لا مستحقّ</b>
          <small>هذه الأرقام مشتقّة من المتبقّي المسجَّل. لا تصير جاهزة للصرف إلا بعد
          فحص الفاتورة والتعليق والأهلية على الخادم، ولا تُدفع إلا بتأكيدٍ
          صريح يحمل تاريخ الدفع ورقم الإشعار.</small></span></div>`

      + (resellers.length ? table(columns, resellers) : empty('لا مرشّحين للصرف'));
  },
};

function blockCell(r: Row, key: string): string {
  const n = num(r, key);
  return n ? `<b>${count(n)}</b>` : '<span class="muted">—</span>';
}

/** أكبر حاجب: يقود المشغّل إلى ما يفتح أكبر مبلغ بأقلّ عمل. */
function topBlocker(blocked: Record<string, number>): string {
  const entries = ['hold', 'invoice', 'source', 'identity', 'parent']
    .map((k) => [k, Number(blocked[k] || 0)] as const)
    .sort((a, b) => b[1] - a[1]);
  const top = entries[0];
  if (!top || top[1] === 0) return '—';
  const meta = BLOCKER[top[0].toUpperCase()];
  return esc(meta ? meta.label : top[0]);
}

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
    const blocker = m.query.get('blocker');
    const search = m.query.get('search');
    if (reseller) args['p_reseller'] = reseller;
    if (stage) args['p_stage'] = stage;
    if (blocker) args['p_blocker'] = blocker;
    if (search) args['p_search'] = search;
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
      // كل ما يحجب السطر، لا أوّل سبب فقط.
      { key: 'blockers', label: 'ما الذي يمنعه', cell: (r) => {
        const list = (r['blockers'] || []) as string[];
        if (!Array.isArray(list) || !list.length) return chip('لا مانع', 'success');
        return list.map((b) => {
          const meta = BLOCKER[b];
          return chip(meta ? meta.label : b, meta?.tone || 'warning');
        }).join(' ');
      } },
      { key: 'why', label: 'التفصيل', cell: (r) => {
        const why = str(r, 'hold_reason');
        return why ? `<span class="muted">${esc(why)}</span>` : '—';
      } },
      { key: 'state', label: 'الحالة', cell: (r) =>
        r['is_ready'] === true ? chip('جاهز', 'success') : chip('محجوب', 'critical') },
    ];

    view.innerHTML = pageHeader(reseller ? `سطور ${reseller}` : 'سطور الصرف',
      'سطرٌ لكل مشترك ومرحلة — هذه وحدة التخزين والتدقيق')
      + filterBar([
        { key: 'search', label: 'بحث بالمشترك أو الوكيل', type: 'search' },
        { key: 'stage', label: 'المرحلة', type: 'select',
          options: ['P1', 'P2', 'P3', 'P4'].map((s) => ({ value: s, label: s })) },
        { key: 'blocker', label: 'الحاجب', type: 'select',
          options: Object.entries(BLOCKER).map(([k, v]) => ({ value: k, label: v.label })) },
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
