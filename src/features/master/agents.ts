/**
 * الوكلاء والباقات — البيانات الرئيسية التي يُبنى عليها المال.
 *
 * ليست هذه شاشة «إعدادات». كل حقلٍ فيها مُدخَل مالي:
 *
 *   - تصنيف الباقة يقرّر أيُحتسب الحدث في العمولة أم لا.
 *   - منطقة الوكيل تقرّر أجر التنصيب.
 *   - تعطيل وكيلٍ يوقف ما لم يُصرف بعد.
 *
 * ولذلك لا كتابة مباشرة من المتصفّح: الجداول مقروءةٌ عبر PostgREST،
 * والكتابة تمرّ بدالّةٍ تفحص القدرة على الخادم وتُسجّل الأثر. إخفاء الزرّ
 * راحةٌ للعين لا حراسة — الحارس هناك.
 *
 * والباقة الواردة في المصدر وغير المعرَّفة تُعرض هنا بصريح القول إنها غير
 * مسجَّلة، وبعدد أحداثها. إخفاؤها يترك أحداثاً لا يعرف النظام كيف يسعّرها.
 */

import type { Route, View } from '../../app/router';
import { href } from '../../app/router';
import { rpc, pageRpc, can, ApiError } from '../../services/api';
import { count } from '../../domain/money';
import {
  esc, loading, empty, pageHeader, table, pager, kpiRow, chip,
  filterBar, wireFilters, type Column,
} from '../../components/ui';

type Row = Record<string, unknown>;
const num = (r: Row, k: string) => Number(r[k] || 0);
const str = (r: Row, k: string) => String(r[k] ?? '');

/** المناطق كما يقبلها قيد الجدول — لا قائمة مخترعة في الواجهة. */
const ZONES: Array<{ value: string; label: string }> = [
  { value: 'old', label: 'قديمة' },
  { value: 'new', label: 'جديدة' },
  { value: 'both', label: 'الاثنتان' },
  { value: 'direct', label: 'مباشرة' },
];

const CATEGORIES: Array<{ value: string; label: string; hint: string }> = [
  { value: 'PAID_PACKAGE', label: 'باقة مدفوعة', hint: 'حدثها مؤهَّل للعمولة' },
  { value: 'DEBT_SERVICE', label: 'خدمة دين', hint: 'لا تُحتسب في العمولة' },
  { value: 'OTHER', label: 'أخرى', hint: 'معرَّفة ولا تُحتسب' },
  { value: 'UNKNOWN', label: 'غير محسوم', hint: 'يمنع التسعير حتى يُحسم' },
  { value: 'DEPRECATED', label: 'متوقّفة', hint: 'لا تُستعمل في الجديد' },
];

const zoneLabel = (v: string) => ZONES.find((z) => z.value === v)?.label || v;
const catLabel = (v: string) => CATEGORIES.find((c) => c.value === v)?.label || v;

function insight(tone: 'good' | 'warn' | 'danger', title: string, detail = ''): string {
  return `<div class="insight ${tone}" style="margin-top:10px"><span class="insight-dot"></span><span>
    <b>${esc(title)}</b>${detail ? `<small>${esc(detail)}</small>` : ''}</span></div>`;
}

/* ---- الوكلاء ------------------------------------------------------------- */

export const agents: Route = {
  pattern: '/master/agents',
  capability: 'agent.view',
  title: 'الوكلاء',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'البيانات الرئيسية' },
    { label: 'الوكلاء' },
  ],
  async render(view, m) {
    const limit = 50;
    const offset = Number(m.query.get('offset') || 0);
    view.innerHTML = loading('جارٍ تحميل الوكلاء…');

    const args: Record<string, unknown> = { p_limit: limit, p_offset: offset };
    const search = m.query.get('search');
    const status = m.query.get('status');
    if (search) args['p_search'] = search;
    if (status) args['p_status'] = status;

    const page = await pageRpc<Row>('page_agents', args, view.signal);
    if (!view.live) return;

    const active = page.rows.filter((r) => str(r, 'status') === 'active').length;
    const noZone = page.rows.filter((r) => !str(r, 'zone')).length;

    const columns: Array<Column<Row>> = [
      { key: 'code', label: 'الرمز', cell: (r) =>
        `<b dir="ltr">${esc(str(r, 'code'))}</b>` },
      { key: 'name', label: 'الاسم الرسمي', cell: (r) => esc(str(r, 'official_name')) },
      { key: 'zone', label: 'المنطقة', cell: (r) =>
        str(r, 'zone') ? chip(zoneLabel(str(r, 'zone')), 'info')
          : chip('غير محدّدة', 'warning') },
      { key: 'status', label: 'الحالة', cell: (r) =>
        str(r, 'status') === 'active' ? chip('فعّال', 'success') : chip('موقوف', 'neutral') },
      { key: 'subs', label: 'مشتركون', cell: (r) => count(num(r, 'subscribers')), numeric: true },
      { key: 'fdts', label: 'كابينات', cell: (r) => count(num(r, 'cabinets')), numeric: true },
      { key: 'aliases', label: 'مرادفات', cell: (r) => count(num(r, 'aliases')), numeric: true },
      { key: 'edit', label: '', cell: (r) => can('agent.manage')
        ? `<button class="smallbtn agent-edit"
             data-code="${esc(str(r, 'code'))}"
             data-name="${esc(str(r, 'official_name'))}"
             data-zone="${esc(str(r, 'zone'))}"
             data-status="${esc(str(r, 'status'))}"
             data-notes="${esc(str(r, 'notes'))}">تحرير</button>`
        : '' },
    ];

    view.innerHTML = pageHeader('الوكلاء',
      'منطقة الوكيل تقرّر أجر التنصيب، وحالته توقف ما لم يُصرف — فليست حقولاً وصفية')

      + kpiRow([
        { label: 'الوكلاء', value: count(page.total), tone: 'primary' },
        { label: 'الفعّالون في هذه الصفحة', value: count(active), tone: 'green' },
        { label: 'بلا منطقة', value: count(noZone),
          tone: noZone ? 'red' : 'green',
          sub: noZone ? 'أجر التنصيب لا يُحسم بلا منطقة' : 'كلّهم محدَّدو المنطقة' },
      ])

      + filterBar([
        { key: 'search', label: 'بحث بالرمز أو الاسم', type: 'search' },
        { key: 'status', label: 'الحالة', type: 'select', options: [
          { value: 'active', label: 'الفعّالون' },
          { value: 'inactive', label: 'الموقوفون' } ] },
      ], '/master/agents', m.query)

      + agentForm()
      + (page.rows.length ? table(columns, page.rows) : empty('لا وكلاء مطابقين'))
      + pager(page.total, limit, offset, '/master/agents', m.query);

    wireFilters(view.el);
    wireAgentForm(view);
  },
};

function agentForm(): string {
  if (!can('agent.manage')) {
    return `<div class="box" style="margin-top:12px">
      <p class="muted">العرض فقط — تحتاج صلاحية <code dir="ltr">agent.manage</code>
      لإضافة وكيل أو تعديله.</p></div>`;
  }
  return `<div class="box" style="margin-top:12px" id="agentBox">
    <h3 id="agentFormTitle">وكيل جديد</h3>
    <p class="muted" style="font-size:11px;margin:0 0 10px">
      الرمز لا يتغيّر بعد الحفظ — إدخال رمزٍ موجود يعني تعديل ذلك الوكيل.</p>
    <div class="toolbar">
      <input class="search" id="agCode" placeholder="الرمز" aria-label="رمز الوكيل" dir="ltr">
      <input class="search" id="agName" placeholder="الاسم الرسمي" aria-label="الاسم الرسمي">
      <select class="select" id="agZone" aria-label="المنطقة">
        <option value="">— المنطقة —</option>
        ${ZONES.map((z) => `<option value="${esc(z.value)}">${esc(z.label)}</option>`).join('')}
      </select>
      <select class="select" id="agStatus" aria-label="الحالة">
        <option value="active">فعّال</option>
        <option value="inactive">موقوف</option>
      </select>
      <input class="search" id="agNotes" placeholder="ملاحظة (اختياري)" aria-label="ملاحظة">
      <button class="btn gold" id="agSave">احفظ</button>
      <button class="btn" id="agReset">جديد</button>
    </div>
    <div id="agResult"></div>
  </div>`;
}

function wireAgentForm(view: View): void {
  const box = view.el.querySelector<HTMLElement>('#agentBox');
  if (!box) return;
  const code = box.querySelector<HTMLInputElement>('#agCode');
  const name = box.querySelector<HTMLInputElement>('#agName');
  const zone = box.querySelector<HTMLSelectElement>('#agZone');
  const status = box.querySelector<HTMLSelectElement>('#agStatus');
  const notes = box.querySelector<HTMLInputElement>('#agNotes');
  const save = box.querySelector<HTMLButtonElement>('#agSave');
  const reset = box.querySelector<HTMLButtonElement>('#agReset');
  const title = box.querySelector<HTMLElement>('#agentFormTitle');
  const out = box.querySelector<HTMLElement>('#agResult');
  if (!code || !name || !zone || !status || !save || !out) return;

  // «تحرير» يملأ النموذج بالقيم القائمة بدل أن يفتح شاشةً ثانية: التعديل
  // والإضافة نفس العملية على الخادم، فلا داعي لواجهتين تختلفان.
  for (const btn of view.el.querySelectorAll<HTMLButtonElement>('.agent-edit')) {
    btn.addEventListener('click', () => {
      code.value = btn.dataset['code'] || '';
      name.value = btn.dataset['name'] || '';
      zone.value = btn.dataset['zone'] || '';
      status.value = btn.dataset['status'] || 'active';
      if (notes) notes.value = btn.dataset['notes'] || '';
      if (title) title.textContent = `تعديل ${btn.dataset['code'] || ''}`;
      out.innerHTML = '';
      code.focus();
    });
  }

  reset?.addEventListener('click', () => {
    code.value = ''; name.value = ''; zone.value = '';
    status.value = 'active'; if (notes) notes.value = '';
    if (title) title.textContent = 'وكيل جديد';
    out.innerHTML = '';
  });

  save.addEventListener('click', async () => {
    if (!code.value.trim()) { out.innerHTML = insight('warn', 'الرمز إلزامي'); return; }
    if (!name.value.trim()) { out.innerHTML = insight('warn', 'الاسم الرسمي إلزامي'); return; }
    save.disabled = true;
    out.innerHTML = loading('جارٍ الحفظ…');
    try {
      const res = await rpc<Row>('upsert_agent', {
        p_code: code.value.trim(),
        p_official_name: name.value.trim(),
        p_status: status.value,
        p_zone: zone.value || null,
        p_notes: notes?.value.trim() || null,
        p_request_id: crypto.randomUUID(),
      });
      if (!view.live) return;
      out.innerHTML = insight('good', 'حُفظ الوكيل',
        res['idempotent'] === true ? 'الطلب نفسه سبق تنفيذه — لم يُكتب مرّتين' : '');
      window.setTimeout(() => { if (view.live) window.location.reload(); }, 1200);
    } catch (error) {
      if (!view.live) return;
      out.innerHTML = insight('danger', 'لم يُحفظ الوكيل',
        error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
    } finally {
      save.disabled = false;
    }
  });
}

/* ---- الباقات ------------------------------------------------------------- */

export const packages: Route = {
  pattern: '/master/packages',
  capability: 'agent.view',
  title: 'الباقات',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'البيانات الرئيسية' },
    { label: 'الباقات' },
  ],
  async render(view, m) {
    const limit = 50;
    const offset = Number(m.query.get('offset') || 0);
    view.innerHTML = loading('جارٍ تحميل الباقات…');

    const args: Record<string, unknown> = { p_limit: limit, p_offset: offset };
    const search = m.query.get('search');
    const category = m.query.get('category');
    if (search) args['p_search'] = search;
    if (category) args['p_category'] = category;

    const page = await pageRpc<Row>('page_packages', args, view.signal);
    if (!view.live) return;

    const missing = page.rows.filter((r) => r['registered'] !== true);
    const missingEvents = missing.reduce((a, r) => a + num(r, 'events'), 0);
    const undecided = page.rows.filter((r) =>
      r['registered'] === true && str(r, 'semantic_category') === 'UNKNOWN');

    const columns: Array<Column<Row>> = [
      { key: 'code', label: 'الرمز', cell: (r) =>
        `<b dir="ltr">${esc(str(r, 'code'))}</b>
         ${r['registered'] === true ? '' : chip('غير مسجَّلة', 'critical')}` },
      { key: 'cat', label: 'التصنيف', cell: (r) => {
        const c = str(r, 'semantic_category');
        return chip(catLabel(c),
          c === 'PAID_PACKAGE' ? 'success' : c === 'UNKNOWN' ? 'warning' : 'neutral');
      } },
      { key: 'events', label: 'أحداث في المصدر', cell: (r) => count(num(r, 'events')), numeric: true },
      { key: 'notes', label: 'ملاحظة', cell: (r) => esc(str(r, 'notes')) || '—' },
      { key: 'edit', label: '', cell: (r) => can('package.manage')
        ? `<button class="smallbtn pkg-edit"
             data-code="${esc(str(r, 'code'))}"
             data-name="${esc(str(r, 'name'))}"
             data-cat="${esc(str(r, 'semantic_category'))}"
             data-notes="${esc(str(r, 'notes'))}">تصنيف</button>`
        : '' },
    ];

    view.innerHTML = pageHeader('الباقات والخدمات',
      'التصنيف يقرّر أيُحتسب حدث الباقة في العمولة — فهو مُدخَل مالي لا وصف')

      + kpiRow([
        { label: 'الباقات', value: count(page.total), tone: 'primary' },
        { label: 'واردة ولم تُسجَّل', value: count(missing.length),
          tone: missing.length ? 'red' : 'green',
          sub: missing.length ? `${count(missingEvents)} حدثاً بلا تصنيف` : 'كل ما ورد مسجَّل' },
        { label: 'مسجَّلة وغير محسومة', value: count(undecided.length),
          tone: undecided.length ? 'gold' : 'green',
          sub: undecided.length ? 'تصنيفها UNKNOWN' : 'كلّها محسومة' },
      ])

      + (missing.length
        ? insight('warn', `${count(missing.length)} باقة وردت في المصدر ولم تُسجَّل`,
            'أحداثها موجودة والنظام لا يعرف أتُحتسب أم لا. تسجيلها يحسم ذلك.')
        : '')

      + filterBar([
        { key: 'search', label: 'بحث بالرمز أو الاسم', type: 'search' },
        { key: 'category', label: 'التصنيف', type: 'select',
          options: CATEGORIES.map((c) => ({ value: c.value, label: c.label })) },
      ], '/master/packages', m.query)

      + packageForm()
      + (page.rows.length ? table(columns, page.rows) : empty('لا باقات مطابقة'))
      + pager(page.total, limit, offset, '/master/packages', m.query);

    wireFilters(view.el);
    wirePackageForm(view);
  },
};

function packageForm(): string {
  if (!can('package.manage')) {
    return `<div class="box" style="margin-top:12px">
      <p class="muted">العرض فقط — تحتاج صلاحية <code dir="ltr">package.manage</code>
      لتصنيف باقة.</p></div>`;
  }
  return `<div class="box" style="margin-top:12px" id="pkgBox">
    <h3 id="pkgFormTitle">تسجيل باقة أو تعديل تصنيفها</h3>
    <p class="muted" style="font-size:11px;margin:0 0 10px">
      ${CATEGORIES.map((c) => `<b>${esc(c.label)}</b>: ${esc(c.hint)}`).join(' · ')}</p>
    <div class="toolbar">
      <input class="search" id="pkCode" placeholder="الرمز كما يرد في المصدر"
        aria-label="رمز الباقة" dir="ltr">
      <input class="search" id="pkName" placeholder="الاسم (اختياري)" aria-label="اسم الباقة">
      <select class="select" id="pkCat" aria-label="التصنيف">
        <option value="">— التصنيف —</option>
        ${CATEGORIES.map((c) => `<option value="${esc(c.value)}">${esc(c.label)}</option>`).join('')}
      </select>
      <input class="search" id="pkNotes" placeholder="ملاحظة (اختياري)" aria-label="ملاحظة">
      <button class="btn gold" id="pkSave">احفظ</button>
    </div>
    <div id="pkResult"></div>
  </div>`;
}

function wirePackageForm(view: View): void {
  const box = view.el.querySelector<HTMLElement>('#pkgBox');
  if (!box) return;
  const code = box.querySelector<HTMLInputElement>('#pkCode');
  const name = box.querySelector<HTMLInputElement>('#pkName');
  const cat = box.querySelector<HTMLSelectElement>('#pkCat');
  const notes = box.querySelector<HTMLInputElement>('#pkNotes');
  const save = box.querySelector<HTMLButtonElement>('#pkSave');
  const title = box.querySelector<HTMLElement>('#pkgFormTitle');
  const out = box.querySelector<HTMLElement>('#pkResult');
  if (!code || !cat || !save || !out) return;

  for (const btn of view.el.querySelectorAll<HTMLButtonElement>('.pkg-edit')) {
    btn.addEventListener('click', () => {
      code.value = btn.dataset['code'] || '';
      if (name) name.value = btn.dataset['name'] || '';
      cat.value = btn.dataset['cat'] || '';
      if (notes) notes.value = btn.dataset['notes'] || '';
      if (title) title.textContent = `تصنيف ${btn.dataset['code'] || ''}`;
      out.innerHTML = '';
      cat.focus();
    });
  }

  save.addEventListener('click', async () => {
    if (!code.value.trim()) { out.innerHTML = insight('warn', 'الرمز إلزامي'); return; }
    if (!cat.value) {
      out.innerHTML = insight('warn', 'التصنيف إلزامي',
        'باقةٌ بلا تصنيف لا تُسعَّر أحداثها');
      return;
    }
    save.disabled = true;
    out.innerHTML = loading('جارٍ الحفظ…');
    try {
      const res = await rpc<Row>('upsert_package', {
        p_code: code.value.trim(),
        p_name: name?.value.trim() || code.value.trim(),
        p_semantic_category: cat.value,
        p_notes: notes?.value.trim() || null,
        p_request_id: crypto.randomUUID(),
      });
      if (!view.live) return;
      out.innerHTML = insight('good', 'حُفظ التصنيف',
        res['idempotent'] === true
          ? 'الطلب نفسه سبق تنفيذه — لم يُكتب مرّتين'
          : cat.value === 'PAID_PACKAGE'
            ? 'أحداث هذه الباقة صارت مؤهَّلة للعمولة.'
            : 'أحداث هذه الباقة لا تُحتسب في العمولة.');
      window.setTimeout(() => { if (view.live) window.location.reload(); }, 1200);
    } catch (error) {
      if (!view.live) return;
      out.innerHTML = insight('danger', 'لم يُحفظ التصنيف',
        error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
    } finally {
      save.disabled = false;
    }
  });
}

export const routes: Route[] = [agents, packages];
