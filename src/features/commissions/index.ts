/**
 * عمولات الوكلاء — الشاشات التشغيلية.
 *
 * كل رقم هنا يأتي من الخادم. لا تسعير ولا جمع في المتصفح: الشاشة تعرض ما
 * حسبه المحرّك المعتمد.
 */

import type { Route, RouteMatch, View } from '../../app/router';
import { href } from '../../app/router';
import { rpc, select, toPage, envelope, can } from '../../services/api';
import { money, count } from '../../domain/money';
import {
  readCycleResult, knownAgentTotal, cycleStatusAr, isProjectedStatus,
  type CycleResult, type UnresolvedOwnership,
} from '../../domain/cycle';
import { dateTime } from '../../domain/time';
import { packageLabel } from '../../domain/presentation';
import { canCancelDraft, cancelDraftError, cancelDraftSuccess } from './cancelDraft';
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

    // بطاقةٌ توجيهية فقط. القرار — DRAFT + القدرة — هو نفس شرط ظهور زرّ
    // الإلغاء في تبويب المراجعة والاعتماد، فيُعاد استعماله لا يُكتب ثانيةً.
    // ولا RPC هنا ولا منطق إلغاء: مجرّد رابطٍ إلى حيث يعيشان.
    const draftCard = canCancelDraft(current.status, can('commission.manage_cycle'))
      ? draftActionsCard(current)
      : '';

    // قراءةٌ واحدة بعقدٍ واحد. والعطل يُعرَض عطلاً: «تعذّر التحميل» و«لا
    // بيانات» حالتان مختلفتان، وعرضُ الشرطة لكليهما يُخفي الأولى.
    let result: CycleResult | null;
    try {
      result = await readCycleResult(current.id);
    } catch (error) {
      if (!view.live) return;
      view.write(pageHeader('عمولات الوكلاء', current.name)
        + errorState(
            error instanceof Error ? error.message : 'تعذّر تحميل بيانات الدورة',
            'location.reload()'));
      return;
    }
    if (!view.live) return;

    if (!result) {
      view.write(pageHeader('عمولات الوكلاء', current.name)
        + draftCard
        + empty('لا نتيجة محسوبة لهذه الدورة بعد', 'تُحسب الدورة من شاشتها'));
      return;
    }

    const projected = isProjectedStatus(result.cycle.status);
    const known = knownAgentTotal(result);
    const unresolved = result.unresolved_ownership;

    view.write(pageHeader('عمولات الوكلاء',
      `${esc(result.cycle.name)} · ${esc(cycleStatusAr(result.cycle.status))}`,
      projected ? projectedTag() : chip('معتمدة', 'success'))

      + draftCard

      // النتيجة المالية أولاً: محسوب، معتمد، مدفوع.
      + kpiRow([
        { label: 'عمولات محسوبة', value: money(result.totals.gross), tone: 'primary',
          sub: projected ? 'قيد المراجعة — لم تُعتمد بعد' : 'معتمدة',
          link: href(`/commissions/cycles/${current.id}`) },
        { label: 'معتمد', value: money(result.totals.approved), tone: 'green',
          sub: result.totals.approved ? 'مثبَّت بلقطة' : 'لم يُعتمد بعد' },
        { label: 'مدفوع', value: money(result.totals.paid), tone: 'blue',
          sub: 'مُرحَّل في دفعات الصرف' },
        { label: 'قرارات تمنع الاعتماد',
          value: count(result.blockers.reduce((a, b) => a + b.subscribers, 0)),
          tone: result.blockers.length ? 'red' : 'green',
          sub: result.blockers.length ? 'تُحسم قبل الاعتماد' : 'لا مانع',
          link: href(`/commissions/cycles/${current.id}/review`) },
      ])

      // المصالحة معروضة: مجموع الوكلاء وحده يبدو ناقصاً بلا سبب.
      + reconciliationBox(result, known, unresolved)

      + `<div class="box" style="margin-top:12px"><h3>الأحجام التشغيلية</h3>
          <div class="minirow"><span>التفعيلات المؤهَّلة</span>
            <b>${count(result.volumes.qualifying_events)}</b></div>
          <div class="minirow"><span>أساس التير — مشتركون فريدون</span>
            <b>${count(result.volumes.tier_basis)}</b></div>
        </div>`

      + `<div class="box" style="margin-top:12px"><h3>الدورات</h3>${
          table<Cycle>(cycleColumns(), list,
            (c) => `location.hash='${href(`/commissions/cycles/${c.id}`).slice(1)}'`)}</div>`);
  },
};

/**
 * بطاقة توجيهٍ لدورةٍ لا تزال مسوّدة.
 *
 * لا تنادي `cancel_empty_commission_cycle` ولا تُعيد رسم التأكيد — كلاهما
 * يعيش في تبويب المراجعة والاعتماد (`workflowPanel`/`wireWorkflow`). هذه
 * إشارةٌ فقط: أنت هنا، والإجراء هناك.
 */
function draftActionsCard(cycle: Cycle): string {
  return `<div class="box" style="margin-top:12px" id="draftActionsBox">
    <h3>إجراءات الدورة</h3>
    <p class="muted" style="font-size:11px;margin:0 0 10px">
      هذه الدورة مسوّدة. إجراءاتها — ومنها إلغاؤها إن كانت فارغة — في تبويب المراجعة والاعتماد.
    </p>
    <a class="btn" href="${esc(href(`/commissions/cycles/${cycle.id}/review`))}">افتح المراجعة والاعتماد</a>
  </div>`;
}

/**
 * المصالحة المرئية.
 *
 * أربعة أحداث في تموز بلا وكيل فعّال، مجموعها 18,750 د.ع. المحرّك يحسبها
 * في الإجمالي — وهي مستحقّة فعلاً — وقائمة الوكلاء لا تعرضها لأنها تُجمّع
 * بالوكيل. فيبدو مجموع الوكلاء أقلّ من الدورة بلا تفسير.
 *
 * ولا تُوزَّع على وكيلٍ لتستقيم المعادلة: توزيعُها بلا دليل يُسمّي التخمين
 * حساباً. تُعرض بندَ قرارٍ قائماً بذاته حتى يُحسم بدليل.
 */
function reconciliationBox(r: CycleResult, known: number, u: UnresolvedOwnership): string {
  if (!u.amount) {
    return `<div class="box" style="margin-top:12px">
      <h3>توزيع الإجمالي</h3>
      <div class="minirow"><span>منسوب لوكلاء معروفين</span>
        <b class="money">${money(known)}</b></div>
      <div class="minirow"><span>إجمالي الدورة</span>
        <b class="money">${money(r.totals.gross)}</b></div>
      <p class="muted" style="font-size:11px;margin:8px 0 0">كل المبلغ منسوب.</p>
    </div>`;
  }
  return `<div class="box" style="margin-top:12px">
    <h3>توزيع الإجمالي</h3>
    <div class="minirow"><span>منسوب لوكلاء معروفين</span>
      <b class="money">${money(known)}</b></div>
    <div class="minirow"><span>ملكية تحتاج حسم
        <div class="muted" style="font-size:11px">${count(u.events)} تفعيلاً ·
          ${count(u.subscribers)} مشتركاً ·
          المصدر ${u.parents.map((p) => esc(p)).join('، ') || '—'}</div></span>
      <b class="money">${money(u.amount)}</b></div>
    <div class="minirow" style="border-top:1px solid var(--line)">
      <span><b>إجمالي الدورة</b></span>
      <b class="money">${money(r.totals.gross)}</b></div>
    <p class="muted" style="font-size:11px;margin:8px 0 0">
      المبلغ المعلّق محسوب ضمن الدورة، ولم يُنسب إلى وكيل لأن عائديته لم تُحسم.
      لا يُوزَّع بلا دليل.</p>
    <div class="actions" style="margin-top:10px">
      <a class="btn gold" href="${esc(href('/work'))}">افتح قرار الملكية</a>
    </div>
  </div>`;
}

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
      + openCyclePanel(list)
      + (list.length ? table<Cycle>(cycleColumns(), list, (c) => `location.hash='${href(`/commissions/cycles/${c.id}`).slice(1)}'`) : empty('لا دورات')));
    wireOpenCycle(view);
  },
};

/* ---- فتح دورة ------------------------------------------------------------ */

/**
 * الفترة تُقترح من نهاية آخر دورة: الشهر الذي يليها كاملاً. والاقتراح لا
 * يُلزم — يبقى الحقلان قابلين للتعديل، فدورةٌ استثنائية بفترةٍ غير شهرية واردة.
 *
 * والتقاطع يرفضه الخادم بقيدٍ لا بفحصٍ وحده: دورتان على الفترة نفسها تحسبان
 * الحدث الواحد مرّتين.
 */
function openCyclePanel(list: Cycle[]): string {
  if (!can('commission.manage_cycle')) return '';
  const last = list.map((c) => c.period_end).sort().at(-1);
  let start = '';
  let end = '';
  let name = '';
  if (last) {
    const next = new Date(`${last}T00:00:00Z`);
    next.setUTCDate(next.getUTCDate() + 1);
    const first = new Date(Date.UTC(next.getUTCFullYear(), next.getUTCMonth(), 1));
    const lastDay = new Date(Date.UTC(next.getUTCFullYear(), next.getUTCMonth() + 1, 0));
    start = first.toISOString().slice(0, 10);
    end = lastDay.toISOString().slice(0, 10);
    name = start.slice(0, 7);
  }
  return `<div class="box" style="margin-top:12px" id="openCycleBox">
    <h3>افتح دورة</h3>
    <p class="muted" style="font-size:11px;margin:0 0 10px">
      تُفتح مسودّةً، ثم تُحسب فتصير قيد المراجعة. والاعتماد له شاشته وشرطه.
      ${last ? `آخر دورة تنتهي ${esc(last)}، والمقترَح الشهر الذي يليها.` : ''}</p>
    <div class="toolbar">
      <input class="search" id="ocName" placeholder="اسم الدورة"
        aria-label="اسم الدورة" value="${esc(name)}">
      <input class="search" type="date" id="ocStart" aria-label="بداية الفترة" value="${esc(start)}">
      <input class="search" type="date" id="ocEnd" aria-label="نهاية الفترة" value="${esc(end)}">
      <input class="search" id="ocNotes" placeholder="ملاحظة (اختياري)" aria-label="ملاحظة">
      <button class="btn gold" id="ocOpen">افتح</button>
    </div>
    <div id="ocResult"></div>
  </div>`;
}

function wireOpenCycle(view: View): void {
  const box = view.el.querySelector<HTMLElement>('#openCycleBox');
  if (!box) return;
  const name = box.querySelector<HTMLInputElement>('#ocName');
  const start = box.querySelector<HTMLInputElement>('#ocStart');
  const end = box.querySelector<HTMLInputElement>('#ocEnd');
  const notes = box.querySelector<HTMLInputElement>('#ocNotes');
  const open = box.querySelector<HTMLButtonElement>('#ocOpen');
  const out = box.querySelector<HTMLElement>('#ocResult');
  if (!name || !start || !end || !open || !out) return;

  open.addEventListener('click', async () => {
    if (!name.value.trim()) { out.innerHTML = insight('warn', 'اسم الدورة إلزامي'); return; }
    if (!start.value || !end.value) {
      out.innerHTML = insight('warn', 'الفترة إلزامية', 'بدايةً ونهايةً');
      return;
    }
    if (end.value < start.value) {
      out.innerHTML = insight('warn', 'الفترة معكوسة', 'النهاية قبل البداية');
      return;
    }
    open.disabled = true;
    out.innerHTML = loading('جارٍ فتح الدورة…');
    try {
      const res = await rpc<Record<string, unknown>>('open_commission_cycle', {
        p_name: name.value.trim(),
        p_period_start: start.value,
        p_period_end: end.value,
        p_notes: notes?.value.trim() || null,
        p_request_id: crypto.randomUUID(),
      });
      if (!view.live) return;
      out.innerHTML = insight('good', 'فُتحت الدورة',
        'مسودّة — تُحسب من شاشتها فتصير قيد المراجعة.');
      const id = String(res['cycle_id'] || '');
      window.setTimeout(() => {
        if (!view.live) return;
        if (id) window.location.hash = href(`/commissions/cycles/${id}`).slice(1);
        else window.location.reload();
      }, 1200);
    } catch (error) {
      if (!view.live) return;
      out.innerHTML = insight('danger', 'لم تُفتح الدورة',
        error instanceof Error ? error.message : 'خطأ غير متوقّع');
    } finally {
      open.disabled = false;
    }
  });
}

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

  let result: CycleResult | null;
  try {
    result = await readCycleResult(id);
  } catch (error) {
    if (!view.live) return;
    view.write(pageHeader(cycle.name, `${cycle.period_start} → ${cycle.period_end}`)
      + errorState(error instanceof Error ? error.message : 'تعذّر تحميل نتيجة الدورة', 'location.reload()'));
    return;
  }
  if (!view.live) return;

  // مسوّدةٌ لم تُحسب بعد ليست عطلاً، و«لا نتيجة» غير «صفر»: لا رقم مالي
  // يُختلَق. لكن صفحة الدورة تبقى قابلة للتنقّل بين تبويباتها — فمنها
  // المراجعة والاعتماد الذي يحمل زرّ إلغاء المسودة، ولا سبيل إليه إن توقّف
  // الرندر هنا كما كان قبل هذا الإصلاح.
  const projected = isProjectedStatus(cycle.status);

  const tabs = CYCLE_TABS.map((t) =>
    `<a class="tab${t.key === tab ? ' active' : ''}" href="${esc(href(`/commissions/cycles/${id}/${t.key}`))}">${esc(t.label)}</a>`).join('');

  const summary = result
    ? kpiRow([
        { label: 'عمولة محسوبة', value: money(result.totals.gross), tone: 'primary',
          sub: projected ? 'قيد المراجعة — ليست مستحقاً معتمداً' : 'نتيجة معتمدة' },
        { label: 'معتمد', value: money(result.totals.approved), tone: 'green' },
        { label: 'مدفوع', value: money(result.totals.paid), tone: 'blue' },
        { label: 'فئات أسباب حاجبة', value: count(result.blockers.length),
          tone: result.blockers.length ? 'red' : 'green', link: href(`/commissions/cycles/${id}/review`) },
      ])
      + `<div class="box cycle-operational-result"><h3>النتيجة التشغيلية</h3>
          <div class="minirow"><span>التفعيلات المؤهَّلة</span><b>${count(result.volumes.qualifying_events)}</b></div>
          <div class="minirow"><span>أساس التير — مشتركون فريدون</span><b>${count(result.volumes.tier_basis)}</b></div>
          <div class="minirow"><span>النطاقات المالية</span><b>${count(result.totals.scopes)}</b></div>
        </div>`
    // لا صفر مصطنع: غياب الحساب يُقال نصّاً، لا برقمٍ يوهم أنه قُرئ من الخادم.
    : insight('warn', 'لم تُحسب هذه الدورة بعد',
        'لا عمولة ولا اعتماد ولا صرف قبل أوّل حساب — من تبويب المراجعة والاعتماد.');

  view.write(pageHeader(cycle.name,
    `${cycle.period_start} → ${cycle.period_end}`,
    `${chip(statusLabel(cycle.status), statusTone(cycle.status))}${projected ? ' ' + projectedTag() : ''}`)
    + summary
    + `<div class="tabs">${tabs}</div><div class="panel active" id="cycleTabBody">${loading()}</div>`);

  const body = view.el.querySelector<HTMLElement>('#cycleTabBody');
  if (!body) return;
  try {
    await renderCycleTab(view, cycle, result, tab, m);
  } catch (error) {
    view.writeInto('#cycleTabBody', errorState(error instanceof Error ? error.message : 'خطأ غير متوقّع'));
  }
}

async function renderCycleTab(view: View, cycle: Cycle, result: CycleResult | null, tab: string, m: RouteMatch): Promise<void> {
  const id = cycle.id;
  if (tab === 'scopes') {
    const rows = (await select<Snapshot[]>(`commission_cycle_snapshots?select=*&cycle_id=eq.${encodeURIComponent(id)}&order=gross_commission.desc`)) || [];
    view.writeInto('#cycleTabBody', rows.length ? scopeTable(rows) : empty('لا نطاقات محسوبة في هذه الدورة'));
    return;
  }

  if (tab === 'events') {
    const limit = Number(m.query.get('limit') || 50);
    const offset = Number(m.query.get('offset') || 0);
    const raw = await rpc<Record<string, unknown>>('page_commission_cycle_events_product', {
      p_cycle_id: id, p_agent_id: m.query.get('agent') || null,
      p_fdt_code: m.query.get('fdt') || null, p_source: m.query.get('source') || null,
      p_package_code: m.query.get('package') || null, p_search: m.query.get('search') || null,
      p_limit: limit, p_offset: offset,
    });
    const page = envelope<Record<string, unknown>>(raw);
    view.writeInto('#cycleTabBody', filterBar([
      { key: 'search', label: 'المشترك', type: 'search' },
      { key: 'agent', label: 'معرّف الوكيل', type: 'search' },
      { key: 'fdt', label: 'الكابينة', type: 'search' },
      { key: 'source', label: 'اسم المصدر', type: 'search' },
      { key: 'package', label: 'الباقة', type: 'select', options: [
        { value: 'P-35000', label: 'P35' }, { value: 'P-45000', label: 'P45' },
        { value: 'P-65000', label: 'P65' },
      ] },
    ], `/commissions/cycles/${id}/events`, m.query)
      + (page.rows.length
      ? table(eventColumns(), page.rows as Array<Record<string, unknown>>)
      : empty('لا أحداث مؤهَّلة'))
      + pager(page.total, limit, offset, `/commissions/cycles/${id}/events`, m.query));
    wireFilters(view.el);
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
      + pager(page.total, limit, offset, `/commissions/cycles/${id}/exceptions`, m.query)
      + resolvePanel());
    wireResolve(view);
    return;
  }

  if (tab === 'review') {
    const blockers = await rpc<Array<Record<string, unknown>>>('commission_finalization_blockers', { p_cycle_id: id });
    const open = blockers || [];
    const total = open.reduce((a, b) => a + Number(b['indicative_amount'] || 0), 0);

    view.writeInto('#cycleTabBody',
      (open.length
        ? `<div class="insight danger" style="margin-bottom:12px"><span class="insight-dot"></span><span>
            <b>الاعتماد محجوب</b>
            <small>${open.length} سبباً · أثر مؤشِّر ${money(total)}. تُحسم الأسباب ثم يُعاد الحساب.</small></span></div>`
        : `<div class="insight good" style="margin-bottom:12px"><span class="insight-dot"></span><span>
            <b>لا مانع من الاعتماد</b><small>لا استثناء حاجب مفتوح في هذه الدورة.</small></span></div>`)
      + workflowPanel(cycle, open.length)
      + (open.length ? table(blockerColumns(), open) : ''));

    wireWorkflow(view, cycle, open.length);
    return;
  }

  if (tab === 'payout') {
    const rows = (await select<Snapshot[]>(`commission_cycle_snapshots?select=*&cycle_id=eq.${encodeURIComponent(id)}&order=gross_commission.desc`)) || [];
    view.writeInto('#cycleTabBody', `<div class="insight warn" style="margin-bottom:12px"><span class="insight-dot"></span><span>
        <b>الصرف يتبع الاعتماد</b>
        <small>لا نطاق يصير قابلاً للدفع قبل اعتماد الدورة. الخادم يُعيد التحقّق عند الترحيل مهما أظهرت الشاشة.</small></span></div>`
      + (rows.length ? table(payoutColumns(cycle), rows) : empty('لا نطاقات')));
    return;
  }

  if (tab === 'audit') {
    const offset = Number(m.query.get('offset') || 0);
    const raw = await rpc<Record<string, unknown>>('page_commission_cycle_audit_product', {
      p_cycle_id: id, p_limit: 50, p_offset: offset,
    });
    const page = envelope<Record<string, unknown>>(raw);
    const cols: Array<Column<Record<string, unknown>>> = [
      { key: 'when', label: 'متى', cell: (r) => esc(dateTime(r['created_at'])) },
      { key: 'who', label: 'من', cell: (r) => esc(r['actor'] ?? '—') },
      { key: 'what', label: 'ماذا', cell: (r) => `<b>${esc(r['action'] ?? '—')}</b><div class="muted">${esc(r['entity_type'] ?? '')}</div>` },
      { key: 'change', label: 'التغيير والسبب', cell: (r) => `${esc(r['old_value'] ?? '—')} ← ${esc(r['new_value'] ?? '—')}${r['extra'] ? `<div class="muted">${esc(r['extra'])}</div>` : ''}<details class="technical-detail"><summary>قبل / بعد</summary><pre>${esc(JSON.stringify({ before: r['before_data'], after: r['after_data'] }, null, 2))}</pre></details>` },
    ];
    view.writeInto('#cycleTabBody', page.rows.length ? table(cols, page.rows) + pager(page.total, 50, offset, `/commissions/cycles/${id}/audit`, m.query) : empty('لا أثر تدقيق لهذه الدورة'));
    return;
  }

  // overview — نفس عقد النتيجة المقروء مرة واحدة في رأس الشاشة. بقيّة
  // التبويبات (النطاقات، الأحداث، الاستثناءات، المراجعة، الصرف، التدقيق)
  // تقرأ من الخادم مباشرةً ولا تعتمد على `result`، فتبقى صحيحة بلا تعديل.
  if (!result) {
    view.writeInto('#cycleTabBody', empty('لم تُحسب هذه الدورة بعد', 'التفصيل حسب المنطقة يظهر بعد أوّل حساب'));
    return;
  }
  view.writeInto('#cycleTabBody', result.zones.length
    ? `<div class="box"><h3>حسب المنطقة</h3>${table(zoneColumns(), result.zones as unknown as Array<Record<string, unknown>>)}</div>`
    : empty('لا تفصيل متاح'));
}

const num = (r: Record<string, unknown>, k: string) => Number(r[k] || 0);

function scopeTable(rows: Snapshot[]): string {
  const columns: Array<Column<Snapshot>> = [
    { key: 'scope', label: 'النطاق', cell: (r) => `<a href="${esc(r.scope_type === 'AGENT' ? href(`/commissions/agents/${r.scope_id}`) : href(`/master/fdts/${encodeURIComponent(r.scope_id)}`))}"><b>${esc(r.scope_label || r.scope_id)}</b></a>
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
    { key: 'subscriber', label: 'المشترك', cell: (r) => `<b>${esc(r['subscriber'] ?? '—')}</b>
      <details class="technical-detail"><summary>تفاصيل تقنية</summary>
        <span dir="ltr">Key: ${esc(r['subscriber_key'] ?? '—')} · Event: ${esc(r['activation_event_id'] ?? '—')}</span></details>` },
    { key: 'agent', label: 'الوكيل', cell: (r) => r['agent_id'] ? `<a href="${esc(href(`/commissions/agents/${r['agent_id']}`))}">${esc(r['agent_name'] ?? '—')}</a>` : '—' },
    { key: 'fdt', label: 'الكابينة', cell: (r) => r['fdt_code'] ? `<a dir="ltr" href="${esc(href(`/master/fdts/${encodeURIComponent(String(r['fdt_code']))}`))}">${esc(r['fdt_code'])}</a>` : '—' },
    { key: 'source', label: 'المصدر', cell: (r) => esc(r['source'] ?? '—') },
    { key: 'pkg', label: 'الباقة', cell: (r) => `${esc(packageLabel(r['package_code']))}<details class="technical-detail"><summary>القيمة الخام</summary><code>${esc(r['package_code'] ?? '—')}</code></details>` },
    { key: 'tier', label: 'الشريحة', cell: (r) => esc(String(r['tier_code'] ?? '—').toUpperCase()), numeric: true },
    { key: 'amount', label: 'العمولة', cell: (r) => `<span class="money">${money(num(r, 'amount'))}</span>`, numeric: true },
    { key: 'at', label: 'تاريخ التفعيل', cell: (r) => `${esc(dateTime(r['event_at']))}<div class="muted table-hint">بتوقيت بغداد</div>` },
  ];
}

const EXCEPTION_LABELS: Record<string, string> = {
  UNKNOWN_FDT: 'كابينة تحتاج تصنيف',
  UNKNOWN_AGENT: 'الوكيل غير معروف',
  UNKNOWN_PACKAGE: 'باقة تحتاج تصنيف',
  SOURCE_INCOMPLETE: 'بيانات المصدر غير مكتملة',
  IDENTITY_CONFLICT: 'هوية تحتاج حسم',
  UNRESOLVED_OWNERSHIP: 'ملكية تحتاج حسم',
};

function exceptionLabel(code: unknown): string {
  const key = String(code || '');
  return EXCEPTION_LABELS[key] || key || 'قرار يحتاج مراجعة';
}

function exceptionColumns(): Array<Column<Record<string, unknown>>> {
  return [
    { key: 'reason', label: 'المشكلة', cell: (r) => `<b>${esc(exceptionLabel(r['reason_code']))}</b>
      <div class="muted table-hint">${esc(r['detail'] ?? '')}</div>
      <details class="technical-detail"><summary>تفاصيل تقنية</summary><code>${esc(r['reason_code'])}</code></details>` },
    { key: 'event', label: 'الحدث', cell: (r) => esc(r['activation_event_id'] ?? '—') },
    { key: 'fdt', label: 'الكابينة', cell: (r) => esc(r['fdt_code'] ?? '—') },
    { key: 'amount', label: 'أثر مؤشِّر', cell: (r) => money(num(r, 'indicative_amount')), numeric: true },
    { key: 'blocking', label: 'حاجب', cell: (r) => r['blocks_finalization'] ? chip('حاجب', 'critical') : chip('للمراجعة', 'warning') },
    { key: 'go', label: '', cell: (r) => actionLink(String(r['reason_code'] || ''), r)
      + (can('commission.review_exception') && String(r['status'] || 'OPEN') === 'OPEN'
        ? ` <button class="smallbtn exc-resolve"
             data-id="${esc(String(r['id'] ?? ''))}"
             data-reason="${esc(String(r['reason_code'] ?? ''))}">احسم</button>`
        : '') },
  ];
}

/**
 * حسم الاستثناء.
 *
 * حكمان لا واحد: «مُعالَج» يعني أن سببه زال فعلاً — صُنِّفت الكابينة أو
 * عُرِف الوكيل. و«مُتجاوَز» يعني أنه باقٍ وقُرِّر ألّا يحجب. الخلط بينهما
 * يجعل سجلّ الحسم بلا معنى بعد شهر، فيُفصلان ويُشترط لكلٍّ سببه.
 *
 * والحسم لا يُصلح البيانات: كابينةٌ مجهولة تبقى مجهولة بعد التجاوز. ولذلك
 * تبقى إلى جانبه وصلةُ شاشة الحسم الحقيقي.
 */
function wireResolve(view: View): void {
  const host = view.el.querySelector<HTMLElement>('#excResolve');
  const buttons = view.el.querySelectorAll<HTMLButtonElement>('.exc-resolve');
  if (!host || !buttons.length) return;

  const status = host.querySelector<HTMLSelectElement>('#exStatus');
  const note = host.querySelector<HTMLInputElement>('#exNote');
  const apply = host.querySelector<HTMLButtonElement>('#exApply');
  const label = host.querySelector<HTMLElement>('#exTarget');
  const out = host.querySelector<HTMLElement>('#exResult');
  if (!status || !note || !apply || !label || !out) return;

  let target = '';
  for (const btn of buttons) {
    btn.addEventListener('click', () => {
      target = btn.dataset['id'] || '';
      label.textContent = btn.dataset['reason'] || target;
      out.innerHTML = '';
      note.focus();
    });
  }

  apply.addEventListener('click', async () => {
    if (!target) { out.innerHTML = insight('warn', 'اختر استثناءً من الجدول'); return; }
    if (!status.value) { out.innerHTML = insight('warn', 'اختر الحكم'); return; }
    const why = note.value.trim();
    if (!why) {
      out.innerHTML = insight('warn', 'السبب إلزامي',
        'حسمٌ بلا سبب لا يُقرأ بعد شهر');
      return;
    }
    apply.disabled = true;
    out.innerHTML = loading('جارٍ الحسم…');
    try {
      await rpc('resolve_commission_exception', {
        p_exception_id: target,
        p_status: status.value,
        p_note: why,
        p_request_id: crypto.randomUUID(),
      });
      if (!view.live) return;
      out.innerHTML = insight('good', 'حُسم الاستثناء',
        status.value === 'WAIVED'
          ? 'تُجووِز ولم يزل سببه — البيانات كما هي.'
          : 'سُجِّل أن سببه عولج. تُعاد حسبة الدورة ليظهر الأثر.');
      window.setTimeout(() => { if (view.live) window.dispatchEvent(new CustomEvent('babil:refresh')); }, 1400);
    } catch (error) {
      if (!view.live) return;
      out.innerHTML = insight('danger', 'لم يُحسم الاستثناء',
        error instanceof Error ? error.message : 'خطأ غير متوقّع');
    } finally {
      apply.disabled = false;
    }
  });
}

function resolvePanel(): string {
  if (!can('commission.review_exception')) return '';
  return `<div class="box" style="margin-top:12px" id="excResolve">
    <h3>حسم استثناء</h3>
    <p class="muted" style="font-size:11px;margin:0 0 10px">
      اختر «احسم» من الجدول ثم الحكم والسبب.
      <b>مُعالَج</b> يعني أن السبب زال فعلاً، و<b>مُتجاوَز</b> يعني أنه باقٍ
      وقُرِّر ألّا يحجب. التجاوز لا يُصلح بيانات.</p>
    <div class="toolbar">
      <span class="muted">المحدَّد: <b id="exTarget">—</b></span>
      <select class="select" id="exStatus" aria-label="الحكم">
        <option value="">— الحكم —</option>
        <option value="RESOLVED">مُعالَج — زال السبب</option>
        <option value="WAIVED">مُتجاوَز — باقٍ ولا يحجب</option>
      </select>
      <input class="search" id="exNote" placeholder="السبب (إلزامي)" aria-label="سبب الحسم">
      <button class="btn gold" id="exApply">احسم</button>
    </div>
    <div id="exResult"></div>
  </div>`;
}

/** الاستثناء يقود إلى شاشة حسمه — لا إلى رسالة عامة. */
function actionLink(reason: string, row: Record<string, unknown>): string {
  const fdt = String(row['fdt_code'] || '');
  // مساران هنا كانا يشيران إلى ما لا وجود له: `/master/fdt` بلا جمع
  // و`/imports` بلا بادئة النظام. الزرّ كان يفتح «الصفحة غير موجودة» —
  // وهو أسوأ من غيابه، لأنه يَعِد بحسمٍ ثم يخذل.
  const map: Record<string, string> = {
    UNKNOWN_FDT: fdt ? href(`/master/fdts/${encodeURIComponent(fdt)}`) : href('/master/fdts/unknown'),
    UNKNOWN_AGENT: href('/master/agents'),
    UNKNOWN_PACKAGE: href('/master/packages'),
    SOURCE_INCOMPLETE: href('/system/imports'),
    IDENTITY_CONFLICT: href('/installation/subscribers'),
  };
  const target = map[reason];
  return target ? `<a class="smallbtn" href="${esc(target)}">افتح</a>` : '';
}

function blockerColumns(): Array<Column<Record<string, unknown>>> {
  return [
    { key: 'reason', label: 'المشكلة', cell: (r) => `<b>${esc(exceptionLabel(r['reason_code']))}</b>
      <details class="technical-detail"><summary>تفاصيل تقنية</summary><code>${esc(r['reason_code'])}</code></details>` },
    { key: 'events', label: 'أحداث', cell: (r) => count(num(r, 'events')), numeric: true },
    { key: 'subs', label: 'مشتركون', cell: (r) => count(num(r, 'subscribers')), numeric: true },
    { key: 'amount', label: 'أثر مؤشِّر', cell: (r) => money(num(r, 'indicative_amount')), numeric: true },
    { key: 'owner', label: 'الجهة', cell: (r) => esc(r['owner_hint'] ?? '—') },
    { key: 'action', label: 'الإجراء', cell: (r) => esc(r['action_hint'] ?? '—') },
  ];
}

function payoutColumns(cycle: Cycle): Array<Column<Snapshot>> {
  const approved = cycle.finalized_at !== null;
  return [
    { key: 'scope', label: 'النطاق', cell: (r) => esc(r.scope_label || r.scope_id) },
    { key: 'gross', label: 'الإجمالي', cell: (r) => `<span class="money">${money(r.gross_commission)}</span>`, numeric: true },
    { key: 'state', label: 'حالة التجهيز', cell: () => approved
      ? chip('بانتظار تجهيز الصرف', 'info')
      : chip('غير جاهز — الدورة لم تُعتمد', 'warning') },
  ];
}

function zoneColumns(): Array<Column<Record<string, unknown>>> {
  return [
    { key: 'zone', label: 'المنطقة', cell: (r) => chip(r['zone'] === 'new' ? 'جديدة (بالكابينة)' : 'قديمة (بالوكيل)', r['zone'] === 'new' ? 'success' : 'info') },
    { key: 'scopes', label: 'النطاقات', cell: (r) => count(num(r, 'scopes')), numeric: true },
    { key: 'subs', label: 'أساس التير', cell: (r) => count(num(r, 'tier_basis') || num(r, 'unique_activated_subscribers')), numeric: true },
    { key: 'events', label: 'تفعيلات مؤهَّلة', cell: (r) => count(num(r, 'events') || num(r, 'qualifying_events')), numeric: true },
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
    const profile = await rpc<Record<string, unknown>>('agent_financial_profile_product', { p_agent_id: id });
    if (!profile) { view.write(empty('الوكيل غير موجود')); return; }

    const agent = (profile['agent'] || {}) as Record<string, unknown>;
    const inst = (profile['installation'] || {}) as Record<string, unknown>;
    const fdts = (profile['fdts'] || []) as string[];
    const aliases = (profile['aliases'] || []) as string[];
    const cycleRows = (profile['commission_cycles'] || []) as Array<Record<string, unknown>>;
    const summary = (profile['commission_summary'] || {}) as Record<string, unknown>;
    const scopes = (profile['commission_scopes'] || []) as Array<Record<string, unknown>>;

    const stages = (inst['stage_distribution'] || {}) as Record<string, number>;

    view.innerHTML = pageHeader(String(agent['name'] || agent['code'] || 'وكيل'),
      String(agent['code'] || ''), chip(String(agent['status'] || '—'), 'neutral'))
      + kpiRow([
        { label: 'محسوب', value: money(Number(summary['calculated'] || 0)), tone: 'primary' },
        { label: 'معتمد', value: money(Number(summary['approved'] || 0)), tone: 'green' },
        { label: 'جاهز للصرف', value: money(Number(summary['ready'] || 0)), tone: 'gold' },
        { label: 'مدفوع', value: money(Number(summary['paid'] || 0)), tone: 'blue' },
      ])
      + `<div class="box"><div class="minirow"><span>المتبقي</span><b class="money">${money(Number(summary['remaining'] || 0))}</b></div></div>`
      // القاعدتان المحاسبيتان تبقيان منفصلتين في العرض: جمعهما يوحي بقاعدة لا وجود لها.
      + `<div class="grid2">
        <div class="box"><h3>النتيجة المالية حسب الدورة والنطاق</h3>
          ${scopes.length ? table(agentProductColumns(), scopes) : `<p class="muted">لا نطاقات محسوبة في الدورة</p>`}</div>
        <div class="box"><h3>تفصيل أجور التنصيب</h3>
          ${Object.keys(stages).length
            ? Object.entries(stages).map(([k, v]) => `<div class="minirow"><span>${esc(k)}</span><b>${count(v)}</b></div>`).join('')
            : `<p class="muted">لا مشتركين منسوبين — التسميات التاريخية لم تُربط بعد بالوكلاء المعتمدين</p>`}
        </div></div>`
      + `<div class="box agent-decisions"><h3>القرارات</h3>
          <p class="muted">قرارات الملكية غير المحسومة لا تُنسب إلى هذا الوكيل بلا دليل.</p>
          <a class="btn gold" href="${esc(href('/work/ownership'))}">راجع قرارات الملكية</a>
        </div>`
      + `<div class="box agent-details"><h3>التفاصيل</h3>
        <div class="minirow"><span>الكابينات</span><span>${fdts.length
          ? fdts.map((f) => `<a class="chip chip-neutral" href="${esc(href(`/master/fdts/${encodeURIComponent(f)}`))}">${esc(f)}</a>`).join(' ')
          : '—'}</span></div>
        <details class="technical-detail"><summary>الأسماء البديلة والتفاصيل التقنية</summary>
          <p>${aliases.length ? aliases.map((a) => esc(a)).join('، ') : 'لا أسماء بديلة'}</p>
          <code dir="ltr">${esc(id)}</code>
        </details></div>`;
  },
};

function agentProductColumns(): Array<Column<Record<string, unknown>>> {
  return [
    { key: 'zone', label: 'المنطقة', cell: (r) => esc(r['zone'] === 'new' ? 'جديدة' : 'قديمة') },
    { key: 'fdt', label: 'FDT / النطاق', cell: (r) => esc(r['fdt_code'] ?? '—') },
    { key: 'tier', label: 'الشريحة', cell: (r) => esc(r['tier_code'] ?? '—') },
    { key: 'p35', label: 'P35', cell: (r) => count(num(r,'p35_count')), numeric: true },
    { key: 'p45', label: 'P45', cell: (r) => count(num(r,'p45_count')), numeric: true },
    { key: 'p65', label: 'P65', cell: (r) => count(num(r,'p65_count')), numeric: true },
    { key: 'calc', label: 'محسوب', cell: (r) => money(num(r,'calculated')), numeric: true },
    { key: 'ready', label: 'جاهز', cell: (r) => money(num(r,'ready')), numeric: true },
    { key: 'paid', label: 'مدفوع', cell: (r) => money(num(r,'paid')), numeric: true },
  ];
}

function agentCycleColumns(): Array<Column<Record<string, unknown>>> {
  return [
    { key: 'cycle', label: 'الدورة', cell: (r) => `<b>${esc(r['cycle'] ?? '—')}</b>
      <div class="muted table-hint">${esc(cycleStatusAr(String(r['status'] || '')))}</div>` },
    { key: 'scope', label: 'النطاق', cell: (r) => esc(r['scope_id'] ?? '—') },
    { key: 'tier', label: 'الشريحة', cell: (r) => esc(String(r['tier'] ?? '—').toUpperCase()), numeric: true },
    { key: 'subs', label: 'مشتركون', cell: (r) => count(num(r, 'unique_activated_subscribers')), numeric: true },
    { key: 'events', label: 'تفعيلات', cell: (r) => count(num(r, 'qualifying_events')), numeric: true },
    { key: 'p35', label: 'P35', cell: (r) => count(num((r['package_breakdown'] || {}) as Record<string, unknown>, 'P-35000')), numeric: true },
    { key: 'p45', label: 'P45', cell: (r) => count(num((r['package_breakdown'] || {}) as Record<string, unknown>, 'P-45000')), numeric: true },
    { key: 'p65', label: 'P65', cell: (r) => count(num((r['package_breakdown'] || {}) as Record<string, unknown>, 'P-65000')), numeric: true },
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
          { value: 'UNKNOWN_FDT', label: 'كابينة تحتاج تصنيف' },
          { value: 'UNKNOWN_AGENT', label: 'وكيل غير معروف' },
          { value: 'UNKNOWN_PACKAGE', label: 'باقة غير معروفة' },
          { value: 'SOURCE_INCOMPLETE', label: 'بيانات المصدر غير مكتملة' },
          { value: 'IDENTITY_CONFLICT', label: 'تعارض هوية' },
        ] },
        { key: 'blocking', label: 'الحجب', type: 'select', options: [{ value: 'true', label: 'الحاجب فقط' }] },
      ], '/exceptions', m.query)
      + `<div class="muted" style="font-size:11px;margin-bottom:8px">
          ${count(page.total)} استثناءً · أثر الصفحة المؤشِّر ${money(impact)}</div>`
      + (page.rows.length ? table(exceptionColumns(), page.rows as Array<Record<string, unknown>>) : empty('لا استثناءات مطابقة'))
      + pager(page.total, limit, offset, '/exceptions', m.query)
      + resolvePanel();

    wireFilters(view.el);
    wireResolve(view);
  },
};

/* ---- انتقالات الدورة ------------------------------------------------------ */

/**
 * الحساب والاعتماد والإغلاق وإعادة الفتح.
 *
 * الشاشة تُظهر ما يسمح به الخادم فقط، لكن العكس ليس صحيحاً: إخفاء الزرّ
 * راحة، ورفض الطلب حراسة. الخادم يُعيد الفحص في كل نداء مهما أظهرت الشاشة —
 * `calculate_commission_cycle` يشترط `commission.finalize` عند الاعتماد،
 * و`close_commission_cycle` يرفض إغلاق دورةٍ لم تُعتمد.
 *
 * وحاجبٌ واحدٌ مفتوح يمنع الاعتماد. لا تُوهَن الحواجب لتمرّ الدورة — تُحسم
 * في شاشاتها ثم يُعاد الحساب.
 */
function workflowPanel(cycle: Cycle, blockers: number): string {
  const finalized = cycle.finalized_at !== null;
  const closed = cycle.status === 'CLOSED';
  const rows: string[] = [];

  // مساران للحساب على الخادم: الأعمّ يفحص `fdt.manage` ويردّ الفرق قبل وبعد،
  // والأبسط لا يردّه. يُختار الأعمّ لمن يملكه لأن الفرق هو جواب السؤال الذي
  // يُعاد الحساب لأجله: ماذا غيّر تصنيفي؟
  const delta = can('fdt.manage');
  if ((delta || can('commission.manage_cycle')) && !finalized) {
    rows.push(`<div class="minirow">
      <span><b>أعد الحساب</b>
        <div class="muted" style="font-size:11px">يُعيد بناء النطاقات والاستثناءات من البيانات الحالية.
          لا يعتمد ولا يدفع.${delta ? ' ويُظهر الفرق قبل وبعد.' : ''}</div></span>
      <button class="btn" id="wfRecalc">احسب</button></div>`);
  }

  if (can('commission.view')) {
    rows.push(`<div class="minirow">
      <span><b>صدِّر الدورة</b>
        <div class="muted" style="font-size:11px">لقطةٌ من الخادم بأرقامها كما هي، ويُسجَّل التصدير.</div></span>
      <button class="btn" id="wfExport">صدِّر</button></div>`);
  }

  if (can('commission.finalize') && !finalized) {
    rows.push(`<div class="minirow">
      <span><b>اعتمد الدورة</b>
        <div class="muted" style="font-size:11px">${blockers
          ? `محجوب بـ${count(blockers)} سبباً — يُحسم أوّلاً.`
          : 'يُثبِّت النطاقات لقطةً نهائية، وبعدها لا تُعاد الحسبة.'}</div></span>
      <button class="btn gold" id="wfFinalize" ${blockers ? 'disabled' : ''}>اعتمد</button></div>`);
  }

  if (can('commission.manage_cycle') && finalized && !closed) {
    rows.push(`<div class="minirow">
      <span><b>أقفل الدورة</b>
        <div class="muted" style="font-size:11px">بعد اكتمال الصرف. الإقفال يُنهي عمل الدورة.</div></span>
      <button class="btn" id="wfClose">أقفل</button></div>`);
  }

  if (can('commission.reopen') && finalized) {
    rows.push(`<div class="minirow">
      <span><b>أعد الفتح</b>
        <div class="muted" style="font-size:11px">يحتاج سبباً مكتوباً — الدورة المعتمدة تُفتح ولا يُمحى أثر اعتمادها.</div></span>
      <button class="btn" id="wfReopen">أعد الفتح</button></div>`);
  }

  // مسوّدةٌ فُتحت سهواً تُلغى ولا تُحذف. والشاشة لا تدّعي معرفةً بفراغها:
  // تعرض الإجراء لمن يملك القدرة وللمسوّدة وحدها، ويبقى `cancel_empty_commission_cycle`
  // هو الحكم على ما إذا كانت فارغةً فعلاً.
  if (canCancelDraft(cycle.status, can('commission.manage_cycle'))) {
    rows.push(`<div class="minirow">
      <span><b>⊘ ألغِ المسوّدة</b>
        <div class="muted" style="font-size:11px">لمسوّدةٍ فُتحت سهواً ولم يُحسب لها شيء.
          الإلغاء يحفظ الدورة في السجلّ ولا يحذف تاريخ إنشائها.</div></span>
      <button class="btn" id="wfCancelDraft">إلغاء المسودة</button></div>`);
  }

  if (!rows.length) {
    return `<div class="box" style="margin-bottom:12px">
      <p class="muted">لا إجراء متاح لك على هذه الدورة في حالتها الحالية.</p></div>`;
  }

  return `<div class="box" style="margin-bottom:12px" id="wfBox">
    <h3>إجراءات الدورة</h3>
    ${rows.join('')}
    <div class="toolbar" style="margin-top:10px">
      <input class="search" id="wfReason" placeholder="السبب — إلزامي للإقفال وإعادة الفتح وإلغاء المسوّدة"
        aria-label="سبب الإجراء">
    </div>
    <div id="wfResult"></div>
  </div>`;
}

function wireWorkflow(view: View, cycle: Cycle, blockers: number): void {
  const box = view.el.querySelector<HTMLElement>('#wfBox');
  if (!box) return;
  const reason = box.querySelector<HTMLInputElement>('#wfReason');
  const out = box.querySelector<HTMLElement>('#wfResult');
  if (!out) return;

  const run = async (
    button: HTMLButtonElement,
    label: string,
    needsReason: boolean,
    confirmText: string,
    call: (why: string) => Promise<unknown>,
    done: string,
  ) => {
    const why = reason?.value.trim() || '';
    if (needsReason && !why) {
      out.innerHTML = insight('warn', 'السبب إلزامي', `${label} يُقرأ لاحقاً في سجلّ التدقيق`);
      return;
    }
    if (!window.confirm(confirmText)) return;
    button.disabled = true;
    out.innerHTML = loading(`جارٍ ${label}…`);
    try {
      await call(why);
      if (!view.live) return;
      out.innerHTML = insight('good', done);
      // ولا يُعاد تمكين الزرّ بعد النجاح. اللوحة تبقى معروضةً حتى التحديث،
      // وضغطةٌ ثانية فيها ترسل طلباً ثانياً بمعرّفٍ جديد — فلا يردّه حارس
      // الإعادة على الخادم لأنه يميّز الطلب المُعاد بمعرّفه لا بأثره.
      window.setTimeout(() => { if (view.live) window.dispatchEvent(new CustomEvent('babil:refresh')); }, 1300);
    } catch (error) {
      if (!view.live) return;
      out.innerHTML = insight('danger', `لم يتم ${label}`,
        error instanceof Error ? error.message : 'خطأ غير متوقّع');
      // فشلٌ حقيقي: لم يقع شيء، فتُتاح المحاولة من جديد.
      button.disabled = false;
    }
  };

  const recalc = box.querySelector<HTMLButtonElement>('#wfRecalc');
  recalc?.addEventListener('click', async () => {
    if (!window.confirm(
      `إعادة حساب «${cycle.name}»؟ تُبنى النطاقات والاستثناءات من جديد، ولا يُعتمد شيء.`)) return;
    recalc.disabled = true;
    out.innerHTML = loading('جارٍ إعادة الحساب…');
    try {
      if (can('fdt.manage')) {
        const res = await rpc<Record<string, unknown>>('recalculate_cycle_after_master_change', {
          p_cycle_id: cycle.id, p_request_id: crypto.randomUUID(),
        });
        if (!view.live) return;
        const g0 = Number(res['gross_before'] || 0);
        const g1 = Number(res['gross_after'] || 0);
        const b0 = Number(res['blocking_before'] || 0);
        const b1 = Number(res['blocking_after'] || 0);
        out.innerHTML = insight('good', 'أُعيد الحساب',
          `المحسوب ${money(g0)} ← ${money(g1)} · الحواجب ${count(b0)} ← ${count(b1)}`);
      } else {
        await rpc('calculate_commission_cycle', {
          p_cycle_id: cycle.id, p_finalize: false, p_request_id: crypto.randomUUID(),
        });
        if (!view.live) return;
        out.innerHTML = insight('good', 'أُعيد الحساب');
      }
      window.setTimeout(() => { if (view.live) window.dispatchEvent(new CustomEvent('babil:refresh')); }, 1800);
    } catch (error) {
      if (!view.live) return;
      out.innerHTML = insight('danger', 'لم يتم إعادة الحساب',
        error instanceof Error ? error.message : 'خطأ غير متوقّع');
      recalc.disabled = false;
    }
  });

  const exportBtn = box.querySelector<HTMLButtonElement>('#wfExport');
  exportBtn?.addEventListener('click', async () => {
    exportBtn.disabled = true;
    out.innerHTML = loading('جارٍ تجهيز التصدير…');
    try {
      const res = await rpc<Record<string, unknown>>('export_commission_cycle', {
        p_cycle_id: cycle.id, p_request_id: crypto.randomUUID(),
      });
      if (!view.live) return;
      downloadJson(`${cycle.name}.json`, res);
      out.innerHTML = insight('good', 'نُزِّل التصدير', 'وسُجِّل في سجلّ التدقيق.');
      // التصدير يكتب سطر تدقيقٍ أيضاً، فضغطتان تُسجَّلان تصديرين لنيّةٍ واحدة.
      // ولا يُقفل كالبقيّة: إعادة التصدير نيّةٌ مشروعة، ولا تحديث بعده يُعيد
      // بناء اللوحة — فمهلةٌ قصيرة تكفي لالتقاط الضغطة المزدوجة وحدها.
      window.setTimeout(() => { if (view.live) exportBtn.disabled = false; }, 1300);
    } catch (error) {
      if (!view.live) return;
      out.innerHTML = insight('danger', 'لم يتم التصدير',
        error instanceof Error ? error.message : 'خطأ غير متوقّع');
      exportBtn.disabled = false;
    }
  });

  const finalize = box.querySelector<HTMLButtonElement>('#wfFinalize');
  finalize?.addEventListener('click', () => {
    if (blockers) {
      out.innerHTML = insight('danger', 'الاعتماد محجوب',
        'تُحسم الأسباب في شاشاتها ثم يُعاد الحساب. لا يُوهَن حاجبٌ ليمرّ الاعتماد.');
      return;
    }
    return run(finalize, 'الاعتماد', false,
      `اعتماد «${cycle.name}» نهائياً؟ تُثبَّت النطاقات لقطةً لا تُعاد حسبتها.`,
      () => rpc('calculate_commission_cycle', {
        p_cycle_id: cycle.id, p_finalize: true, p_request_id: crypto.randomUUID(),
      }),
      'اعتُمدت الدورة');
  });

  const close = box.querySelector<HTMLButtonElement>('#wfClose');
  close?.addEventListener('click', () => run(close, 'الإقفال', true,
    `إقفال «${cycle.name}»؟`,
    (why) => rpc('close_commission_cycle', {
      p_cycle_id: cycle.id, p_reason: why, p_request_id: crypto.randomUUID(),
    }),
    'أُقفلت الدورة'));

  const reopen = box.querySelector<HTMLButtonElement>('#wfReopen');
  reopen?.addEventListener('click', () => run(reopen, 'إعادة الفتح', true,
    `إعادة فتح «${cycle.name}»؟ الأثر المسجَّل لاعتمادها يبقى.`,
    (why) => rpc('reopen_commission_cycle', {
      p_cycle_id: cycle.id, p_reason: why, p_request_id: crypto.randomUUID(),
    }),
    'أُعيد فتح الدورة'));

  // الإلغاء خطوتان: السبب أوّلاً، ثم تأكيدٌ يعرض ما يُلغى بالضبط قبل التنفيذ.
  const cancelDraft = box.querySelector<HTMLButtonElement>('#wfCancelDraft');
  cancelDraft?.addEventListener('click', () => {
    const why = reason?.value.trim() || '';
    if (!why) {
      const need = cancelDraftError('needs a reason');
      out.innerHTML = insight('warn', need.title, need.detail);
      reason?.focus();
      return;
    }
    out.innerHTML = cancelDraftConfirm(cycle, why);

    out.querySelector<HTMLButtonElement>('#wfCancelBack')
      ?.addEventListener('click', () => { out.innerHTML = ''; });

    const go = out.querySelector<HTMLButtonElement>('#wfCancelGo');
    go?.addEventListener('click', async () => {
      // ضغطتان لا تصيران طلبين: الحارس هنا، ومعرّف الطلب يحرس الخادم لو سبق أحدهما.
      if (go.disabled) return;
      go.disabled = true;
      cancelDraft.disabled = true;
      out.innerHTML = loading('جارٍ إلغاء المسودة…');
      try {
        const res = await rpc<Record<string, unknown>>('cancel_empty_commission_cycle', {
          p_cycle_id: cycle.id,
          p_reason: why,
          p_request_id: crypto.randomUUID(),
        });
        if (!view.live) return;
        const done = cancelDraftSuccess(!!res && res['replayed'] === true);
        out.innerHTML = insight('good', done.title, done.detail);
        // الدورة لم تعد عاملة، فلا يُترك المستخدم واقفاً على تفاصيلها.
        window.setTimeout(() => {
          if (view.live) window.location.hash = href('/commissions/cycles');
        }, 1300);
      } catch (error) {
        if (!view.live) return;
        // النصّ الخام يبقى للمهندس في الـconsole، ويُعرض للمستخدم سببٌ تشغيلي.
        console.error('cancel_empty_commission_cycle', error);
        const failed = cancelDraftError(error instanceof Error ? error.message : '');
        out.innerHTML = insight('danger', failed.title, failed.detail);
        // لم يتغيّر شيء على الخادم، فلا تُغيَّر حالة الدورة على الشاشة.
        cancelDraft.disabled = false;
      }
    });
  });
}

/**
 * تأكيدُ الإلغاء يعرض ما يُلغى بالضبط.
 *
 * `window.confirm` تكفي لسؤالٍ من سطر، ولا تكفي هنا: التأكيد يجب أن يريَ اسم
 * الدورة وفترتها وحالتها والسبب المكتوب، وأن يحمل زرّه اسم فعله لا كلمة
 * «موافق». واللون وحده لا يُعوَّل عليه — النصّ والرمز يقولان ما يجري.
 */
function cancelDraftConfirm(cycle: Cycle, why: string): string {
  return `<div class="insight warn" style="margin-top:10px"><span class="insight-dot"></span><span>
    <b>⊘ تأكيد إلغاء المسودة</b>
    <small>الدورة: ${esc(cycle.name)}</small>
    <small>الفترة: ${esc(cycle.period_start)} — ${esc(cycle.period_end)}</small>
    <small>الحالة الحالية: مسودة</small>
    <small>الإلغاء يحفظ الدورة في السجل ولا يحذف تاريخ إنشائها.</small>
    <small>السبب: ${esc(why)}</small>
    <div class="toolbar" style="margin-top:8px">
      <button class="btn" id="wfCancelGo">تأكيد إلغاء المسودة</button>
      <button class="btn" id="wfCancelBack">تراجع</button>
    </div></span></div>`;
}

/** التصدير يُنزَّل كما ردّه الخادم، دون إعادة تشكيلٍ في المتصفّح. */
function downloadJson(filename: string, payload: unknown): void {
  const blob = new Blob([JSON.stringify(payload, null, 2)], {
    type: 'application/json;charset=utf-8',
  });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}

function insight(tone: 'good' | 'warn' | 'danger', title: string, detail = ''): string {
  return `<div class="insight ${tone}" style="margin-top:10px"><span class="insight-dot"></span><span>
    <b>${esc(title)}</b>${detail ? `<small>${esc(detail)}</small>` : ''}</span></div>`;
}

export const routes: Route[] = [
  overview, cycleList, cycleDetail, cycleTab, agentList, agentDetail, exceptionsQueue,
];

export { can };
