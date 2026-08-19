/**
 * البيانات المرجعية — سجلّ الآباء وحسم عائديتهم.
 *
 * الأب اسمٌ ورد من المصدر. والعائدية حكمٌ يوضع بجانبه، لا تسميةٌ تحلّ محلّه:
 * «hrins.office» يبقى «hrins.office» في كل شاشة، سواء صُنّف وكيلاً أو تابعاً
 * للشركة أو بقي بلا حسم.
 *
 * هذه الشاشة كانت أكبر ثغرة تشغيلية: 22 أباً بلا تصنيف، وقرارُ تصنيفِ أيٍّ
 * منها قرارٌ ماليّ — يقرّر من يستحق العمولة — وكان يُتَّخذ خارج النظام.
 */

import type { Route, View } from '../../app/router';
import { href } from '../../app/router';
import { rpc, pageRpc, can, ApiError } from '../../services/api';
import { money, count } from '../../domain/money';
import {
  esc, loading, empty, pageHeader, table, pager, chip,
  filterBar, wireFilters, kpiRow, type Column,
} from '../../components/ui';

type Row = Record<string, unknown>;
const num = (r: Row, k: string) => Number(r[k] || 0);
const str = (r: Row, k: string) => String(r[k] ?? '');

/** التصنيف ثلاثي. وأسماء الآباء ليست تصنيفات. */
export const OWNERSHIP: Array<{ value: string; label: string }> = [
  { value: 'RESELLER', label: 'وكيل' },
  { value: 'DIRECT_COMPANY', label: 'الشركة' },
  { value: 'NEEDS_REVIEW', label: 'تحتاج مراجعة' },
];

export const OWNERSHIP_LABEL: Record<string, string> =
  Object.fromEntries(OWNERSHIP.map((o) => [o.value, o.label]));

export function ownershipChip(type: string): string {
  const tone: 'info' | 'warning' | 'brand' = type === 'RESELLER' ? 'info'
    : type === 'NEEDS_REVIEW' ? 'warning' : 'brand';
  return chip(OWNERSHIP_LABEL[type] || type || '—', tone);
}

/** الاسم الأصلي يُعرض لاتينياً ومحفوظاً حرفياً — لا يُترجم ولا يُختصر. */
function parentName(name: string): string {
  return `<span class="parent-name" dir="ltr">${esc(name)}</span>`;
}

const date = (v: unknown) => (v ? String(v).slice(0, 10) : '—');

/* ---- سجلّ الآباء --------------------------------------------------------- */

export const parents: Route = {
  pattern: '/master/parents',
  capability: 'agent.view',
  title: 'الآباء',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'البيانات المرجعية' },
    { label: 'الآباء' },
  ],
  async render(view, m) {
    const limit = 50;
    const offset = Number(m.query.get('offset') || 0);
    view.innerHTML = loading('جارٍ تحميل سجلّ الآباء…');

    const args: Record<string, unknown> = { p_limit: limit, p_offset: offset };
    const own = m.query.get('ownership');
    const search = m.query.get('search');
    if (own) args['p_ownership'] = own;
    if (search) args['p_search'] = search;

    const page = await pageRpc<Row>('list_parents', args, view.signal);

    // العدّ على الصفحة المعروضة لا على المجموعة كلها، فيُقال ذلك صراحةً بدل
    // أن يُقرأ رقمُ صفحةٍ على أنه رقم النظام.
    const pending = page.rows.filter((r) => str(r, 'ownership') === 'NEEDS_REVIEW').length;

    const columns: Array<Column<Row>> = [
      // الاسم أولاً وكما ورد. هذا هو العمود الذي يبحث عنه المشغّل في ملف المصدر.
      { key: 'name', label: 'الأب (كما ورد في المصدر)', cell: (r) => parentName(str(r, 'parent_name')) },
      { key: 'own', label: 'العائدية', cell: (r) => ownershipChip(str(r, 'ownership')) },
      { key: 'agent', label: 'الوكيل المرتبط', cell: (r) => {
        const n = str(r, 'agent_name');
        if (!n) return '<span class="muted">—</span>';
        const code = str(r, 'agent_code');
        return `${esc(n)}${code ? ` <span class="muted">(${esc(code)})</span>` : ''}`;
      } },
      { key: 'subs', label: 'المشتركون', cell: (r) => count(num(r, 'subscribers')), numeric: true },
      { key: 'ev', label: 'الأحداث', cell: (r) => count(num(r, 'events')), numeric: true },
      { key: 'seen', label: 'آخر ظهور', cell: (r) => `<span dir="ltr">${esc(date(r['last_seen']))}</span>`, numeric: true },
      { key: 'go', label: '', cell: (r) => `<a class="smallbtn" href="${esc(hrefParent(str(r, 'parent_name')))}">افحص</a>` },
    ];

    view.innerHTML = pageHeader('سجلّ الآباء',
      'الاسم كما ورد من المصدر. التصنيف حكمٌ بجانبه لا تسميةٌ بديلة.')
      + (pending
        ? `<div class="insight warn"><span class="insight-dot"></span><span>
           <b>${count(pending)} أباً في هذه الصفحة بلا حسم</b>
           <small>لا عمولة تُصرف على أساسها قبل أن تُحسم عائديتها.</small></span></div>`
        : '')
      + filterBar([
        { key: 'search', label: 'بحث بالاسم', type: 'search' },
        { key: 'ownership', label: 'العائدية', type: 'select', options: OWNERSHIP },
      ], '/master/parents', m.query)
      + (page.outOfRange
        ? `<div class="insight warn"><span class="insight-dot"></span><span><b>الصفحة خارج المدى</b>
           <small>المجموعة فيها ${count(page.total)} صفّاً. عُد إلى الصفحة الأولى.</small></span></div>`
        : '')
      + (page.rows.length
        ? table(columns, page.rows, (r) => `location.hash='${hrefParent(str(r, 'parent_name')).slice(1)}'`)
        : empty('لا آباء مطابقين'))
      + pager(page.total, limit, offset, '/master/parents', m.query);

    wireFilters(view.el);
  },
};

function hrefParent(name: string): string {
  return href(`/master/parents/${encodeURIComponent(name)}`);
}

/* ---- حسم عائدية أب ------------------------------------------------------- */

const MEANING: Record<string, { text: string; tone: 'warning' | 'brand' | 'info' }> = {
  AWAITING_DECISION: { text: 'مبلغ ينتظر هذا القرار — لا يُصرف قبل الحسم', tone: 'warning' },
  NO_RESELLER_COMMISSION: { text: 'لا عمولة وكيل تنشأ عن هذا الأب', tone: 'brand' },
  AGENT_BASIS: { text: 'أساس مؤشِّر لعمولة الوكيل المرتبط', tone: 'info' },
};

export const parentCase: Route = {
  pattern: '/master/parents/:name',
  capability: 'agent.view',
  title: 'حسم عائدية أب',
  breadcrumb: (m) => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'الآباء', href: href('/master/parents') },
    { label: decodeURIComponent(m.params['name'] || '') },
  ],
  async render(view, m) {
    const name = decodeURIComponent(m.params['name'] as string);
    view.innerHTML = loading('جارٍ جمع الشواهد…');

    const doc = await rpc<Row>('parent_evidence', { p_parent_name: name });
    if (!doc || doc['found'] !== true) {
      view.innerHTML = empty('لا شواهد لهذا الأب', name);
      return;
    }

    const exact = str(doc, 'parent_name');
    const own = str(doc, 'ownership');
    const vol = (doc['volume'] || {}) as Row;
    const exp = (doc['exposure'] || {}) as Row;
    const cls = (doc['classification'] || null) as Row | null;
    const packages = (doc['packages'] || []) as Row[];
    const related = (doc['related_parents'] || []) as Row[];
    const samples = (doc['samples'] || []) as Row[];
    const audit = (doc['audit'] || []) as Row[];

    const meaning = MEANING[str(exp, 'meaning')] || null;

    view.innerHTML = pageHeader(exact,
      'الاسم كما ورد في المصدر — لا يتغيّر بأيّ قرار أدناه',
      ownershipChip(own))

      + kpiRow([
        { label: 'المشتركون', value: count(num(vol, 'subscribers')), tone: 'primary',
          sub: `${count(num(vol, 'events'))} حدثاً` },
        { label: 'المبلغ المؤشِّر في الدورة', value: money(num(exp, 'indicative_amount')),
          tone: own === 'NEEDS_REVIEW' ? 'red' : 'gold',
          sub: meaning ? meaning.text : 'خارج أي دورة مفتوحة' },
        { label: 'أول ظهور', value: date(vol['first_seen']), tone: 'blue' },
        { label: 'آخر ظهور', value: date(vol['last_seen']), tone: 'blue' },
      ])

      + `<div class="grid2">
        <div class="box">
          <h3>التصنيف الحالي</h3>
          <div class="minirow"><span class="muted">العائدية</span><b>${ownershipChip(own)}</b></div>
          <div class="minirow"><span class="muted">الوكيل المرتبط</span>
            <b>${cls && str(cls, 'agent_name') ? esc(str(cls, 'agent_name')) : '—'}</b></div>
          <div class="minirow"><span class="muted">آخر تعديل</span>
            <b dir="ltr">${cls ? esc(date(cls['updated_at'])) : '—'}</b></div>
          ${own === 'NEEDS_REVIEW'
            ? `<p class="muted" style="font-size:11px;margin-top:8px">
               بلا حسم: الأحداث لا تُنسب إلى وكيل ولا إلى الشركة، والمبلغ أعلاه موقوف.</p>`
            : ''}
        </div>
        <div class="box">
          <h3>الباقات</h3>
          ${packages.length
            ? packages.map((p) => `<div class="minirow">
                <span dir="ltr">${esc(str(p, 'package') || '—')}</span>
                <b>${count(num(p, 'subscribers'))}</b></div>`).join('')
            : '<p class="muted">لا باقات</p>'}
        </div>
      </div>`

      // تداخل المشتركين: واقعةٌ في البيانات، لا تشابهُ حروف. تُعرض لأن أعطاب
      // التصدير أسقطت حروفاً من الأسماء («hrins.oice» عن «hrins.office»)،
      // فصار الأب الواحد أبوين. القرار للمشغّل — لا ربط تلقائي.
      + (related.length
        ? `<section style="margin-top:16px"><div class="box">
            <h3>آباء يتقاسمون المشتركين أنفسهم</h3>
            <p class="muted" style="font-size:11px;margin:0 0 8px">
              مشتركون حقيقيون ظهروا تحت الاسمين معاً. شاهدٌ يُقرأ، لا استنتاجٌ يُطبَّق.</p>
            ${related.map((r) => `<a class="minirow" style="text-decoration:none;color:inherit"
                href="${esc(hrefParent(str(r, 'parent_name')))}">
                <span>${parentName(str(r, 'parent_name'))} ${ownershipChip(str(r, 'ownership'))}</span>
                <b>${count(num(r, 'shared_subscribers'))} مشتركاً مشترَكاً بينهما</b></a>`).join('')}
          </div></section>`
        : '')

      + decisionPanel(exact, own, cls)

      + `<section style="margin-top:16px"><div class="box">
          <h3>عيّنة من المصدر</h3>
          <p class="muted" style="font-size:11px;margin:0 0 8px">
            كما كُتبت في ملف الاستيراد، بالورقة والسطر.</p>
          ${samples.length ? table<Row>([
            { key: 'u', label: 'المستخدم', cell: (r) => `<span dir="ltr">${esc(str(r, 'username'))}</span>` },
            { key: 'p', label: 'الباقة', cell: (r) => `<span dir="ltr">${esc(str(r, 'profile_name') || '—')}</span>` },
            { key: 'd', label: 'التاريخ', cell: (r) => `<span dir="ltr">${esc(String(r['event_created_at'] ?? '').slice(0, 16))}</span>` },
            { key: 'f', label: 'الكابينة', cell: (r) => `<span dir="ltr">${esc(str(r, 'fdt_code') || '—')}</span>` },
            { key: 'raw', label: 'الأب كما ورد', cell: (r) => parentName(str(r, 'raw_parent')) },
            { key: 's', label: 'المصدر', cell: (r) => `<span dir="ltr" class="muted">${esc(str(r, 'source_sheet'))}:${esc(str(r, 'source_row'))}</span>` },
          ], samples) : '<p class="muted">لا عيّنات</p>'}
        </div></section>`

      + (audit.length
        ? `<section style="margin-top:16px"><div class="box">
            <h3>سجلّ القرارات</h3>
            ${audit.map((a) => `<div class="minirow">
              <span><b dir="ltr">${esc(date(a['created_at']))}</b>
                ${esc(str(a, 'old_value') || '—')} ← ${esc(str(a, 'new_value'))}</span>
              <span class="muted">${esc(str(a, 'actor_email') || '—')}</span></div>`).join('')}
          </div></section>`
        : '');

    wireDecision(view, exact);
  },
};

/**
 * القرارات الثلاثة.
 *
 * «تابع للشركة» لا يعيد التسمية: الاسم أعلاه يبقى كما هو بعد الحفظ. هذا
 * مكتوبٌ في الشاشة لا في التوثيق وحده، لأن الخطأ الذي سبق كان أن يُفهم
 * التصنيف تسميةً.
 */
function decisionPanel(name: string, own: string, cls: Row | null): string {
  if (!can('agent.manage')) {
    return `<section style="margin-top:16px"><div class="box">
      <h3>الحسم</h3>
      <p class="muted">تحتاج صلاحية <code>agent.manage</code> لتغيير العائدية.</p>
    </div></section>`;
  }
  const currentAgent = cls ? str(cls, 'agent_id') : '';
  return `<section style="margin-top:16px"><div class="box" id="decisionBox">
    <h3>الحسم</h3>
    <p class="muted" style="font-size:11px;margin:0 0 10px">
      الاسم <span class="parent-name" dir="ltr">${esc(name)}</span> يبقى كما هو في كل الحالات.
      القرار يحدّد من يستحق مالياً، لا كيف يُكتب الاسم.</p>

    <div class="toolbar" style="margin-bottom:10px">
      <select class="select" id="decChoice" aria-label="القرار">
        <option value="">— اختر القرار —</option>
        <option value="RESELLER"${own === 'RESELLER' ? ' selected' : ''}>ربط بوكيل</option>
        <option value="DIRECT_COMPANY"${own === 'DIRECT_COMPANY' ? ' selected' : ''}>تابع للشركة</option>
        <option value="NEEDS_REVIEW"${own === 'NEEDS_REVIEW' ? ' selected' : ''}>تحتاج مراجعة</option>
      </select>
      <select class="select" id="decAgent" aria-label="الوكيل" style="display:none">
        <option value="">— جارٍ تحميل الوكلاء —</option>
      </select>
      <input class="search" id="decReason" placeholder="سبب القرار (يُحفظ في التدقيق)"
        aria-label="سبب القرار">
      <button class="btn gold" id="decApply" data-current-agent="${esc(currentAgent)}">احفظ القرار</button>
    </div>
    <div id="decResult"></div>
  </div></section>`;
}

function wireDecision(view: View, name: string): void {
  const root = view.el;
  const choice = root.querySelector<HTMLSelectElement>('#decChoice');
  const agent = root.querySelector<HTMLSelectElement>('#decAgent');
  const reason = root.querySelector<HTMLInputElement>('#decReason');
  const apply = root.querySelector<HTMLButtonElement>('#decApply');
  const out = root.querySelector<HTMLElement>('#decResult');
  if (!choice || !agent || !apply || !out) return;

  let agentsLoaded = false;
  const loadAgents = async () => {
    if (agentsLoaded) return;
    agentsLoaded = true;
    try {
      const list = await rpc<Row[]>('list_agents_for_pick', {});
      if (!view.live) return;
      const current = apply.dataset['currentAgent'] || '';
      agent.innerHTML = '<option value="">— اختر الوكيل —</option>'
        + (list || []).map((a) => `<option value="${esc(str(a, 'id'))}"${str(a, 'id') === current ? ' selected' : ''}>${esc(str(a, 'official_name'))}${str(a, 'code') ? ` (${esc(str(a, 'code'))})` : ''}</option>`).join('');
    } catch {
      agentsLoaded = false;
      agent.innerHTML = '<option value="">تعذّر تحميل الوكلاء</option>';
    }
  };

  const syncAgentVisibility = () => {
    const needsAgent = choice.value === 'RESELLER';
    agent.style.display = needsAgent ? '' : 'none';
    if (needsAgent) void loadAgents();
  };
  choice.addEventListener('change', syncAgentVisibility);
  syncAgentVisibility();

  apply.addEventListener('click', async () => {
    const ownership = choice.value;
    if (!ownership) {
      out.innerHTML = `<div class="insight warn"><span class="insight-dot"></span><span>اختر قراراً أولاً</span></div>`;
      return;
    }
    if (ownership === 'RESELLER' && !agent.value) {
      out.innerHTML = `<div class="insight warn"><span class="insight-dot"></span><span>«ربط بوكيل» يحتاج وكيلاً محدَّداً</span></div>`;
      return;
    }

    apply.disabled = true;
    out.innerHTML = loading('جارٍ حفظ القرار…');
    try {
      // معرّف الطلب يجعل النقرة المكرّرة بلا أثر ثانٍ.
      const result = await rpc<Row>('classify_parent', {
        p_parent_name: name,
        p_ownership: ownership,
        p_agent_id: ownership === 'RESELLER' ? agent.value : null,
        p_reason: reason?.value.trim() || null,
        p_request_id: crypto.randomUUID(),
      });
      if (!view.live) return;
      const same = result?.['idempotent'] === true;
      out.innerHTML = `<div class="insight good"><span class="insight-dot"></span><span>
        <b>${same ? 'القرار مسجَّل مسبقاً' : 'حُفظ القرار'}</b>
        <small>الاسم <span dir="ltr">${esc(name)}</span> لم يتغيّر.
        ${same ? '' : `العائدية الآن: ${esc(OWNERSHIP_LABEL[ownership] || ownership)}.`}</small>
        </span></div>`;
      window.setTimeout(() => { if (view.live) window.location.reload(); }, 1200);
    } catch (error) {
      if (!view.live) return;
      const message = error instanceof ApiError ? error.message : 'تعذّر حفظ القرار';
      out.innerHTML = `<div class="insight danger"><span class="insight-dot"></span><span>
        <b>لم يُحفظ</b><small>${esc(message)}</small></span></div>`;
    } finally {
      apply.disabled = false;
    }
  });
}

export const routes: Route[] = [parents, parentCase];
