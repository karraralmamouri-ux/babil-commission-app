/**
 * عمولات الوكلاء — الشاشات التشغيلية.
 *
 * كل رقم هنا يأتي من الخادم. لا تسعير ولا جمع في المتصفح: الشاشة تعرض ما
 * حسبه المحرّك المعتمد.
 */

import type { Route, RouteMatch, View } from '../../app/router';
import { href } from '../../app/router';
import { rpc, select, toPage, can } from '../../services/api';
import { money, count } from '../../domain/money';
import {
  esc, loading, empty, errorState, pageHeader, table, pager, kpiRow,
  chip, projectedTag, filterBar, wireFilters, type Column,
} from '../../components/ui';

interface Cycle {
  id: string; name: string; status: string;
  period_start: string; period_end: string;
  finalized_at: string | null; closed_at: string | null;
}

interface Snapshot {
  id: string; scope_type: string; scope_id: string; scope_label: string | null;
  zone: string; unique_activated_subscribers: number; qualifying_event_count: number;
  tier_code: string; gross_commission: number; package_breakdown: Record<string, number> | null;
}

const FINAL = new Set(['FINALIZED', 'PARTIALLY_PAID', 'PAID', 'CLOSED']);
const isProjected = (status: string) => !FINAL.has(status);

const STATUS_LABEL: Record<string, string> = {
  DRAFT: 'مسودّة', DATA_IMPORTED: 'بيانات مُستوردة', UNDER_REVIEW: 'قيد المراجعة',
  READY_TO_FINALIZE: 'جاهزة للاعتماد', FINALIZED: 'معتمدة',
  PARTIALLY_PAID: 'مدفوعة جزئياً', PAID: 'مدفوعة', CLOSED: 'مقفلة',
};
const statusLabel = (s: string) => STATUS_LABEL[s] || s;

const statusTone = (s: string): 'success' | 'warning' | 'info' | 'neutral' => {
  if (s === 'PAID' || s === 'FINALIZED') return 'success';
  if (s === 'UNDER_REVIEW' || s === 'READY_TO_FINALIZE') return 'info';
  if (s === 'CLOSED') return 'neutral';
  return 'warning';
};

async function cycles(): Promise<Cycle[]> {
  return (await select<Cycle[]>('commission_cycles?select=*&order=period_start.desc')) || [];
}

/* ---- نظرة عامة ---------------------------------------------------------- */

export const overview: Route = {
  pattern: '/commissions',
  capability: 'commission.view',
  title: 'عمولات الوكلاء',
  breadcrumb: () => [{ label: 'الرئيسية', href: href('/') }, { label: 'عمولات الوكلاء' }],
  async render(view) {
    view.write(loading('جارٍ تحميل الدورات…'));
    const list = await cycles();
    if (!list.length) { view.write(empty('لا توجد دورات عمولة بعد')); return; }
    const current = list[0] as Cycle;
    const detail = await rpc<Record<string, unknown>>('report_commission_cycle_detail', { p_cycle_id: current.id })
      .catch(() => null);
    const totals = (detail?.['totals'] || {}) as Record<string, number>;
    const projected = isProjected(current.status);

    view.write(pageHeader('عمولات الوكلاء', 'الدورة الأحدث ومدخل إلى الدورات السابقة')
      + kpiRow([
        { label: 'الإجمالي المحسوب', value: money(totals['gross'] ?? null) + (projected ? ' ' + projectedTag() : ''), tone: 'primary', sub: current.name, link: href(`/commissions/cycles/${current.id}`) },
        { label: 'أساس الشريحة — مشتركون فريدون', value: count(totals['unique_activated_subscribers'] ?? null), tone: 'blue', link: href(`/commissions/cycles/${current.id}/scopes`) },
        { label: 'الأحداث المؤهَّلة', value: count(totals['qualifying_events'] ?? null), tone: 'green', link: href(`/commissions/cycles/${current.id}/events`) },
        { label: 'النطاقات', value: count(totals['scopes'] ?? null), tone: 'gold', link: href(`/commissions/cycles/${current.id}/scopes`) },
      ])
      + `<div class="box"><h3>الدورات</h3>${table<Cycle>(cycleColumns(), list, (c) => `location.hash='${href(`/commissions/cycles/${c.id}`).slice(1)}'`)}</div>`);
  },
};

function cycleColumns(): Array<Column<Cycle>> {
  return [
    { key: 'name', label: 'الدورة', cell: (c) => `<b>${esc(c.name)}</b>` },
    { key: 'period', label: 'الفترة', cell: (c) => `${esc(c.period_start)} → ${esc(c.period_end)}` },
    { key: 'status', label: 'الحالة', cell: (c) => chip(statusLabel(c.status), statusTone(c.status)) + (isProjected(c.status) ? ' ' + projectedTag() : '') },
    { key: 'open', label: '', cell: (c) => `<a class="smallbtn" href="${esc(href(`/commissions/cycles/${c.id}`))}">فتح</a>` },
  ];
}

export const cycleList: Route = {
  pattern: '/commissions/cycles',
  capability: 'commission.view',
  title: 'دورات العمولة',
  breadcrumb: () => [{ label: 'الرئيسية', href: href('/') }, { label: 'عمولات الوكلاء', href: href('/commissions') }, { label: 'الدورات' }],
  async render(view) {
    view.write(loading());
    const list = await cycles();
    view.write(pageHeader('دورات العمولة', `${list.length} دورة`)
      + (list.length ? table<Cycle>(cycleColumns(), list, (c) => `location.hash='${href(`/commissions/cycles/${c.id}`).slice(1)}'`) : empty('لا دورات')));
  },
};

/* ---- ورشة الدورة -------------------------------------------------------- */

const CYCLE_TABS = [
  { key: 'overview', label: 'نظرة عامة' },
  { key: 'scopes', label: 'النطاقات' },
  { key: 'events', label: 'الأحداث' },
  { key: 'exceptions', label: 'الاستثناءات' },
  { key: 'review', label: 'المراجعة والاعتماد' },
  { key: 'payout', label: 'تجهيز الصرف' },
  { key: 'audit', label: 'التدقيق' },
];

export const cycleDetail: Route = {
  pattern: '/commissions/cycles/:id',
  capability: 'commission.view',
  title: 'دورة العمولة',
  breadcrumb: (m) => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'عمولات الوكلاء', href: href('/commissions') },
    { label: 'الدورات', href: href('/commissions/cycles') },
    { label: m.params['id'] ? 'الدورة' : '—' },
  ],
  async render(view, m) { await renderCycle(view, m, m.query.get('tab') || 'overview'); },
};

export const cycleTab: Route = {
  pattern: '/commissions/cycles/:id/:tab',
  capability: 'commission.view',
  title: 'دورة العمولة',
  breadcrumb: (m) => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'عمولات الوكلاء', href: href('/commissions') },
    { label: 'الدورات', href: href('/commissions/cycles') },
    { label: CYCLE_TABS.find((t) => t.key === m.params['tab'])?.label || 'الدورة' },
  ],
  async render(view, m) { await renderCycle(view, m, m.params['tab'] || 'overview'); },
};

async function renderCycle(view: View, m: RouteMatch, tab: string): Promise<void> {
  const id = m.params['id'] as string;
  view.write(loading('جارٍ تحميل الدورة…'));

  const list = await cycles();
  const cycle = list.find((c) => c.id === id);
  if (!cycle) { view.write(empty('الدورة غير موجودة', 'قد تكون أُغلقت أو حُذف رابطها')); return; }

  const detail = await rpc<Record<string, unknown>>('report_commission_cycle_detail', { p_cycle_id: id }).catch(() => null);
  const totals = (detail?.['totals'] || {}) as Record<string, number>;
  const projected = isProjected(cycle.status);

  const tabs = CYCLE_TABS.map((t) =>
    `<a class="tab${t.key === tab ? ' active' : ''}" href="${esc(href(`/commissions/cycles/${id}/${t.key}`))}">${esc(t.label)}</a>`).join('');

  view.write(pageHeader(cycle.name,
    `${cycle.period_start} → ${cycle.period_end}`,
    `${chip(statusLabel(cycle.status), statusTone(cycle.status))}${projected ? ' ' + projectedTag() : ''}`)
    + kpiRow([
      { label: 'المحسوب', value: money(totals['gross'] ?? null), tone: 'primary' },
      { label: 'أساس الشريحة', value: count(totals['unique_activated_subscribers'] ?? null), sub: 'مشتركون فريدون', tone: 'blue' },
      { label: 'الأحداث المؤهَّلة', value: count(totals['qualifying_events'] ?? null), sub: 'ليست أساس الشريحة', tone: 'green' },
      { label: 'النطاقات', value: count(totals['scopes'] ?? null), tone: 'gold' },
    ])
    + `<div class="tabs">${tabs}</div><div class="panel active" id="cycleTabBody">${loading()}</div>`);

  const body = view.el.querySelector<HTMLElement>('#cycleTabBody');
  if (!body) return;
  try {
    await renderCycleTab(view, id, tab, m);
  } catch (error) {
    view.writeInto('#cycleTabBody', errorState(error instanceof Error ? error.message : 'خطأ غير متوقّع'));
  }
}

async function renderCycleTab(view: View, id: string, tab: string, m: RouteMatch): Promise<void> {
  if (tab === 'scopes') {
    const rows = (await select<Snapshot[]>(`commission_cycle_snapshots?select=*&cycle_id=eq.${encodeURIComponent(id)}&order=gross_commission.desc`)) || [];
    view.writeInto('#cycleTabBody', rows.length ? scopeTable(rows) : empty('لا نطاقات محسوبة في هذه الدورة'));
    return;
  }

  if (tab === 'events') {
    const limit = Number(m.query.get('limit') || 50);
    const offset = Number(m.query.get('offset') || 0);
    const rows = await rpc<Array<Record<string, unknown>>>('commission_cycle_events_page', {
      p_cycle_id: id, p_scope_type: m.query.get('scope_type'), p_scope_id: m.query.get('scope_id'),
      p_limit: limit, p_offset: offset,
    });
    const page = toPage(rows as never, limit, offset);
    view.writeInto('#cycleTabBody', (page.rows.length
      ? table(eventColumns(), page.rows as Array<Record<string, unknown>>)
      : empty('لا أحداث مؤهَّلة'))
      + pager(page.total, limit, offset, `/commissions/cycles/${id}/events`, m.query));
    return;
  }

  if (tab === 'exceptions') {
    const limit = 50;
    const offset = Number(m.query.get('offset') || 0);
    const rows = await rpc<Array<Record<string, unknown>>>('list_commission_exceptions', {
      p_cycle_id: id, p_limit: limit, p_offset: offset,
    });
    const page = toPage(rows as never, limit, offset);
    view.writeInto('#cycleTabBody', `<p class="muted" style="font-size:11px">الاستثناء يُحسم في شاشته، ثم تُعاد حسبة الدورة.</p>`
      + (page.rows.length ? table(exceptionColumns(), page.rows as Array<Record<string, unknown>>) : empty('لا استثناءات مفتوحة'))
      + pager(page.total, limit, offset, `/commissions/cycles/${id}/exceptions`, m.query));
    return;
  }

  if (tab === 'review') {
    const blockers = await rpc<Array<Record<string, unknown>>>('commission_finalization_blockers', { p_cycle_id: id });
    if (!blockers || !blockers.length) {
      view.writeInto('#cycleTabBody', `<div class="insight good"><span class="insight-dot"></span><span>
        <b>لا مانع من الاعتماد</b><small>لا استثناء حاجب مفتوح في هذه الدورة.</small></span></div>`);
      return;
    }
    const total = blockers.reduce((a, b) => a + Number(b['indicative_amount'] || 0), 0);
    view.writeInto('#cycleTabBody', `<div class="insight danger" style="margin-bottom:12px"><span class="insight-dot"></span><span>
        <b>الاعتماد محجوب</b>
        <small>${blockers.length} سبباً · أثر مؤشِّر ${money(total)}. تُحسم الأسباب ثم يُعاد الحساب.</small></span></div>`
      + table(blockerColumns(), blockers));
    return;
  }

  if (tab === 'payout') {
    const rows = (await select<Snapshot[]>(`commission_cycle_snapshots?select=*&cycle_id=eq.${encodeURIComponent(id)}&order=gross_commission.desc`)) || [];
    view.writeInto('#cycleTabBody', `<div class="insight warn" style="margin-bottom:12px"><span class="insight-dot"></span><span>
        <b>الصرف يتبع الاعتماد</b>
        <small>لا نطاق يصير قابلاً للدفع قبل اعتماد الدورة. الخادم يُعيد التحقّق عند الترحيل مهما أظهرت الشاشة.</small></span></div>`
      + (rows.length ? table(payoutColumns(), rows) : empty('لا نطاقات')));
    return;
  }

  if (tab === 'audit') {
    const rows = await rpc<Array<Record<string, unknown>>>('list_audit_events', {
      p_action_prefix: 'commission.', p_limit: 50, p_offset: 0,
    }).catch(() => null);
    view.writeInto('#cycleTabBody', rows && rows.length ? table(auditColumns(), rows) : empty('لا سجلّات تدقيق'));
    return;
  }

  // overview
  const zones = (detailZones(await rpc<Record<string, unknown>>('report_commission_cycle_detail', { p_cycle_id: id }).catch(() => null)));
  view.writeInto('#cycleTabBody', zones.length
    ? `<div class="box"><h3>حسب المنطقة</h3>${table(zoneColumns(), zones)}</div>`
    : empty('لا تفصيل متاح'));
}

function detailZones(detail: Record<string, unknown> | null): Array<Record<string, unknown>> {
  const byZone = detail?.['by_zone'];
  return Array.isArray(byZone) ? byZone as Array<Record<string, unknown>> : [];
}

const num = (r: Record<string, unknown>, k: string) => Number(r[k] || 0);

function scopeTable(rows: Snapshot[]): string {
  const columns: Array<Column<Snapshot>> = [
    { key: 'scope', label: 'النطاق', cell: (r) => `<b>${esc(r.scope_label || r.scope_id)}</b>
      <div class="muted" style="font-size:10px">${esc(r.scope_type === 'FDT' ? 'كابينة' : 'وكيل')} · ${esc(r.scope_id)}</div>` },
    { key: 'zone', label: 'المنطقة', cell: (r) => chip(r.zone === 'new' ? 'جديدة' : 'قديمة', r.zone === 'new' ? 'success' : 'info') },
    { key: 'tier', label: 'الشريحة', cell: (r) => chip(String(r.tier_code || '—').toUpperCase(), 'brand'), numeric: true },
    { key: 'subs', label: 'مشتركون (أساس الشريحة)', cell: (r) => count(r.unique_activated_subscribers), numeric: true },
    { key: 'events', label: 'أحداث مؤهَّلة', cell: (r) => count(r.qualifying_event_count), numeric: true },
    { key: 'p35', label: 'P35', cell: (r) => count(r.package_breakdown?.['P-35000'] ?? 0), numeric: true },
    { key: 'p45', label: 'P45', cell: (r) => count(r.package_breakdown?.['P-45000'] ?? 0), numeric: true },
    { key: 'p65', label: 'P65', cell: (r) => count(r.package_breakdown?.['P-65000'] ?? 0), numeric: true },
    { key: 'gross', label: 'الإجمالي', cell: (r) => `<span class="money">${money(r.gross_commission)}</span>`, numeric: true },
  ];
  return table(columns, rows);
}

function eventColumns(): Array<Column<Record<string, unknown>>> {
  return [
    { key: 'event', label: 'الحدث', cell: (r) => esc(r['activation_event_id'] ?? r['saas_event_id'] ?? '—') },
    { key: 'pkg', label: 'الباقة', cell: (r) => esc(r['package_code'] ?? '—') },
    { key: 'tier', label: 'الشريحة', cell: (r) => esc(String(r['tier_code'] ?? '—').toUpperCase()), numeric: true },
    { key: 'amount', label: 'المبلغ', cell: (r) => `<span class="money">${money(num(r, 'amount'))}</span>`, numeric: true },
    { key: 'at', label: 'التاريخ', cell: (r) => esc(String(r['event_at'] ?? '').slice(0, 10)) },
  ];
}

function exceptionColumns(): Array<Column<Record<string, unknown>>> {
  return [
    { key: 'reason', label: 'السبب', cell: (r) => `<b>${esc(r['reason_code'])}</b>
      <div class="muted" style="font-size:10px">${esc(r['detail'] ?? '')}</div>` },
    { key: 'event', label: 'الحدث', cell: (r) => esc(r['activation_event_id'] ?? '—') },
    { key: 'fdt', label: 'الكابينة', cell: (r) => esc(r['fdt_code'] ?? '—') },
    { key: 'amount', label: 'أثر مؤشِّر', cell: (r) => money(num(r, 'indicative_amount')), numeric: true },
    { key: 'blocking', label: 'حاجب', cell: (r) => r['blocks_finalization'] ? chip('حاجب', 'critical') : chip('للمراجعة', 'warning') },
    { key: 'go', label: '', cell: (r) => actionLink(String(r['reason_code'] || ''), r) },
  ];
}

/** الاستثناء يقود إلى شاشة حسمه — لا إلى رسالة عامة. */
function actionLink(reason: string, row: Record<string, unknown>): string {
  const fdt = String(row['fdt_code'] || '');
  const map: Record<string, string> = {
    UNKNOWN_FDT: href('/master/fdt', fdt ? { code: fdt } : undefined),
    UNKNOWN_AGENT: href('/master/agents'),
    UNKNOWN_PACKAGE: href('/master/packages'),
    SOURCE_INCOMPLETE: href('/imports'),
    IDENTITY_CONFLICT: href('/installation/subscribers'),
  };
  const target = map[reason];
  return target ? `<a class="smallbtn" href="${esc(target)}">افتح</a>` : '';
}

function blockerColumns(): Array<Column<Record<string, unknown>>> {
  return [
    { key: 'reason', label: 'السبب', cell: (r) => `<b>${esc(r['reason_code'])}</b>` },
    { key: 'events', label: 'أحداث', cell: (r) => count(num(r, 'events')), numeric: true },
    { key: 'subs', label: 'مشتركون', cell: (r) => count(num(r, 'subscribers')), numeric: true },
    { key: 'amount', label: 'أثر مؤشِّر', cell: (r) => money(num(r, 'indicative_amount')), numeric: true },
    { key: 'owner', label: 'الجهة', cell: (r) => esc(r['owner_hint'] ?? '—') },
    { key: 'action', label: 'الإجراء', cell: (r) => esc(r['action_hint'] ?? '—') },
  ];
}

function payoutColumns(): Array<Column<Snapshot>> {
  return [
    { key: 'scope', label: 'النطاق', cell: (r) => esc(r.scope_label || r.scope_id) },
    { key: 'gross', label: 'الإجمالي', cell: (r) => `<span class="money">${money(r.gross_commission)}</span>`, numeric: true },
    { key: 'state', label: 'قابلية الدفع', cell: () => chip('غير قابل — الدورة لم تُعتمد', 'warning') },
  ];
}

function auditColumns(): Array<Column<Record<string, unknown>>> {
  return [
    { key: 'at', label: 'التاريخ', cell: (r) => esc(String(r['created_at'] ?? '').slice(0, 19).replace('T', ' ')) },
    { key: 'action', label: 'الفعل', cell: (r) => esc(r['action'] ?? '') },
    { key: 'field', label: 'الحقل', cell: (r) => esc(r['field'] ?? '—') },
    { key: 'new', label: 'القيمة', cell: (r) => esc(r['new_value'] ?? '—') },
  ];
}

function zoneColumns(): Array<Column<Record<string, unknown>>> {
  return [
    { key: 'zone', label: 'المنطقة', cell: (r) => chip(r['zone'] === 'new' ? 'جديدة (بالكابينة)' : 'قديمة (بالوكيل)', r['zone'] === 'new' ? 'success' : 'info') },
    { key: 'scopes', label: 'النطاقات', cell: (r) => count(num(r, 'scopes')), numeric: true },
    { key: 'subs', label: 'مشتركون', cell: (r) => count(num(r, 'unique_activated_subscribers')), numeric: true },
    { key: 'events', label: 'أحداث', cell: (r) => count(num(r, 'qualifying_events')), numeric: true },
    { key: 'gross', label: 'الإجمالي', cell: (r) => `<span class="money">${money(num(r, 'gross'))}</span>`, numeric: true },
  ];
}

/* ---- الوكلاء ------------------------------------------------------------ */

export const agentList: Route = {
  pattern: '/commissions/agents',
  capability: 'commission.view',
  title: 'الوكلاء',
  breadcrumb: () => [{ label: 'الرئيسية', href: href('/') }, { label: 'عمولات الوكلاء', href: href('/commissions') }, { label: 'الوكلاء' }],
  async render(view) {
    view.write(loading('جارٍ تحميل الوكلاء…'));
    const rows = await rpc<Array<Record<string, unknown>>>('list_agents_financial', {});
    const columns: Array<Column<Record<string, unknown>>> = [
      { key: 'name', label: 'الوكيل', cell: (r) => `<b>${esc(r['official_name'])}</b>
        <div class="muted" style="font-size:10px">${esc(r['code'])}</div>` },
      { key: 'fdts', label: 'كابينات', cell: (r) => count(num(r, 'fdt_count')), numeric: true },
      { key: 'calc', label: 'محسوب', cell: (r) => `<span class="money">${money(num(r, 'calc_gross'))}</span>`, numeric: true },
      { key: 'events', label: 'أحداث', cell: (r) => count(num(r, 'calc_events')), numeric: true },
      { key: 'blocked', label: 'موقوف (مؤشِّر)', cell: (r) => `<span class="money is-blocked">${money(num(r, 'blocked_indicative'))}</span>`, numeric: true },
      { key: 'inst', label: 'مشتركو التنصيب', cell: (r) => count(num(r, 'installation_subscribers')), numeric: true },
      { key: 'go', label: '', cell: (r) => `<a class="smallbtn" href="${esc(href(`/commissions/agents/${r['agent_id']}`))}">فتح</a>` },
    ];
    view.write(pageHeader('الوكلاء', `${(rows || []).length} وكيلاً`)
      + (rows && rows.length ? table(columns, rows) : empty('لا وكلاء')));
  },
};

export const agentDetail: Route = {
  pattern: '/commissions/agents/:id',
  capability: 'commission.view',
  title: 'الملفّ المالي للوكيل',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'عمولات الوكلاء', href: href('/commissions') },
    { label: 'الوكلاء', href: href('/commissions/agents') },
    { label: 'الملفّ المالي' },
  ],
  async render(view, m) {
    const id = m.params['id'] as string;
    view.write(loading('جارٍ تحميل ملفّ الوكيل…'));
    const profile = await rpc<Record<string, unknown>>('agent_financial_profile', { p_agent_id: id });
    if (!profile) { view.write(empty('الوكيل غير موجود')); return; }

    const agent = (profile['agent'] || {}) as Record<string, unknown>;
    const inst = (profile['installation'] || {}) as Record<string, unknown>;
    const fdts = (profile['fdts'] || []) as string[];
    const aliases = (profile['aliases'] || []) as string[];
    const cycleRows = (profile['commission_cycles'] || []) as Array<Record<string, unknown>>;

    const calc = cycleRows.reduce((a, c) => a + Number(c['gross_commission'] || 0), 0);
    const stages = (inst['stage_distribution'] || {}) as Record<string, number>;

    view.innerHTML = pageHeader(String(agent['name'] || agent['code'] || 'وكيل'),
      `${esc(String(agent['code'] || ''))} · ${chip(String(agent['status'] || '—'), 'neutral')}`)
      + kpiRow([
        { label: 'عمولة محسوبة', value: money(calc), tone: 'primary' },
        { label: 'كابينات', value: count(fdts.length), tone: 'gold' },
        { label: 'مشتركو التنصيب', value: count(Number(inst['subscribers'] || 0)), tone: 'blue' },
        { label: 'أسماء بديلة', value: count(aliases.length), tone: 'green' },
      ])
      // القاعدتان المحاسبيتان تبقيان منفصلتين في العرض: جمعهما يوحي بقاعدة لا وجود لها.
      + `<div class="grid2">
        <div class="box"><h3>◎ العمولات</h3>
          ${cycleRows.length ? table(agentCycleColumns(), cycleRows) : `<p class="muted">لا دورات محسوبة</p>`}</div>
        <div class="box"><h3>⚙ أجور التنصيب</h3>
          ${Object.keys(stages).length
            ? Object.entries(stages).map(([k, v]) => `<div class="minirow"><span>${esc(k)}</span><b>${count(v)}</b></div>`).join('')
            : `<p class="muted">لا مشتركين منسوبين — التسميات التاريخية لم تُربط بعد بالوكلاء المعتمدين</p>`}
        </div></div>`
      + `<div class="box" style="margin-top:14px"><h3>الكابينات</h3>
        ${fdts.length ? fdts.map((f) => `<a class="chip chip-neutral" style="margin:2px" href="${esc(href('/master/fdt', { code: f }))}">${esc(f)}</a>`).join('') : '<p class="muted">لا كابينات</p>'}</div>`;
  },
};

function agentCycleColumns(): Array<Column<Record<string, unknown>>> {
  return [
    { key: 'cycle', label: 'الدورة', cell: (r) => esc(r['cycle'] ?? '—') },
    { key: 'scope', label: 'النطاق', cell: (r) => esc(r['scope_id'] ?? '—') },
    { key: 'tier', label: 'الشريحة', cell: (r) => esc(String(r['tier'] ?? '—').toUpperCase()), numeric: true },
    { key: 'subs', label: 'مشتركون', cell: (r) => count(num(r, 'unique_activated_subscribers')), numeric: true },
    { key: 'gross', label: 'الإجمالي', cell: (r) => `<span class="money">${money(num(r, 'gross_commission'))}</span>`, numeric: true },
  ];
}

/* ---- الاستثناءات (طابور مستقلّ) ---------------------------------------- */

export const exceptionsQueue: Route = {
  pattern: '/exceptions',
  capability: 'commission.view',
  title: 'الاستثناءات',
  breadcrumb: () => [{ label: 'الرئيسية', href: href('/') }, { label: 'الاستثناءات' }],
  async render(view, m) {
    const limit = 50;
    const offset = Number(m.query.get('offset') || 0);
    view.innerHTML = loading('جارٍ تحميل الطابور…');

    const args: Record<string, unknown> = { p_limit: limit, p_offset: offset };
    if (m.query.get('reason')) args['p_reason'] = m.query.get('reason');
    if (m.query.get('search')) args['p_search'] = m.query.get('search');
    if (m.query.get('blocking') === 'true') args['p_blocking'] = true;

    const rows = await rpc<Array<Record<string, unknown>>>('list_commission_exceptions', args);
    const page = toPage(rows as never, limit, offset);
    const impact = (page.rows as Array<Record<string, unknown>>)
      .reduce((a, r) => a + Number(r['indicative_amount'] || 0), 0);

    view.innerHTML = pageHeader('الاستثناءات', 'طابور عمل — لكل صفّ جهةٌ وإجراءٌ وشاشةُ حسم')
      + filterBar([
        { key: 'search', label: 'بحث', type: 'search' },
        { key: 'reason', label: 'الأسباب', type: 'select', options: [
          { value: 'UNKNOWN_FDT', label: 'كابينة غير مسجَّلة' },
          { value: 'UNKNOWN_AGENT', label: 'وكيل غير معروف' },
          { value: 'UNKNOWN_PACKAGE', label: 'باقة غير معروفة' },
          { value: 'SOURCE_INCOMPLETE', label: 'مصدر غير مكتمل' },
          { value: 'IDENTITY_CONFLICT', label: 'تعارض هوية' },
        ] },
        { key: 'blocking', label: 'الحجب', type: 'select', options: [{ value: 'true', label: 'الحاجب فقط' }] },
      ], '/exceptions', m.query)
      + `<div class="muted" style="font-size:11px;margin-bottom:8px">
          ${count(page.total)} استثناءً · أثر الصفحة المؤشِّر ${money(impact)}</div>`
      + (page.rows.length ? table(exceptionColumns(), page.rows as Array<Record<string, unknown>>) : empty('لا استثناءات مطابقة'))
      + pager(page.total, limit, offset, '/exceptions', m.query);

    wireFilters(view.el);
  },
};

export const routes: Route[] = [
  overview, cycleList, cycleDetail, cycleTab, agentList, agentDetail, exceptionsQueue,
];

export { can };
