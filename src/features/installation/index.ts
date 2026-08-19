/**
 * أجور التنصيب — الشاشات التشغيلية.
 *
 * سجلّ المشتركين وملفّ الحالة هما أكبر ما كان ناقصاً: 5,693 مشتركاً بلا شاشة
 * تفتح واحداً منهم وتقول لماذا هو موقوف.
 */

import type { Route } from '../../app/router';
import { href } from '../../app/router';
import { rpc, pageRpc } from '../../services/api';
import { money, count } from '../../domain/money';
import { transferPanel, wireTransfer } from '../ownership/transfer';
import { classificationPanel } from './classification';
import { routes as holdRoutes, holdPanel, wireHoldPanel } from './holds';
import { routes as payoutRoutes } from './payout';
import { routes as invoiceRoutes } from './invoices';
import { routes as cycleRoutes } from './cycle';
import {
  esc, loading, empty, pageHeader, table, pager, kpiRow, chip,
  filterBar, wireFilters, type Column,
} from '../../components/ui';

type Row = Record<string, unknown>;
const num = (r: Row, k: string) => Number(r[k] || 0);
const str = (r: Row, k: string) => String(r[k] ?? '');

/**
 * العائدية: تصنيفٌ ثلاثي، لا اسمٌ بديل.
 *
 * الاسم الأصلي للأب يبقى معروضاً كما ورد في المصدر — hrins.office يظل
 * hrins.office. والتصنيف عمودٌ بجانبه يقول ما هو مالياً، لا يحلّ محلّه.
 * فالمشغّل الذي يبحث في ملف SaaS يجد ما يراه على الشاشة.
 */
export const OWNERSHIP_LABEL: Record<string, string> = {
  RESELLER: 'وكيل',
  DIRECT_COMPANY: 'الشركة',
  NEEDS_REVIEW: 'تحتاج مراجعة',
};

export function ownershipChip(type: string): string {
  const tone: 'info' | 'warning' | 'brand' = type === 'RESELLER' ? 'info'
    : type === 'NEEDS_REVIEW' ? 'warning' : 'brand';
  return chip(OWNERSHIP_LABEL[type] || type || '—', tone);
}

const STAGE_TONE: Record<string, 'success' | 'info' | 'warning' | 'neutral'> = {
  DONE: 'success', P4: 'info', P3: 'info', P2: 'warning', P1: 'warning', UNKNOWN: 'neutral',
};

/* ---- مركز التحكم -------------------------------------------------------- */

export const controlCenter: Route = {
  pattern: '/installation',
  capability: 'installation.view',
  title: 'أجور التنصيب',
  breadcrumb: () => [{ label: 'الرئيسية', href: href('/') }, { label: 'أجور التنصيب' }],
  async render(view) {
    view.write(loading('جارٍ تحميل حالة التنصيب…'));
    // حالة التصنيف تُقرأ من الخادم الآن، لا تُحسب في المتصفّح وتضيع.
    const [state, classState] = await Promise.all([
      rpc<Row>('installation_cycle_state', {}),
      rpc<Row>('classification_state', {}).catch(() => null),
    ]);
    const hist = (state?.['historical'] || {}) as Row;
    const ent = (state?.['entitlements'] || {}) as Row;
    const enroll = (state?.['enrollments'] || {}) as Record<string, number>;

    const stageRows = Object.entries(enroll).map(([k, v]) => ({ stage: k, n: v }));

    view.innerHTML = pageHeader('أجور التنصيب', 'مركز التحكّم التشغيلي')
      + kpiRow([
        { label: 'المشتركون', value: count(num(hist, 'subscribers')), tone: 'primary', link: href('/installation/subscribers') },
        { label: 'مدفوع تاريخياً', value: money(num(hist, 'paid')), tone: 'green', sub: `${count(num(hist, 'payment_rows'))} دفعة` },
        { label: 'مستحق حالي', value: money(num(ent, 'due')), tone: 'gold', link: href('/installation/ready') },
        { label: 'إيقافات فعّالة', value: count(num(state || {}, 'holds')), tone: 'red', link: href('/installation/holds') },
      ])
      + `<div class="grid2">
          <div class="box"><h3>توزيع المراحل</h3>
            ${stageRows.length
              ? stageRows.map((r) => `<div class="minirow"><span>${chip(r.stage, STAGE_TONE[r.stage] || 'neutral')}</span><b>${count(r.n)}</b></div>`).join('')
              : '<p class="muted">لا تسجيلات</p>'}</div>
          <div class="box"><h3>تصنيف الجِدّة</h3>
            ${classificationPanel(classState)}</div>
        </div>`;
  },
};

/* ---- سجلّ المشتركين ------------------------------------------------------ */

export const subscribers: Route = {
  pattern: '/installation/subscribers',
  capability: 'installation.view',
  title: 'المشتركون',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'أجور التنصيب', href: href('/installation') },
    { label: 'المشتركون' },
  ],
  async render(view, m) {
    const limit = 50;
    const offset = Number(m.query.get('offset') || 0);
    view.innerHTML = loading('جارٍ تحميل السجلّ…');

    const args: Record<string, unknown> = { p_limit: limit, p_offset: offset };
    for (const [q, p] of [['search', 'p_search'], ['agent', 'p_agent'], ['fdt', 'p_fdt'],
      ['zone', 'p_zone'], ['stage', 'p_stage'], ['ownership', 'p_ownership']] as const) {
      const v = m.query.get(q);
      if (v) args[p] = v;
    }
    if (m.query.get('hold') === 'true') args['p_has_hold'] = true;

    // الصدفة تفصل الإجمالي عن الصفوف، وتُمرَّر إشارة الإلغاء فيُهمَل ردُّ
    // شاشةٍ غادرها المستخدم.
    const page = await pageRpc<Row>('page_installation_subscribers', args, view.signal);

    const columns: Array<Column<Row>> = [
      { key: 'sid', label: 'المشترك', cell: (r) => `<b>${esc(str(r, 'subscriber_id'))}</b>` },
      { key: 'own', label: 'العائدية', cell: (r) => ownershipChip(str(r, 'ownership_type')) },
      // الاسم الأصلي كما ورد من المصدر — لا يُستبدَل بتسمية التصنيف.
      { key: 'agent', label: 'الوكيل / الأب', cell: (r) => esc(str(r, 'reseller') || '—') },
      { key: 'fdt', label: 'الكابينة', cell: (r) => esc(str(r, 'fdt') || '—') },
      { key: 'zone', label: 'المنطقة', cell: (r) => {
        const z = str(r, 'zone');
        return z ? chip(z === 'new' ? 'جديدة' : 'قديمة', z === 'new' ? 'success' : 'info') : '—';
      } },
      { key: 'stage', label: 'المرحلة', cell: (r) => {
        const s = str(r, 'stage_code');
        return chip(s, STAGE_TONE[s] || 'neutral');
      } },
      { key: 'status', label: 'التسجيل', cell: (r) => esc(str(r, 'enrollment_status')) },
      { key: 'paid', label: 'المدفوع', cell: (r) => `<span class="money">${money(num(r, 'paid_total'))}</span>`, numeric: true },
      { key: 'hold', label: 'إيقاف', cell: (r) => num(r, 'hold_count') > 0 ? chip('موقوف', 'critical') : '—' },
      { key: 'go', label: '', cell: (r) => `<a class="smallbtn" href="${esc(href(`/installation/subscribers/${encodeURIComponent(str(r, 'subscriber_id'))}`))}">فتح</a>` },
    ];

    view.innerHTML = pageHeader('سجلّ المشتركين', 'يُصفَّح ويُصفّى على الخادم — لا يُنقل الجدول إلى المتصفح')
      + filterBar([
        { key: 'search', label: 'بحث بالمعرّف أو الوكيل', type: 'search' },
        // ثلاثة أصناف مالية. أسماء الآباء ليست أصنافاً — تُعرض كما هي.
        { key: 'ownership', label: 'العائدية', type: 'select', options: [
          { value: 'RESELLER', label: 'وكيل' },
          { value: 'DIRECT_COMPANY', label: 'الشركة' },
          { value: 'NEEDS_REVIEW', label: 'تحتاج مراجعة' },
        ] },
        { key: 'stage', label: 'المراحل', type: 'select', options: ['P1', 'P2', 'P3', 'P4', 'DONE', 'UNKNOWN'].map((s) => ({ value: s, label: s })) },
        { key: 'zone', label: 'المناطق', type: 'select', options: [{ value: 'old', label: 'قديمة' }, { value: 'new', label: 'جديدة' }] },
        { key: 'hold', label: 'الإيقاف', type: 'select', options: [{ value: 'true', label: 'الموقوفون فقط' }] },
      ], '/installation/subscribers', m.query)
      // الصفحة خارج المدى تُقال صراحةً، ومعها الإجمالي الصادق — لا صفر صامت.
      + (page.outOfRange
        ? `<div class="insight warn"><span class="insight-dot"></span><span><b>الصفحة خارج المدى</b>
           <small>المجموعة فيها ${count(page.total)} صفّاً. عُد إلى الصفحة الأولى.</small></span></div>`
        : '')
      + (page.rows.length ? table(columns, page.rows as Row[], (r) => `location.hash='${href(`/installation/subscribers/${encodeURIComponent(str(r as Row, 'subscriber_id'))}`).slice(1)}'`) : empty('لا مشتركين مطابقين'))
      + pager(page.total, limit, offset, '/installation/subscribers', m.query);

    wireFilters(view.el);
  },
};

/* ---- ملفّ المشترك -------------------------------------------------------- */

const CASE_TABS = [
  { key: 'overview', label: 'نظرة عامة' },
  { key: 'ownership', label: 'العائدية' },
  { key: 'activations', label: 'التفعيلات' },
  { key: 'invoices', label: 'الفواتير' },
  { key: 'entitlements', label: 'الاستحقاقات' },
  { key: 'payments', label: 'الدفعات' },
  { key: 'holds', label: 'الإيقافات' },
  { key: 'history', label: 'التاريخ' },
  { key: 'audit', label: 'التدقيق' },
];

export const subscriberCase: Route = {
  pattern: '/installation/subscribers/:id',
  capability: 'installation.view',
  title: 'ملفّ المشترك',
  breadcrumb: (m) => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'أجور التنصيب', href: href('/installation') },
    { label: 'المشتركون', href: href('/installation/subscribers') },
    { label: m.params['id'] || 'مشترك' },
  ],
  async render(view, m) {
    const id = m.params['id'] as string;
    const tab = m.query.get('tab') || 'overview';
    view.innerHTML = loading('جارٍ تحميل ملفّ المشترك…');

    const [doc, next] = await Promise.all([
      rpc<Row>('installation_subscriber_case', { p_subscriber_id: id }),
      rpc<Row>('subscriber_next_action', { p_subscriber_id: id }).catch(() => null),
    ]);
    const sub = (doc?.['subscriber'] || null) as Row | null;
    if (!sub) { view.innerHTML = empty('المشترك غير موجود', id); return; }

    const enr = (doc?.['enrollment'] || {}) as Row;
    const totals = (doc?.['totals'] || {}) as Row;
    const holds = (doc?.['holds'] || []) as Row[];
    const activeHolds = holds.filter((h) => str(h, 'status') === 'ACTIVE');
    const stage = str(enr, 'stage') || 'UNKNOWN';

    const tabs = CASE_TABS.map((t) =>
      `<a class="tab${t.key === tab ? ' active' : ''}" href="${esc(href(`/installation/subscribers/${encodeURIComponent(id)}`, { tab: t.key }))}">${esc(t.label)}</a>`).join('');

    view.innerHTML = pageHeader(str(sub, 'subscriber_id'),
      `${esc(str(sub, 'reseller') || '—')} · كابينة ${esc(str(sub, 'fdt') || '—')}`,
      `${chip(stage, STAGE_TONE[stage] || 'neutral')}
       ${activeHolds.length ? chip('موقوف', 'critical') : chip('لا إيقاف', 'success')}`)
      + kpiRow([
        { label: 'المرحلة الحالية', value: esc(stage), tone: 'primary', sub: str(enr, 'status') },
        { label: 'المدفوع', value: money(num(totals, 'paid')), tone: 'green', sub: `${count(num(totals, 'payment_count'))} دفعة` },
        { label: 'المنطقة', value: esc(str(enr, 'zone') === 'new' ? 'جديدة' : str(enr, 'zone') === 'old' ? 'قديمة' : '—'), tone: 'blue' },
        { label: 'الإيقافات الفعّالة', value: count(activeHolds.length), tone: 'red' },
      ])
      + nextActionBanner(next)
      + `<div class="tabs">${tabs}</div><div class="panel active">${renderCaseTab(doc as Row, tab, id)}</div>`;

    // مفتاح المشترك هو ما تعرفه أحداث SaaS، وهو صغير الأحرف.
    if (tab === 'ownership') await wireTransfer(view, id.toLowerCase().trim());
    if (tab === 'holds') wireHoldPanel(view);

    if (tab === 'history') {
      const host = view.el.querySelector<HTMLElement>('#timelineHost');
      if (host) {
        try {
          const events = await rpc<Row[]>('subscriber_timeline', { p_subscriber_id: id });
          host.innerHTML = events && events.length ? timeline(events) : empty('لا أحداث');
        } catch {
          host.innerHTML = empty('تعذّر تحميل التاريخ');
        }
      }
    }
  },
};

/**
 * الإجراء التالي.
 *
 * قراءةٌ للحالة القائمة لا قاعدةٌ مالية جديدة: تقول أين يقف هذا المشترك
 * وأيّ شاشةٍ تحسمه، ولا تحسب مبلغاً. وترتيبها ترتيب الحجب — ما يمنع
 * الصرف قبل ما ينتظره — فلا يُرسَل المستخدم إلى شاشةٍ يحجبها شيء آخر.
 */
function nextActionBanner(doc: Row | null): string {
  const a = (doc?.['action'] || null) as Row | null;
  if (!a || str(a, 'code') === 'NONE') return '';
  const tone = str(a, 'tone');
  const cls = tone === 'critical' ? 'danger' : tone === 'success' ? 'good' : 'warn';
  const path = str(a, 'path');
  return `<div class="insight ${cls}" style="margin:12px 0"><span class="insight-dot"></span>
    <span><b>الإجراء التالي: ${esc(str(a, 'label'))}</b>
    <small>${esc(str(a, 'why'))}</small></span>
    ${path ? `<a class="btn gold" href="${esc(href(path))}">افتح</a>` : ''}</div>`;
}

function renderCaseTab(doc: Row, tab: string, id: string): string {
  const list = (k: string) => (doc[k] || []) as Row[];

  if (tab === 'ownership') return transferPanel();

  if (tab === 'entitlements') {
    const rows = list('entitlements');
    return rows.length ? table([
      { key: 'period', label: 'الفترة', cell: (r) => esc(str(r, 'period')) },
      { key: 'stage', label: 'المرحلة', cell: (r) => chip(str(r, 'stage'), STAGE_TONE[str(r, 'stage')] || 'neutral') },
      { key: 'amount', label: 'المبلغ', cell: (r) => `<span class="money">${money(num(r, 'amount'))}</span>`, numeric: true },
      { key: 'inv', label: 'الفاتورة', cell: (r) => esc(str(r, 'invoice_status') || '—') },
      { key: 'pay', label: 'الدفع', cell: (r) => esc(str(r, 'payment_status') || '—') },
    ] as Array<Column<Row>>, rows) : empty('لا استحقاقات');
  }

  if (tab === 'invoices') {
    const rows = list('invoices');
    return rows.length ? table([
      { key: 'num', label: 'الرقم', cell: (r) => esc(str(r, 'number') || '—') },
      { key: 'stage', label: 'المرحلة', cell: (r) => esc(str(r, 'stage')) },
      { key: 'amount', label: 'المبلغ', cell: (r) => money(num(r, 'amount')), numeric: true },
      { key: 'status', label: 'الحالة', cell: (r) => esc(str(r, 'status')) },
    ] as Array<Column<Row>>, rows) : empty('لا فواتير');
  }

  if (tab === 'payments') {
    const rows = list('payments');
    return rows.length ? table([
      { key: 'date', label: 'التاريخ', cell: (r) => esc(str(r, 'payment_date')) },
      { key: 'stage', label: 'المرحلة', cell: (r) => esc(str(r, 'stage')) },
      { key: 'amount', label: 'المبلغ', cell: (r) => `<span class="money">${money(num(r, 'amount'))}</span>`, numeric: true },
    ] as Array<Column<Row>>, rows) : empty('لا دفعات');
  }

  if (tab === 'holds') {
    const rows = list('holds');
    const listed = rows.length ? table([
      { key: 'reason', label: 'السبب', cell: (r) => esc(str(r, 'reason')) },
      { key: 'stage', label: 'المرحلة', cell: (r) => esc(str(r, 'stage') || '—') },
      { key: 'status', label: 'الحالة', cell: (r) => str(r, 'status') === 'ACTIVE' ? chip('فعّال', 'critical') : chip('مُفرَج', 'success') },
      { key: 'note', label: 'ملاحظة', cell: (r) => esc(str(r, 'note') || '—') },
    ] as Array<Column<Row>>, rows) : empty('لا إيقافات');
    // القائمة أوّلاً ثم لوحة التعليق: يُقرأ القائم قبل أن يُضاف إليه.
    return listed + holdPanel(id);
  }

  if (tab === 'activations' || tab === 'history' || tab === 'audit') {
    return `<div id="timelineHost">${tab === 'history' ? loading('جارٍ بناء التاريخ…') : empty('يُعرض في تبويب التاريخ', 'التاريخ يُشتقّ من الأحداث والدفتر والتدقيق')}</div>`;
  }

  // overview
  const enr = (doc['enrollment'] || {}) as Row;
  const ident = (doc['identity'] || {}) as Row;
  return `<div class="grid2">
    <div class="box"><h3>التسجيل</h3>
      <div class="minirow"><span class="muted">المرحلة</span><b>${esc(str(enr, 'stage') || '—')}</b></div>
      <div class="minirow"><span class="muted">الحالة</span><b>${esc(str(enr, 'status') || '—')}</b></div>
      <div class="minirow"><span class="muted">الأصل</span><b>${esc(str(enr, 'origin') || '—')}</b></div>
      <div class="minirow"><span class="muted">الوكيل وقت التسجيل</span><b>${esc(str(enr, 'agent_name') || '—')}</b></div>
    </div>
    <div class="box"><h3>الهوية</h3>
      <div class="minirow"><span class="muted">حالة الهوية</span><b>${esc(str(ident, 'identity_status') || '—')}</b></div>
      <div class="minirow"><span class="muted">طريقة المطابقة</span><b>${esc(str(ident, 'match_method') || '—')}</b></div>
      <div class="minirow"><span class="muted">التصنيف</span><b>${esc(str(ident, 'source_classification') || '—')}</b></div>
    </div></div>`;
}

/** الخطّ الزمني مُشتَقّ من المصادر المعتمدة — لا جدول يُحرَّر. */
function timeline(events: Row[]): string {
  const tone: Record<string, string> = {
    PAYMENT: 'good', ACTIVATION: 'good', HOLD: 'danger', INVOICE: 'warn', AUDIT: 'warn',
  };
  return `<div class="insight-list">${events.map((e) => `
    <div class="insight ${tone[str(e, 'kind')] || ''}">
      <span class="insight-dot"></span>
      <span><b>${esc(str(e, 'title'))}</b>
        <small>${esc(String(e['occurred_at'] ?? '').slice(0, 19).replace('T', ' '))}
        ${e['amount'] ? ' · ' + money(num(e, 'amount')) : ''}
        ${str(e, 'detail') ? ' · ' + esc(str(e, 'detail')) : ''}</small></span>
    </div>`).join('')}</div>`;
}

// «جاهز للصرف» و«التعليقات» انتقلتا إلى ملفَّيهما: الأولى صارت تجميعاً
// بالوكيل مع سطورٍ تحته، والثانية صارت تحمل نوع الحجب ومصدره وأجله.
export const routes: Route[] = [
  controlCenter, subscribers, subscriberCase,
  ...invoiceRoutes,
  ...cycleRoutes,
  ...payoutRoutes, ...holdRoutes,
];
