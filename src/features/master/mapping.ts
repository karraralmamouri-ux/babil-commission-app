/**
 * ربط الوكلاء والكابينات.
 *
 * الزرّ الذي كان يحمل هذا الاسم كان ينادي `openSettingsSection` على قسم
 * إعدادات القراءة الخام — نموذج المدَيات الرقميّة: «الكابينات من 100 إلى 200
 * لفلان». وذاك القسم يعيش في المساحة السابقة المخفيّة، فلم يكن الزرّ يفعل
 * شيئاً أصلاً.
 *
 * ولم يُستعَد ذلك النموذج، وليس هذا سهواً: المدى الرقميّ يستنتج العائدية
 * والنطاق من رقم الكابينة، والرقم ليس حقيقةً مالية. كابينة 150 قد تكون
 * لوكيلٍ آخر أو في منطقةٍ أخرى، ولا يُعلَم ذلك إلا بقرارٍ صريح.
 *
 * فالربط هنا صريح: كابينةٌ واحدة، ووكيلٌ يُختار، ونطاقٌ يُقال. والكتابة
 * تمرّ بـ`register_fdt` التي ترفض نطاقاً غير مُصرَّح به وتُسجّل الأثر.
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

const ZONE_AR: Record<string, string> = { old: 'قديمة', new: 'جديدة' };

function insight(tone: 'good' | 'warn' | 'danger', title: string, detail = ''): string {
  return `<div class="insight ${tone}" style="margin-top:10px"><span class="insight-dot"></span><span>
    <b>${esc(title)}</b>${detail ? `<small>${esc(detail)}</small>` : ''}</span></div>`;
}

export const mapping: Route = {
  pattern: '/master/mapping',
  capability: 'commission.view',
  title: 'ربط الوكلاء والكابينات',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'البيانات الرئيسية' },
    { label: 'ربط الوكلاء والكابينات' },
  ],
  async render(view, m) {
    const limit = 50;
    const offset = Number(m.query.get('offset') || 0);
    view.innerHTML = loading('جارٍ قراءة الربط…');

    const args: Record<string, unknown> = { p_limit: limit, p_offset: offset };
    const search = m.query.get('search');
    const agent = m.query.get('agent');
    const zone = m.query.get('zone');
    const mapped = m.query.get('mapped');
    if (search) args['p_search'] = search;
    if (agent) args['p_agent'] = agent;
    if (zone) args['p_zone'] = zone;
    if (mapped === 'true') args['p_mapped'] = true;
    if (mapped === 'false') args['p_mapped'] = false;

    // قائمة الوكلاء لا تسقط صامتةً إلى [].
    //
    // كانت `.catch(() => [])` تُحوِّل أي عطل إلى قائمة فارغة، فتبدو الشاشة
    // سليمةً وفيها قائمةٌ خالية. ولم يكن ذلك سبب الفراغ — الدالّة كانت
    // ترشّح `status = 'ACTIVE'` بحروف كبيرة وقيد الجدول لا يقبل إلا
    // الصغيرة، فتنجح وتُعيد صفراً — لكن السقوط الصامت كان يمنع رؤية أي عطلٍ
    // حقيقي لو وقع. الأول عولج في الخادم، وهذا يُعالَج هنا.
    const [page, summary, agentsResult] = await Promise.all([
      pageRpc<Row>('page_fdt_mapping', args, view.signal),
      rpc<Row>('fdt_mapping_summary', {}),
      rpc<Row[]>('list_agents_for_pick', {})
        .then((r) => ({ ok: true as const, rows: Array.isArray(r) ? r : [] }))
        .catch((e: unknown) => ({ ok: false as const, error: e })),
    ]);
    if (!view.live) return;

    const list = agentsResult.ok ? agentsResult.rows : [];
    const agentsFailed = !agentsResult.ok;
    const unmapped = summary ? num(summary, 'unmapped') : 0;
    const unregistered = summary ? num(summary, 'unregistered') : 0;

    const columns: Array<Column<Row>> = [
      { key: 'code', label: 'الكابينة', cell: (r) =>
        `<b dir="ltr">${esc(str(r, 'code'))}</b>
         ${str(r, 'label') ? `<div class="muted" dir="ltr">${esc(str(r, 'label'))}</div>` : ''}` },
      { key: 'zone', label: 'النطاق', cell: (r) =>
        str(r, 'zone') ? chip(ZONE_AR[str(r, 'zone')] || str(r, 'zone'), 'info')
          : chip('غير محدّد', 'critical') },
      { key: 'agent', label: 'الوكيل', cell: (r) =>
        str(r, 'agent_id')
          ? `<a href="${esc(href(`/commissions/agents/${str(r,'agent_id')}`))}"><b>${esc(str(r, 'agent_name'))}</b></a>
             <div class="muted" dir="ltr">${esc(str(r, 'agent_code'))}</div>`
          : chip('غير مربوطة', 'critical') },
      // ثلاثة أرقام لا رقم واحد. كان العمود يقول «أحداث» ويعرض مجموع كل ما
      // وصل منذ أوّل ملفّ، فيُقرأ في شاشةٍ تشغيلية على أنه تفعيلات الشهر.
      { key: 'cycle', label: 'تفعيلات الدورة', cell: (r) =>
        `<b>${count(num(r, 'cycle_events'))}</b>`, numeric: true },
      { key: 'cycleSubs', label: 'مشتركون فريدون للدورة', cell: (r) =>
        count(num(r, 'cycle_subscribers')), numeric: true },
      { key: 'lifetime', label: 'إجمالي تاريخي', cell: (r) =>
        `<span class="muted">${count(num(r, 'lifetime_events'))}</span>`, numeric: true },
      { key: 'go', label: '', cell: (r) =>
        `<a class="smallbtn" href="${esc(href(`/master/fdts/${encodeURIComponent(str(r, 'code'))}/events`))}">الأحداث</a>
         <a class="smallbtn" href="${esc(href(`/master/fdts/${encodeURIComponent(str(r, 'code'))}`))}">الملفّ</a>`
        + (can('fdt.manage')
          ? ` <button class="smallbtn map-edit"
               data-code="${esc(str(r, 'code'))}"
               data-zone="${esc(str(r, 'zone'))}"
               data-agent="${esc(str(r, 'agent_id'))}"
               data-label="${esc(str(r, 'label'))}">اربط</button>`
          : '') },
    ];

    view.innerHTML = pageHeader('ربط الوكلاء والكابينات',
      'الكابينة تُربط بوكيلٍ ونطاقٍ صراحةً — لا يُستنتج أيّهما من رقمها')

      + kpiRow([
        { label: 'كابينات مسجَّلة', value: count(summary ? num(summary, 'registered') : 0),
          tone: 'primary', sub: `${count(summary ? num(summary, 'agents_with_cabinets') : 0)} وكيلاً` },
        { label: 'مربوطة بوكيل', value: count(summary ? num(summary, 'mapped') : 0), tone: 'green' },
        { label: 'مسجَّلة بلا وكيل', value: count(unmapped),
          tone: unmapped ? 'red' : 'green',
          sub: unmapped ? 'أحداثها لا تجد وكيلاً' : 'كلّها مربوطة' },
        { label: 'واردة ولم تُسجَّل', value: count(unregistered),
          tone: unregistered ? 'gold' : 'green',
          sub: unregistered ? 'تُصنَّف في طابور الكابينات' : 'لا شيء معلَّق' },
      ])

      // الرقمان مختلفان علاجاً، فيُفصلان قولاً.
      + (unregistered
        ? `<div class="insight warn" style="margin-top:12px"><span class="insight-dot"></span><span>
            <b>${count(unregistered)} كابينة وردت في المصدر ولا سجلّ لها</b>
            <small>هذه غير «المسجَّلة بلا وكيل»: تلك موجودة وتنتظر وكيلاً، وهذه لا وجود
              لها بعد. تُدخَل من
              <a href="${esc(href('/master/fdts/unknown'))}">طابور الكابينات</a>.</small>
          </span></div>`
        : '')

      + filterBar([
        { key: 'search', label: 'بحث بالكابينة', type: 'search' },
        { key: 'agent', label: 'بحث بالوكيل', type: 'search' },
        { key: 'zone', label: 'النطاق', type: 'select', options: [
          { value: 'old', label: 'قديمة' }, { value: 'new', label: 'جديدة' } ] },
        { key: 'mapped', label: 'الربط', type: 'select', options: [
          { value: 'false', label: 'غير المربوطة' }, { value: 'true', label: 'المربوطة' } ] },
      ], '/master/mapping', m.query)

      + mapPanel(list, agentsFailed)
      + (page.rows.length ? table(columns, page.rows) : empty('لا كابينات مطابقة'))
      + pager(page.total, limit, offset, '/master/mapping', m.query);

    wireFilters(view.el);
    wireMap(view);
  },
};

function mapPanel(agents: Row[], failed: boolean): string {
  // العطل يُقال عطلاً. قائمةٌ فارغة تُقرأ «لا وكلاء»، وذلك كذبٌ على المشغّل
  // حين يكون السبب أن الطلب لم ينجح أصلاً.
  if (failed) {
    return `<div class="box" style="margin-top:12px">
      <div class="insight danger"><span class="insight-dot"></span><span>
        <b>تعذّر تحميل قائمة الوكلاء</b>
        <small>لا يتمّ الربط بلا قائمة. أعِد المحاولة، وإن تكرّر فالخادم لا يستجيب.</small>
      </span></div>
      <div class="actions" style="margin-top:10px">
        <button class="btn" onclick="location.reload()">إعادة المحاولة</button>
      </div>
    </div>`;
  }

  if (!can('fdt.manage')) {
    return `<div class="box" style="margin-top:12px">
      <p class="muted">العرض فقط — الربط يحتاج صلاحية
      <code dir="ltr">fdt.manage</code>.</p></div>`;
  }
  return `<div class="box" style="margin-top:12px" id="mapBox">
    <h3>اربط كابينة</h3>
    <p class="muted" style="font-size:11px;margin:0 0 10px">
      النطاق إلزامي ويُقال صراحةً؛ الخادم يرفض استنتاجه. وتغيير ربطٍ قائم
      يحتاج تأكيداً، لأنه يُحوّل عمولة أحداث الكابينة إلى وكيلٍ آخر.</p>
    <div class="toolbar">
      <input class="search" id="mpCode" placeholder="رمز الكابينة" aria-label="رمز الكابينة" dir="ltr">
      <select class="select" id="mpZone" aria-label="النطاق">
        <option value="">— النطاق —</option>
        <option value="old">قديمة</option>
        <option value="new">جديدة</option>
      </select>
      <select class="select" id="mpAgent" aria-label="الوكيل">
        <option value="">— بلا وكيل —</option>
        ${agents.map((a) => `<option value="${esc(str(a, 'id'))}">${esc(str(a, 'official_name') || str(a, 'name'))}</option>`).join('')}
      </select>
      <input class="search" id="mpNotes" placeholder="سبب/ملاحظة" aria-label="ملاحظة">
      <label class="muted" style="display:inline-flex;align-items:center;gap:6px">
        <input type="checkbox" id="mpOverwrite"> أؤكّد تغيير ربطٍ قائم</label>
      <button class="btn gold" id="mpSave">اربط</button>
    </div>
    <div id="mpResult"></div>
  </div>`;
}

function wireMap(view: View): void {
  const box = view.el.querySelector<HTMLElement>('#mapBox');
  if (!box) return;
  const code = box.querySelector<HTMLInputElement>('#mpCode');
  const zone = box.querySelector<HTMLSelectElement>('#mpZone');
  const agent = box.querySelector<HTMLSelectElement>('#mpAgent');
  const notes = box.querySelector<HTMLInputElement>('#mpNotes');
  const overwrite = box.querySelector<HTMLInputElement>('#mpOverwrite');
  const save = box.querySelector<HTMLButtonElement>('#mpSave');
  const out = box.querySelector<HTMLElement>('#mpResult');
  if (!code || !zone || !agent || !save || !out) return;

  for (const btn of view.el.querySelectorAll<HTMLButtonElement>('.map-edit')) {
    btn.addEventListener('click', () => {
      code.value = btn.dataset['code'] || '';
      zone.value = btn.dataset['zone'] || '';
      agent.value = btn.dataset['agent'] || '';
      if (notes) notes.value = '';
      if (overwrite) overwrite.checked = false;
      out.innerHTML = '';
      zone.focus();
    });
  }

  save.addEventListener('click', async () => {
    if (!code.value.trim()) { out.innerHTML = insight('warn', 'رمز الكابينة إلزامي'); return; }
    if (!zone.value) {
      out.innerHTML = insight('warn', 'النطاق إلزامي',
        'لا يُستنتج من رقم الكابينة — يُقال صراحةً');
      return;
    }
    save.disabled = true;
    out.innerHTML = loading('جارٍ الربط…');
    try {
      await rpc<Row>('register_fdt', {
        p_code: code.value.trim(),
        p_zone: zone.value,
        p_agent_id: agent.value || null,
        p_notes: notes?.value.trim() || null,
        p_confirm_overwrite: overwrite?.checked === true,
        p_request_id: crypto.randomUUID(),
      });
      if (!view.live) return;
      out.innerHTML = insight('good', 'حُفظ الربط',
        agent.value ? 'أحداث الكابينة صارت تُنسب إلى هذا الوكيل.'
                    : 'الكابينة مسجَّلة بلا وكيل — أحداثها تبقى بلا نسبة.');
      window.setTimeout(() => { if (view.live) window.dispatchEvent(new CustomEvent('babil:refresh')); }, 1200);
    } catch (error) {
      if (!view.live) return;
      const message = error instanceof ApiError ? error.message : 'خطأ غير متوقّع';
      out.innerHTML = insight('danger', 'لم يُحفظ الربط', message)
        + (/overwrite|قائم|exists/i.test(message)
          ? insight('warn', 'الكابينة مربوطة بالفعل',
              'أشِّر «أؤكّد تغيير ربطٍ قائم» إن كان التحويل مقصوداً.')
          : '');
    } finally {
      save.disabled = false;
    }
  });
}

export const routes: Route[] = [mapping];
