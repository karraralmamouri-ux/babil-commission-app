/**
 * التقارير والأرشيف.
 *
 * القاعدة الحاكمة: المجموع والتفصيل من استعلامٍ واحد على الخادم. الشاشة لا
 * تجمع ولا تحسب — تعرض `summary` كما جاء، وتُصفِّح `page` من المجموعة نفسها.
 * فإذا صُدِّر التقرير، صُدِّر ما عُرض بعينه.
 *
 * لا حساب مالي في المتصفّح: أوّل مكانٍ يفترق فيه المجموع عن التفصيل هو شرطٌ
 * يُنسى في أحدهما.
 */

import type { Route, View } from '../../app/router';
import { href } from '../../app/router';
import { rpc, select, envelope } from '../../services/api';
import { money, count } from '../../domain/money';
import { dateTime } from '../../domain/time';
import { readCycleResult, knownAgentTotal, cycleStatusAr, currentCycleId } from '../../domain/cycle';
import {
  esc, loading, empty, pageHeader, table, pager, kpiRow, chip,
  filterBar, wireFilters, type Column,
} from '../../components/ui';

type Row = Record<string, unknown>;
const num = (r: Row, k: string) => Number(r[k] || 0);
const str = (r: Row, k: string) => String(r[k] ?? '');
const when = (v: unknown) => (v ? dateTime(v) : '—');

/* ---- فهرس التقارير ------------------------------------------------------- */

const REPORTS = [
  { key: 'commission', label: 'نتيجة العمولات', path: '/reports/commissions',
    hint: 'نتيجة الدورة ومصالحة الوكلاء المعروفين مع الملكية غير المحسومة' },
  { key: 'installation', label: 'أجور التنصيب', path: '/reports/installation',
    hint: 'الاستحقاقات بمراحلها ووكلائها وحالة دفعها' },
  { key: 'historical', label: 'المدفوع تاريخياً', path: '/reports/historical',
    hint: 'الأساس المستورد — 17,117 صفّاً لا يُدفع ثانية' },
  { key: 'payments', label: 'حركات الدفتر', path: '/reports/payments',
    hint: 'الدفعات والعكوس والتسويات' },
  { key: 'exceptions', label: 'الاستثناءات والتعرّض', path: '/work',
    hint: 'ما يحجب المال، مجمَّعاً بوحدة حسمه' },
  { key: 'archive', label: 'الأرشيف', path: '/reports/archive',
    hint: 'الدورات والدفعات والاستيرادات ونسخ المخططات' },
];

export const reportsIndex: Route = {
  pattern: '/reports',
  capability: 'report.view',
  title: 'التقارير',
  breadcrumb: () => [{ label: 'الرئيسية', href: href('/') }, { label: 'التقارير' }],
  render(view) {
    view.innerHTML = pageHeader('التقارير',
      'المجموع والتفصيل من مصدرٍ واحد — ما يُعرض هو ما يُصدَّر')
      + `<div class="grid2">
        ${REPORTS.map((r) => `<a class="box" style="text-decoration:none;color:inherit"
            href="${esc(href(r.path))}">
            <h3>${esc(r.label)}</h3>
            <p class="muted" style="font-size:11px;margin:0">${esc(r.hint)}</p>
          </a>`).join('')}
      </div>`;
  },
};

/* ---- تقرير نتيجة العمولات ----------------------------------------------- */

export const commissionReport: Route = {
  pattern: '/reports/commissions',
  capability: 'report.view',
  title: 'تقرير نتيجة العمولات',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'التقارير', href: href('/reports') },
    { label: 'نتيجة العمولات' },
  ],
  async render(view, m) {
    view.write(loading('جارٍ تحميل نتيجة العمولات…'));
    // القائمة تبقى كاملةً ليُختار منها صراحةً، أمّا الافتراضي فمن الخادم:
    // أحدثُ دورةٍ قد تكون مسوّدةً فارغة، وتقريرها حينئذٍ صفرٌ لدورةٍ خاطئة.
    const [cycles, current] = await Promise.all([
      select<Row[]>('commission_cycles?select=id,name,status&order=period_start.desc'),
      currentCycleId(),
    ]);
    const id = m.query.get('cycle') || current || '';
    if (!id) {
      view.write(pageHeader('تقرير نتيجة العمولات')
        + empty(cycles.length ? 'لا دورة عمولة عاملة — اختر دورةً صراحةً' : 'لا دورات عمولة'));
      return;
    }
    const report = await rpc<Row>('commission_report_product', { p_cycle_id: id });
    const result = await readCycleResult(id);
    if (!result) { view.write(pageHeader('تقرير نتيجة العمولات') + empty('لا نتيجة محسوبة للدورة')); return; }
    if (!view.live) return;

    const unresolved = result.unresolved_ownership;
    const rows: Row[] = (report?.['rows'] || []) as Row[];

    const columns: Array<Column<Row>> = [
      { key: 'agent', label: 'الوكيل', cell: (r) => r['agent_id'] ? `<a href="${esc(href(`/commissions/agents/${str(r,'agent_id')}`))}"><b>${esc(str(r, 'agent_name'))}</b></a>` : `<b>${esc(str(r,'agent_name'))}</b>` },
      { key: 'zone', label: 'المنطقة / FDT', cell: (r) => `${esc(str(r,'zone') === 'new' ? 'جديدة' : 'قديمة')}<div class="muted">${esc(str(r,'fdt_code'))}</div>` },
      { key: 'tier', label: 'الشريحة', cell: (r) => esc(str(r,'tier_code') || '—') },
      { key: 'packs', label: 'P35 / P45 / P65', cell: (r) => `${count(num(r,'p35_count'))} / ${count(num(r,'p45_count'))} / ${count(num(r,'p65_count'))}`, numeric: true },
      { key: 'events', label: 'المؤهلة', cell: (r) => count(num(r, 'qualifying_events')), numeric: true },
      { key: 'basis', label: 'أساس الشريحة', cell: (r) => count(num(r, 'tier_basis')), numeric: true },
      { key: 'calc', label: 'محسوب', cell: (r) => money(num(r,'calculated')), numeric: true },
      { key: 'approved', label: 'معتمد', cell: (r) => money(num(r,'approved')), numeric: true },
      { key: 'ready', label: 'جاهز', cell: (r) => money(num(r,'ready')), numeric: true },
      { key: 'paid', label: 'مدفوع', cell: (r) => money(num(r,'paid')), numeric: true },
    ];

    view.innerHTML = pageHeader('تقرير نتيجة العمولات',
      `${result.cycle.name} · ${cycleStatusAr(result.cycle.status)}`)
      + kpiRow([
        { label: 'محسوب', value: money(result.totals.gross), tone: 'primary' },
        { label: 'معتمد', value: money(result.totals.approved), tone: 'green' },
        { label: 'جاهز للصرف', value: money(result.totals.ready), tone: 'gold' },
        { label: 'مدفوع', value: money(result.totals.paid), tone: 'blue' },
        { label: 'ملكية غير محسومة', value: money(unresolved.amount), tone: unresolved.amount ? 'red' : 'green',
          sub: `${count(unresolved.events)} تفعيلات`, link: href('/work/ownership') },
      ])
      + filterBar([{ key: 'cycle', label: 'الدورة', type: 'select', options: cycles.map((c) => ({
        value: str(c, 'id'), label: `${str(c, 'name')} — ${cycleStatusAr(str(c, 'status'))}`,
      })) }], '/reports/commissions', m.query)
      + `<div class="box report-reconciliation"><h3>المصالحة</h3>
          <div class="minirow"><span>منسوب لوكلاء معروفين</span><b class="money">${money(knownAgentTotal(result))}</b></div>
          <div class="minirow"><span>ملكية تحتاج حسم</span><b class="money">${money(unresolved.amount)}</b></div>
          <div class="minirow"><span><b>إجمالي الدورة</b></span><b class="money">${money(result.totals.gross)}</b></div>
        </div>`
      + (unresolved.amount ? `<div class="insight warn"><span class="insight-dot"></span><span><b>ملكية تحتاج حسم — ${money(unresolved.amount)}</b><small>تبقى خارج صفوف الوكلاء حتى يصدر قرار بدليل.</small></span><a class="btn" href="${esc(href('/work/ownership'))}">افتح القرار</a></div>` : '')
      + exportBar()
      + table(columns, rows);

    wireFilters(view.el);
    wireExport(view, 'commission-result', rows, [
      ['agent_name', 'الوكيل'], ['zone', 'المنطقة'], ['fdt_code', 'FDT'], ['tier_code','الشريحة'],
      ['p35_count','P35'],['p45_count','P45'],['p65_count','P65'],
      ['qualifying_events', 'التفعيلات المؤهلة'], ['tier_basis', 'أساس الشريحة'],
      ['calculated', 'المحسوب'],['approved','المعتمد'],['ready','الجاهز'],['paid','المدفوع'],
    ], { 'المحسوب': result.totals.gross, 'المعتمد': result.totals.approved,
      'المدفوع': result.totals.paid, 'الملكية غير المحسومة': unresolved.amount });
  },
};

/* ---- تقرير أجور التنصيب -------------------------------------------------- */

const STAGE_TONE: Record<string, 'info'> = { P1: 'info', P2: 'info', P3: 'info', P4: 'info' };

export const installationReport: Route = {
  pattern: '/reports/installation',
  capability: 'report.view',
  title: 'تقرير أجور التنصيب',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'التقارير', href: href('/reports') },
    { label: 'أجور التنصيب' },
  ],
  async render(view, m) {
    const limit = 50;
    const offset = Number(m.query.get('offset') || 0);
    view.innerHTML = loading('جارٍ بناء التقرير…');

    const args: Record<string, unknown> = { p_limit: limit, p_offset: offset };
    for (const [q, p] of [['period', 'p_period'], ['reseller', 'p_reseller'],
      ['stage', 'p_stage']] as const) {
      const v = m.query.get(q);
      if (v) args[p] = v;
    }

    const doc = await rpc<Row>('report_installation_fees', args);
    if (!view.live) return;

    const summary = (doc?.['summary'] || {}) as Row;
    const page = envelope<Row>(doc?.['page']);
    const byStage = (summary['by_stage'] || {}) as Record<string, Row>;
    const byReseller = (summary['by_reseller'] || []) as Row[];

    const columns: Array<Column<Row>> = [
      { key: 'sid', label: 'المشترك', cell: (r) =>
        `<a dir="ltr" href="${esc(href(`/installation/subscribers/${encodeURIComponent(str(r, 'subscriber_id'))}`))}">${esc(str(r, 'subscriber_id'))}</a>` },
      { key: 'res', label: 'الوكيل / الأب', cell: (r) => esc(str(r, 'reseller') || '—') },
      { key: 'period', label: 'الفترة', cell: (r) => `<span dir="ltr">${esc(str(r, 'period'))}</span>` },
      { key: 'stage', label: 'المرحلة', cell: (r) => chip(str(r, 'stage'), STAGE_TONE[str(r, 'stage')] || 'neutral') },
      { key: 'amount', label: 'المبلغ', cell: (r) =>
        `<span class="money">${money(num(r, 'amount'))}</span>`, numeric: true },
      { key: 'inv', label: 'الفاتورة', cell: (r) => esc(str(r, 'invoice_status') || '—') },
      { key: 'pay', label: 'الدفع', cell: (r) =>
        str(r, 'payment_status') === 'paid'
          ? chip('مدفوع', 'success') : chip(str(r, 'payment_status') || '—', 'warning') },
      { key: 'paid', label: 'المدفوع', cell: (r) =>
        num(r, 'paid_amount') ? `<span class="money">${money(num(r, 'paid_amount'))}</span>` : '—',
        numeric: true },
    ];

    view.innerHTML = pageHeader('تقرير أجور التنصيب',
      'المجموع أدناه من المجموعة نفسها التي تُصفَّح — لا حساب في المتصفّح')

      + kpiRow([
        { label: 'الاستحقاقات', value: count(num(summary, 'entitlements')), tone: 'primary' },
        { label: 'المجموع', value: money(num(summary, 'total_amount')), tone: 'gold' },
        { label: 'المدفوع', value: money(num(summary, 'paid_amount')), tone: 'green',
          sub: `${count(num(summary, 'paid_count'))} استحقاقاً` },
        { label: 'المتبقّي', value: money(num(summary, 'due_amount')), tone: 'blue' },
      ])

      + filterBar([
        { key: 'period', label: 'الفترة YYYY-MM', type: 'search' },
        { key: 'stage', label: 'المرحلة', type: 'select',
          options: ['P1', 'P2', 'P3', 'P4'].map((s) => ({ value: s, label: s })) },
      ], '/reports/installation', m.query)

      + (Object.keys(byStage).length || byReseller.length
        ? `<div class="grid2" style="margin-top:12px">
            <div class="box"><h3>حسب المرحلة</h3>
              ${Object.entries(byStage).map(([s, v]) => `<div class="minirow">
                <span>${chip(s, 'info')} <span class="muted">${count(num(v as Row, 'n'))}</span></span>
                <b class="money">${money(num(v as Row, 'amount'))}</b></div>`).join('')
                || '<p class="muted">لا بيانات</p>'}
            </div>
            <div class="box"><h3>حسب الوكيل</h3>
              ${byReseller.map((r) => `<div class="minirow">
                <span>${esc(str(r, 'reseller') || '—')}</span>
                <span><b>${count(num(r, 'n'))}</b>
                  <span class="money">${money(num(r, 'amount'))}</span></span></div>`).join('')
                || '<p class="muted">لا بيانات</p>'}
            </div>
          </div>`
        : '')

      + exportBar()
      + (page.rows.length ? table(columns, page.rows) : empty('لا استحقاقات مطابقة'))
      + pager(page.total, limit, offset, '/reports/installation', m.query);

    wireFilters(view.el);
    wireExport(view, 'installation-fees', page.rows, [
      ['subscriber_id', 'المشترك'], ['reseller', 'الوكيل'], ['period', 'الفترة'],
      ['stage', 'المرحلة'], ['amount', 'المبلغ'], ['invoice_status', 'الفاتورة'],
      ['payment_status', 'الدفع'], ['paid_amount', 'المدفوع'],
    ], { 'المجموع': num(summary, 'total_amount'), 'الاستحقاقات': num(summary, 'entitlements') });
  },
};

/* ---- المدفوع تاريخياً ---------------------------------------------------- */

export const historicalReport: Route = {
  pattern: '/reports/historical',
  capability: 'report.view',
  title: 'المدفوع تاريخياً',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'التقارير', href: href('/reports') },
    { label: 'المدفوع تاريخياً' },
  ],
  async render(view, m) {
    const limit = 50;
    const offset = Number(m.query.get('offset') || 0);
    view.innerHTML = loading('جارٍ تحميل السجلّ التاريخي…');

    const args: Record<string, unknown> = { p_limit: limit, p_offset: offset };
    const search = m.query.get('search');
    const stage = m.query.get('stage');
    if (search) args['p_search'] = search;
    if (stage) args['p_stage'] = stage;

    const raw = await rpc<Row>('page_historical_payments', args);
    if (!view.live) return;
    const page = envelope<Row>(raw);
    const sum = Number((raw as Row)?.['sum_amount'] || 0);

    const columns: Array<Column<Row>> = [
      { key: 'sid', label: 'المشترك', cell: (r) =>
        `<a dir="ltr" href="${esc(href(`/installation/subscribers/${encodeURIComponent(str(r, 'subscriber_id'))}`))}">${esc(str(r, 'subscriber_id'))}</a>` },
      { key: 'res', label: 'الوكيل / الأب', cell: (r) => esc(str(r, 'reseller') || '—') },
      { key: 'stage', label: 'المرحلة', cell: (r) => chip(str(r, 'stage'), 'info') },
      { key: 'amount', label: 'المبلغ', cell: (r) =>
        `<span class="money">${money(num(r, 'amount'))}</span>`, numeric: true },
      { key: 'date', label: 'تاريخ الدفع', cell: (r) =>
        `<span dir="ltr">${esc(String(r['payment_date'] ?? '').slice(0, 10) || '—')}</span>` },
    ];

    view.innerHTML = pageHeader('المدفوع تاريخياً',
      'الأساس المستورد — مدفوعٌ سلفاً ولا يُدفع ثانية')

      + kpiRow([
        { label: 'صفوف الدفع', value: count(page.total), tone: 'primary' },
        { label: 'المجموع', value: money(sum), tone: 'green' },
        { label: 'الحالة', value: 'مُقفَل', tone: 'blue', sub: 'لا يُعاد حسابه' },
        { label: 'الأثر', value: 'يحدّد القسط التالي', tone: 'gold',
          link: href('/installation/ready') },
      ])

      + `<div class="insight good" style="margin-top:12px"><span class="insight-dot"></span><span>
          <b>هذا السجلّ لا يُدفع ثانية</b>
          <small>المتبقّي المسجَّل لكل مشترك هو ما يحدّد قسطه القادم. ولا
          يُعاد بناء مرحلةٍ ماضية منه.</small></span></div>`

      + filterBar([
        { key: 'search', label: 'بحث بالمشترك أو الوكيل', type: 'search' },
        { key: 'stage', label: 'المرحلة', type: 'select',
          options: ['P1', 'P2', 'P3', 'P4'].map((s) => ({ value: s, label: s })) },
      ], '/reports/historical', m.query)

      + exportBar()
      + (page.rows.length ? table(columns, page.rows) : empty('لا صفوف مطابقة'))
      + pager(page.total, limit, offset, '/reports/historical', m.query);

    wireFilters(view.el);
    wireExport(view, 'historical-payments', page.rows, [
      ['subscriber_id', 'المشترك'], ['reseller', 'الوكيل'], ['stage', 'المرحلة'],
      ['amount', 'المبلغ'], ['payment_date', 'التاريخ'],
    ], { 'المجموع': sum, 'الصفوف': page.total });
  },
};

/* ---- حركات الدفتر -------------------------------------------------------- */

export const paymentsReport: Route = {
  pattern: '/reports/payments',
  capability: 'report.view',
  title: 'حركات الدفتر',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'التقارير', href: href('/reports') },
    { label: 'حركات الدفتر' },
  ],
  async render(view, m) {
    const limit = 50;
    const offset = Number(m.query.get('offset') || 0);
    view.innerHTML = loading('جارٍ تحميل الحركات…');

    const doc = await rpc<Row>('report_payment_history', { p_limit: limit, p_offset: offset });
    if (!view.live) return;
    const summary = (doc?.['summary'] || {}) as Row;
    const page = envelope<Row>(doc?.['page']);

    const columns: Array<Column<Row>> = [
      { key: 'at', label: 'الوقت', cell: (r) => `<span dir="ltr">${esc(when(r['created_at']))}</span>` },
      { key: 'type', label: 'النوع', cell: (r) => {
        const t = str(r, 'txn_type');
        return chip(t, t === 'PAYMENT' ? 'success' : t === 'REVERSAL' ? 'critical' : 'warning');
      } },
      { key: 'sid', label: 'المشترك', cell: (r) => `<span dir="ltr">${esc(str(r, 'subscriber_id') || '—')}</span>` },
      { key: 'agent', label: 'الوكيل', cell: (r) => esc(str(r, 'agent_name') || '—') },
      { key: 'stage', label: 'المرحلة', cell: (r) => esc(str(r, 'stage') || '—') },
      { key: 'amount', label: 'المبلغ', cell: (r) =>
        `<span class="money">${money(num(r, 'amount'))}</span>
         <div class="muted table-hint">${num(r, 'direction') < 0 ? 'قيد عكسي' : 'قيد مالي'}</div>`, numeric: true },
      { key: 'batch', label: 'الدفعة', cell: (r) => esc(str(r, 'batch_name') || '—') },
      { key: 'ref', label: 'الإشعار', cell: (r) =>
        str(r, 'payment_ref') ? `<span dir="ltr">${esc(str(r, 'payment_ref'))}</span>` : '—' },
    ];

    view.innerHTML = pageHeader('حركات الدفتر',
      'المال المُرحَّل — لا يُعدَّل، ويُصحَّح بقيدٍ مقابل')

      + kpiRow([
        { label: 'القيود', value: count(num(summary, 'entries')), tone: 'primary' },
        { label: 'الصافي', value: money(num(summary, 'total_amount')), tone: 'gold' },
        { label: 'دفعات', value: count(num(summary, 'payments')), tone: 'green' },
        { label: 'عكوس / تسويات', value:
          `${count(num(summary, 'reversals'))} / ${count(num(summary, 'adjustments'))}`, tone: 'red' },
      ])

      + exportBar()
      + (page.rows.length ? table(columns, page.rows) : empty('لا حركات في الدفتر'))
      + pager(page.total, limit, offset, '/reports/payments', m.query);

    wireExport(view, 'ledger', page.rows, [
      ['created_at', 'الوقت'], ['txn_type', 'النوع'], ['subscriber_id', 'المشترك'],
      ['agent_name', 'الوكيل'], ['stage', 'المرحلة'], ['amount', 'المبلغ'],
      ['batch_name', 'الدفعة'], ['payment_ref', 'الإشعار'],
    ], { 'الصافي': num(summary, 'total_amount'), 'القيود': num(summary, 'entries') });
  },
};

/* ---- الأرشيف ------------------------------------------------------------- */

export const archive: Route = {
  pattern: '/reports/archive',
  capability: 'report.view',
  title: 'الأرشيف',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'التقارير', href: href('/reports') },
    { label: 'الأرشيف' },
  ],
  async render(view) {
    view.write(loading('جارٍ تحميل الأرشيف…'));

    const doc = await rpc<Row>('archive_overview', {});
    if (!view.live) return;

    const cycles = (doc?.['commission_cycles'] || []) as Row[];
    const batches = (doc?.['installation_batches'] || []) as Row[];
    const imports = (doc?.['imports'] || []) as Row[];
    const schemes = (doc?.['scheme_versions'] || []) as Row[];
    const totals = (doc?.['totals'] || {}) as Row;

    const settledChip = (r: Row) =>
      r['settled'] === true ? chip('مكتمل', 'success') : chip('غير مكتمل', 'warning');
    const closedCycles = cycles.filter((r) => str(r, 'status') === 'CLOSED');
    const openHistoricalCycles = cycles.filter((r) => str(r, 'status') !== 'CLOSED');
    const cycleTable = (rows: Row[]) => table<Row>([
      { key: 'name', label: 'الدورة', cell: (r) => `<b>${esc(str(r, 'name'))}</b>` },
      { key: 'period', label: 'المدى', cell: (r) =>
        `<span dir="ltr">${esc(str(r, 'period_start'))} → ${esc(str(r, 'period_end'))}</span>` },
      { key: 'status', label: 'الحالة', cell: (r) => chip(cycleStatusAr(str(r, 'status')),
        str(r, 'status') === 'CLOSED' ? 'success' : 'warning') },
      { key: 'settled', label: 'الاكتمال', cell: settledChip },
      { key: 'fin', label: 'وقت الاعتماد', cell: (r) => `<span dir="ltr">${esc(when(r['finalized_at']))}</span>` },
    ], rows);

    view.innerHTML = pageHeader('الأرشيف',
      'قراءةٌ محضة — الأرشيف مرجعٌ لا سلطةٌ ثانية على المال')

      + kpiRow([
        { label: 'المدفوع تاريخياً', value: money(num(totals, 'historical_paid')), tone: 'green',
          sub: `${count(num(totals, 'historical_rows'))} صفّاً`,
          link: href('/reports/historical') },
        { label: 'دورات العمولة', value: count(cycles.length), tone: 'primary' },
        { label: 'دفعات التنصيب', value: count(batches.length), tone: 'blue' },
        { label: 'قيود الدفتر', value: count(num(totals, 'ledger_entries')), tone: 'gold',
          link: href('/reports/payments') },
      ])

      + `<div class="insight good" style="margin-top:12px"><span class="insight-dot"></span><span>
          <b>لا كتابة من هنا</b>
          <small>كل ما في هذه الشاشة قراءة. التصحيح يمرّ بالدفتر، والتعديل
          بمساحته — لا سلطتان على المال.</small></span></div>`

      + (openHistoricalCycles.length ? `<div class="box archive-unfinished-cycles">
          <h3>دورات تاريخها قديم لكنها غير مكتملة</h3>
          <div class="insight warn"><span class="insight-dot"></span><span><b>ليست أرشيفاً مقفلاً</b>
            <small>قِدم التاريخ لا يعني اكتمال الدورة. تبقى حالتها التشغيلية كما سجلها الخادم.</small></span></div>
          ${cycleTable(openHistoricalCycles)}</div>` : '')
      + `<div class="box archive-closed-cycles"><h3>دورات مقفلة تاريخياً</h3>
          ${closedCycles.length ? cycleTable(closedCycles) : '<p class="muted">لا دورات مقفلة</p>'}</div>`

      + `<div class="box" style="margin-top:12px">
          <h3>دفعات التنصيب</h3>
          ${batches.length ? table<Row>([
            { key: 'name', label: 'الدفعة', cell: (r) =>
              `<a href="${esc(href(`/finance/installation-batches/${encodeURIComponent(str(r, 'id'))}`))}">${esc(str(r, 'name'))}</a>` },
            { key: 'status', label: 'الحالة', cell: (r) => chip(str(r, 'status'), 'info') },
            { key: 'n', label: 'السطور', cell: (r) => count(num(r, 'item_count')), numeric: true },
            { key: 'amt', label: 'المبلغ', cell: (r) =>
              `<span class="money">${money(num(r, 'total_amount'))}</span>`, numeric: true },
            { key: 'ref', label: 'الإشعار', cell: (r) => esc(str(r, 'payment_ref') || '—') },
            { key: 'settled', label: '', cell: settledChip },
          ], batches) : '<p class="muted">لا دفعات</p>'}
        </div>`

      + `<div class="grid2" style="margin-top:12px">
          <div class="box"><h3>الاستيرادات</h3>
            ${imports.map((i) => `<a class="minirow" style="text-decoration:none;color:inherit"
                href="${esc(href(`/system/imports/${encodeURIComponent(str(i, 'id'))}`))}">
                <span>${esc(str(i, 'source_filename'))}
                  <span class="muted">${esc(str(i, 'completeness_status'))}</span></span>
                <b>${count(num(i, 'imported_row_count'))}</b></a>`).join('')
              || '<p class="muted">لا استيرادات</p>'}
          </div>
          <div class="box"><h3>نسخ المخططات</h3>
            ${schemes.map((s) => `<div class="minirow">
                <span>${chip(str(s, 'status'), str(s, 'status') === 'PUBLISHED' ? 'success' : 'neutral')}
                  <span class="muted" dir="ltr">${esc(when(s['created_at']))}</span></span>
                <b>${count(num(s, 'stages'))} مرحلة</b></div>`).join('')
              || '<p class="muted">لا نسخ</p>'}
          </div>
        </div>`;
  },
};

/* ---- التصدير ------------------------------------------------------------- */

function exportBar(): string {
  return `<div class="actions" style="margin:10px 0">
    <button class="btn" id="rpExport">صدِّر الصفحة المعروضة (CSV)</button>
    <span class="muted" style="font-size:11px">يُصدَّر ما يُعرض بعينه، ومعه المجموع.</span>
  </div>`;
}

/**
 * التصدير يخرج من الصفوف المعروضة نفسها.
 *
 * لو أُعيد جلبها بشروطٍ أخرى لأمكن أن يفترق المُصدَّر عن المعروض — وهو بالضبط
 * ما يجعل تقريراً لا يطابق نفسه. ويُذيَّل بالمجموع الخادمي كما ورد.
 */
function wireExport(view: View, name: string, rows: Row[],
                    cols: Array<[string, string]>, totals: Record<string, number>): void {
  const btn = view.el.querySelector<HTMLButtonElement>('#rpExport');
  if (!btn) return;
  btn.addEventListener('click', () => {
    const esc2 = (v: unknown) => {
      const s = String(v ?? '');
      return /[",\n]/.test(s) ? `"${s.split('"').join('""')}"` : s;
    };
    const lines = [cols.map(([, label]) => esc2(label)).join(',')];
    for (const r of rows) lines.push(cols.map(([k]) => esc2(r[k])).join(','));
    lines.push('');
    for (const [k, v] of Object.entries(totals)) lines.push(`${esc2(k)},${esc2(v)}`);
    // BOM كي تفتح Excel العربية بترميزها الصحيح.
    const blob = new Blob(['﻿' + lines.join('\n')], { type: 'text/csv;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `babil-${name}-${new Date().toISOString().slice(0, 10)}.csv`;
    a.click();
    URL.revokeObjectURL(url);
  });
}

export const routes: Route[] = [
  reportsIndex, commissionReport, installationReport, historicalReport, paymentsReport, archive,
];
