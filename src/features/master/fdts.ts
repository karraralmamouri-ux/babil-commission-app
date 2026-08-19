/**
 * الكابينات — الطابور والسجلّ والتصنيف.
 *
 * أكبر حاجبٍ في النظام: 119 كابينة مجهولة تحجب 22,724 صفَّ استثناء. وحدة
 * القرار الكابينة لا الصفّ، فحسمُ واحدةٍ يُطلق مئاتٍ دفعةً واحدة.
 *
 * والمنطقة تُذكر صراحةً ولا تُشتقّ من رقم الكابينة. الترقيم لا يحمل معنى
 * المنطقة، واشتقاقه منه يخترع تصنيفاً مالياً من محارف — والخادم يرفضه.
 */

import type { Route, View } from '../../app/router';
import { href } from '../../app/router';
import { rpc, pageRpc, can, ApiError } from '../../services/api';
import { money, count } from '../../domain/money';
import {
  esc, loading, empty, pageHeader, table, pager, kpiRow, chip,
  filterBar, wireFilters, type Column,
} from '../../components/ui';

type Row = Record<string, unknown>;
const num = (r: Row, k: string) => Number(r[k] || 0);
const str = (r: Row, k: string) => String(r[k] ?? '');
const when = (v: unknown) => (v ? String(v).replace('T', ' ').slice(0, 16) : '—');

export const ZONE_AR: Record<string, string> = { old: 'قديمة', new: 'جديدة' };

/* ---- طابور الكابينات المجهولة -------------------------------------------- */

export const unknownFdts: Route = {
  pattern: '/master/fdts/unknown',
  capability: 'commission.view',
  title: 'كابينات بلا تصنيف',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'الكابينات', href: href('/master/fdts') },
    { label: 'بلا تصنيف' },
  ],
  async render(view, m) {
    const limit = 50;
    const offset = Number(m.query.get('offset') || 0);
    view.innerHTML = loading('جارٍ حصر الكابينات المجهولة…');

    const args: Record<string, unknown> = { p_limit: limit, p_offset: offset };
    const search = m.query.get('search');
    if (search) args['p_search'] = search;

    const [page, summary] = await Promise.all([
      pageRpc<Row>('page_unknown_fdts', args, view.signal),
      rpc<Row>('unknown_fdt_summary', {}).catch(() => null),
    ]);
    if (!view.live) return;

    const columns: Array<Column<Row>> = [
      { key: 'code', label: 'الكابينة', cell: (r) =>
        `<a dir="ltr" href="${esc(href(`/master/fdts/${encodeURIComponent(str(r, 'fdt_code'))}`))}">
           <b>${esc(str(r, 'fdt_code'))}</b></a>` },
      { key: 'subs', label: 'المشتركون', cell: (r) => count(num(r, 'subscribers')), numeric: true },
      { key: 'ev', label: 'الأحداث', cell: (r) => count(num(r, 'events')), numeric: true },
      // الأب الأكثر وروداً: شاهد نسبة، لا حكم.
      { key: 'parent', label: 'أكثر أبٍ ورد معها', cell: (r) =>
        str(r, 'top_parent')
          ? `<span class="parent-name" dir="ltr">${esc(str(r, 'top_parent'))}</span>`
          : '<span class="muted">—</span>' },
      { key: 'amt', label: 'مبلغ مؤشِّر محجوب', cell: (r) =>
        `<span class="money">${money(num(r, 'indicative_amount'))}</span>`, numeric: true },
      { key: 'seen', label: 'آخر ظهور', cell: (r) =>
        `<span dir="ltr">${esc(String(r['last_seen'] ?? '').slice(0, 10) || '—')}</span>` },
      { key: 'go', label: '', cell: (r) =>
        `<a class="smallbtn" href="${esc(href(`/master/fdts/${encodeURIComponent(str(r, 'fdt_code'))}`))}">صنّف</a>` },
    ];

    view.innerHTML = pageHeader('كابينات بلا تصنيف',
      'وحدة القرار الكابينة لا الصفّ — وحسمُ واحدةٍ يُطلق مئات الأحداث')

      + kpiRow([
        { label: 'كابينات مجهولة', value: count(num(summary || {}, 'cabinets')), tone: 'red',
          sub: 'قرارٌ لكلٍّ منها' },
        { label: 'أحداث محجوبة', value: count(num(summary || {}, 'events')), tone: 'primary',
          sub: `${count(num(summary || {}, 'subscribers'))} مشتركاً` },
        { label: 'مبلغ مؤشِّر محجوب', value: money(num(summary || {}, 'indicative_amount')), tone: 'gold',
          sub: 'داخل نافذة الدورة الجارية' },
        { label: 'مُعرَّفة في السجلّ', value: count(num(summary || {}, 'registered')), tone: 'green',
          sub: `${count(num(summary || {}, 'registered_old'))} قديمة · ${count(num(summary || {}, 'registered_new'))} جديدة`,
          link: href('/master/fdts') },
      ])

      + `<div class="insight warn" style="margin-top:12px"><span class="insight-dot"></span><span>
          <b>المنطقة تُذكر ولا تُشتقّ</b>
          <small>رقم الكابينة لا يحمل معنى المنطقة. التصنيف قرارٌ صريح
          يُسجَّل باسم صاحبه، ويرفض الخادم أيّ تسجيل بلا منطقة معلنة.</small>
        </span></div>`

      + filterBar([{ key: 'search', label: 'بحث برمز الكابينة', type: 'search' }],
          '/master/fdts/unknown', m.query)
      + (page.outOfRange
        ? `<div class="insight warn"><span class="insight-dot"></span><span><b>الصفحة خارج المدى</b>
           <small>المجموعة فيها ${count(page.total)} كابينة.</small></span></div>`
        : '')
      + (page.rows.length ? table(columns, page.rows) : empty('لا كابينات مجهولة'))
      + pager(page.total, limit, offset, '/master/fdts/unknown', m.query);

    wireFilters(view.el);
  },
};

/* ---- سجلّ الكابينات ------------------------------------------------------ */

export const fdtRegistry: Route = {
  pattern: '/master/fdts',
  capability: 'commission.view',
  title: 'الكابينات',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'البيانات الرئيسية' },
    { label: 'الكابينات' },
  ],
  async render(view, m) {
    const limit = 50;
    const offset = Number(m.query.get('offset') || 0);
    view.innerHTML = loading('جارٍ تحميل السجلّ…');

    const args: Record<string, unknown> = { p_limit: limit, p_offset: offset };
    for (const [q, p] of [['zone', 'p_zone'], ['status', 'p_status'], ['search', 'p_search']] as const) {
      const v = m.query.get(q);
      if (v) args[p] = v;
    }

    const [page, summary] = await Promise.all([
      pageRpc<Row>('page_fdts', args, view.signal),
      rpc<Row>('unknown_fdt_summary', {}).catch(() => null),
    ]);
    if (!view.live) return;

    const unknown = num(summary || {}, 'cabinets');

    const columns: Array<Column<Row>> = [
      { key: 'code', label: 'الرمز', cell: (r) =>
        `<a dir="ltr" href="${esc(href(`/master/fdts/${encodeURIComponent(str(r, 'code'))}`))}">
           <b>${esc(str(r, 'code'))}</b></a>` },
      { key: 'label', label: 'التسمية', cell: (r) => esc(str(r, 'label') || '—') },
      { key: 'zone', label: 'المنطقة', cell: (r) => {
        const z = str(r, 'zone');
        return chip(ZONE_AR[z] || z || '—', z === 'new' ? 'success' : 'info');
      } },
      { key: 'agent', label: 'الوكيل', cell: (r) => esc(str(r, 'agent_name') || '—') },
      { key: 'subs', label: 'المشتركون', cell: (r) => count(num(r, 'subscribers')), numeric: true },
      { key: 'ev', label: 'الأحداث', cell: (r) => count(num(r, 'events')), numeric: true },
      { key: 'status', label: 'الحالة', cell: (r) =>
        str(r, 'status') === 'ACTIVE' ? chip('فعّالة', 'success') : chip(str(r, 'status') || '—', 'neutral') },
    ];

    view.innerHTML = pageHeader('الكابينات',
      'السجلّ المعتمد — والمنطقة فيه مُعلَنة لا مُستنتَجة')

      + (unknown
        ? `<div class="insight danger" style="margin-bottom:12px"><span class="insight-dot"></span><span>
            <b>${count(unknown)} كابينة بلا تصنيف</b>
            <small>تحجب ${count(num(summary || {}, 'events'))} حدثاً
            بمبلغ مؤشِّر ${money(num(summary || {}, 'indicative_amount'))}.</small></span>
            <a class="btn gold" href="${esc(href('/master/fdts/unknown'))}">افتح الطابور</a></div>`
        : '')

      + filterBar([
        { key: 'search', label: 'بحث بالرمز أو التسمية', type: 'search' },
        { key: 'zone', label: 'المنطقة', type: 'select', options: [
          { value: 'old', label: 'قديمة' }, { value: 'new', label: 'جديدة' } ] },
        { key: 'status', label: 'الحالة', type: 'select', options: [
          { value: 'ACTIVE', label: 'فعّالة' }, { value: 'INACTIVE', label: 'موقوفة' } ] },
      ], '/master/fdts', m.query)

      + (page.outOfRange
        ? `<div class="insight warn"><span class="insight-dot"></span><span><b>الصفحة خارج المدى</b>
           <small>السجلّ فيه ${count(page.total)} كابينة.</small></span></div>`
        : '')
      + (page.rows.length ? table(columns, page.rows) : empty('لا كابينات مطابقة'))
      + pager(page.total, limit, offset, '/master/fdts', m.query);

    wireFilters(view.el);
  },
};

/* ---- تفصيل كابينة وتصنيفها ----------------------------------------------- */

export const fdtDetail: Route = {
  pattern: '/master/fdts/:code',
  capability: 'commission.view',
  title: 'كابينة',
  breadcrumb: (m) => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'الكابينات', href: href('/master/fdts') },
    { label: decodeURIComponent(m.params['code'] || '') },
  ],
  async render(view, m) {
    const code = decodeURIComponent(m.params['code'] as string);
    view.innerHTML = loading('جارٍ جمع شواهد الكابينة…');

    const doc = await rpc<Row>('fdt_detail', { p_code: code });
    if (!view.live) return;
    if (!doc) { view.innerHTML = empty('لا شواهد', code); return; }

    const registered = doc['registered'] === true;
    const rec = (doc['record'] || null) as Row | null;
    const vol = (doc['volume'] || {}) as Row;
    const parents = (doc['parents'] || []) as Row[];
    const samples = (doc['samples'] || []) as Row[];
    const audit = (doc['audit'] || []) as Row[];
    const zone = rec ? str(rec, 'zone') : '';

    view.innerHTML = pageHeader(`كابينة ${code}`,
      registered ? 'مُعرَّفة في السجلّ' : 'غير معرَّفة — تحجب أحداثها',
      registered
        ? chip(ZONE_AR[zone] || zone || '—', zone === 'new' ? 'success' : 'info')
        : chip('بلا تصنيف', 'critical'))

      + kpiRow([
        { label: 'المشتركون', value: count(num(vol, 'subscribers')), tone: 'primary',
          sub: `${count(num(vol, 'events'))} حدثاً` },
        { label: 'أول ظهور', value: String(vol['first_seen'] ?? '').slice(0, 10) || '—', tone: 'blue' },
        { label: 'آخر ظهور', value: String(vol['last_seen'] ?? '').slice(0, 10) || '—', tone: 'blue' },
        { label: 'الحالة', value: registered ? (ZONE_AR[zone] || zone) : 'بلا تصنيف',
          tone: registered ? 'green' : 'red',
          sub: registered ? esc(str(rec || {}, 'agent_name') || 'بلا وكيل') : 'أحداثها محجوبة' },
      ])

      // الآباء شاهدُ نسبةٍ لا حكم: يساعدون على معرفة صاحبها، ولا يصنّفون المنطقة.
      + `<div class="grid2" style="margin-top:12px">
        <div class="box">
          <h3>الآباء الواردون معها</h3>
          <p class="muted" style="font-size:11px;margin:0 0 8px">
            شاهدٌ على من يشغّلها. لا يُشتقّ منه تصنيف المنطقة.</p>
          ${parents.length
            ? parents.map((p) => `<div class="minirow">
                <span class="parent-name" dir="ltr">${esc(str(p, 'parent_name'))}</span>
                <span><b>${count(num(p, 'subscribers'))}</b> مشتركاً</span></div>`).join('')
            : '<p class="muted">لا آباء</p>'}
        </div>
        <div class="box">
          <h3>البيانات المسجَّلة</h3>
          ${registered && rec ? `
            <div class="minirow"><span class="muted">التسمية</span><b>${esc(str(rec, 'label') || '—')}</b></div>
            <div class="minirow"><span class="muted">المنطقة</span>
              <b>${esc(ZONE_AR[zone] || zone || '—')}</b></div>
            <div class="minirow"><span class="muted">الوكيل</span>
              <b>${esc(str(rec, 'agent_name') || '—')}</b></div>
            <div class="minirow"><span class="muted">آخر تعديل</span>
              <b dir="ltr">${esc(when(rec['updated_at']))}</b></div>
            ${str(rec, 'notes') ? `<p class="muted">${esc(str(rec, 'notes'))}</p>` : ''}`
          : '<p class="muted">لا صفّ لها في السجلّ. أحداثها تُحجب حتى تُصنَّف.</p>'}
        </div>
      </div>`

      + classifyPanel(code, rec)

      + `<div class="box" style="margin-top:12px">
          <h3>عيّنة من المصدر</h3>
          ${samples.length ? table<Row>([
            { key: 'u', label: 'المستخدم', cell: (r) => `<span dir="ltr">${esc(str(r, 'username'))}</span>` },
            { key: 'p', label: 'الباقة', cell: (r) => `<span dir="ltr">${esc(str(r, 'profile_name') || '—')}</span>` },
            { key: 'par', label: 'الأب', cell: (r) => `<span class="parent-name" dir="ltr">${esc(str(r, 'raw_parent') || '—')}</span>` },
            { key: 'fat', label: 'FAT / PORT', cell: (r) =>
              `<span dir="ltr">${esc(str(r, 'fat_code') || '—')}/${esc(str(r, 'port_code') || '—')}</span>` },
            { key: 'd', label: 'التاريخ', cell: (r) => `<span dir="ltr">${esc(String(r['event_created_at'] ?? '').slice(0, 16))}</span>` },
            { key: 's', label: 'المصدر', cell: (r) => `<span class="muted" dir="ltr">${esc(str(r, 'source_sheet'))}:${esc(str(r, 'source_row'))}</span>` },
          ], samples) : '<p class="muted">لا عيّنات</p>'}
        </div>`

      + (audit.length
        ? `<div class="box" style="margin-top:12px"><h3>سجلّ القرارات</h3>
            ${audit.map((a) => `<div class="minirow">
              <span><b dir="ltr">${esc(when(a['created_at']))}</b> ${esc(str(a, 'action'))}</span>
              <span class="muted">${esc(str(a, 'actor_email') || '—')}</span></div>`).join('')}
          </div>`
        : '');

    wireClassify(view, code);
  },
};

function classifyPanel(code: string, rec: Row | null): string {
  if (!can('fdt.manage')) {
    return `<div class="box" style="margin-top:12px">
      <p class="muted">تحتاج صلاحية <code>fdt.manage</code> لتصنيف الكابينات.</p></div>`;
  }
  const zone = rec ? str(rec, 'zone') : '';
  return `<div class="box" style="margin-top:12px" id="fdtBox" data-code="${esc(code)}">
    <h3>${rec ? 'تعديل التصنيف' : 'تصنيف الكابينة'}</h3>
    <p class="muted" style="font-size:11px;margin:0 0 10px">
      المنطقة تُذكر صراحةً. لا يُشتقّ شيء من رقم الكابينة.</p>
    <div class="toolbar">
      <select class="select" id="fdZone" aria-label="المنطقة">
        <option value="">— المنطقة —</option>
        <option value="old"${zone === 'old' ? ' selected' : ''}>قديمة — بالوكيل</option>
        <option value="new"${zone === 'new' ? ' selected' : ''}>جديدة — بالكابينة</option>
      </select>
      <select class="select" id="fdAgent" aria-label="الوكيل">
        <option value="">— بلا وكيل —</option>
      </select>
      <input class="search" id="fdLabel" placeholder="تسمية (اختيارية)" aria-label="التسمية"
        value="${esc(rec ? str(rec, 'label') : '')}">
      <input class="search" id="fdNotes" placeholder="سبب القرار" aria-label="سبب القرار">
      <button class="btn gold" id="fdApply" data-current-agent="${esc(rec ? str(rec, 'agent_id') : '')}">
        ${rec ? 'احفظ التعديل' : 'صنّف'}</button>
    </div>
    <div id="fdResult"></div>
  </div>`;
}

function wireClassify(view: View, code: string): void {
  const box = view.el.querySelector<HTMLElement>('#fdtBox');
  if (!box) return;
  const zone = box.querySelector<HTMLSelectElement>('#fdZone');
  const agent = box.querySelector<HTMLSelectElement>('#fdAgent');
  const label = box.querySelector<HTMLInputElement>('#fdLabel');
  const notes = box.querySelector<HTMLInputElement>('#fdNotes');
  const apply = box.querySelector<HTMLButtonElement>('#fdApply');
  const out = box.querySelector<HTMLElement>('#fdResult');
  if (!zone || !agent || !apply || !out) return;

  void (async () => {
    try {
      const list = await rpc<Row[]>('list_agents_for_pick', {});
      if (!view.live) return;
      const current = apply.dataset['currentAgent'] || '';
      agent.innerHTML = '<option value="">— بلا وكيل —</option>'
        + (list || []).map((a) => `<option value="${esc(str(a, 'id'))}"${str(a, 'id') === current ? ' selected' : ''}>${esc(str(a, 'official_name'))}</option>`).join('');
    } catch { /* القائمة اختيارية: الكابينة تُصنَّف بلا وكيل أيضاً. */ }
  })();

  apply.addEventListener('click', async () => {
    if (!zone.value) {
      out.innerHTML = insight('warn', 'المنطقة إلزامية',
        'لا تُشتقّ من الرقم — تُذكر قديمة أو جديدة');
      return;
    }
    const why = notes?.value.trim() || '';
    if (!why) {
      out.innerHTML = insight('warn', 'سبب القرار إلزامي', 'يُحفظ مع التصنيف');
      return;
    }
    apply.disabled = true;
    out.innerHTML = loading('جارٍ حفظ التصنيف…');
    try {
      await rpc<Row>('register_fdt', {
        p_code: code,
        p_zone: zone.value,
        p_agent_id: agent.value || null,
        p_label: label?.value.trim() || null,
        p_notes: why,
        p_confirm_overwrite: true,
        p_request_id: crypto.randomUUID(),
      });
      if (!view.live) return;
      out.innerHTML = insight('good', `صُنِّفت ${ZONE_AR[zone.value] || zone.value}`,
        'تُعاد الأحداث المرتبطة بها إلى الحساب في إعادة التقييم.');
      window.setTimeout(() => { if (view.live) window.location.reload(); }, 1300);
    } catch (error) {
      if (!view.live) return;
      out.innerHTML = insight('danger', 'لم يُحفظ التصنيف',
        error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
    } finally {
      apply.disabled = false;
    }
  });
}

function insight(tone: 'good' | 'warn' | 'danger', title: string, detail = ''): string {
  return `<div class="insight ${tone}" style="margin-top:10px"><span class="insight-dot"></span><span>
    <b>${esc(title)}</b>${detail ? `<small>${esc(detail)}</small>` : ''}</span></div>`;
}

export const routes: Route[] = [unknownFdts, fdtRegistry, fdtDetail];
