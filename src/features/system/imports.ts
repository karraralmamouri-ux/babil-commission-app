/**
 * مركز الاستيراد.
 *
 * كان في الشاشات السابقة وحدها. يعرض عن كل دفعة ما يحتاجه من يراجعها: الملف
 * وبصمته والتغطية والاكتمال والصفوف المقبولة والمكرّرة والمرفوضة — والفارق
 * بين ما في الملف وما وصل إلى القاعدة.
 *
 * والاكتمال يبقى مُعلَناً لا مُستنتَجاً. مدى التواريخ لا يُثبت أن الملف كامل:
 * ملفٌّ يغطّي الشهر كلّه قد ينقصه نصف صفوفه. فتبقى UNKNOWN حتى يُعلنها إنسان
 * بشاهد.
 *
 * ولا يُعرض ct_password ولا يُخزَّن ولا يُصدَّر — يُسقَط عند التحليل أصلاً.
 */

import type { Route, View } from '../../app/router';
import { href } from '../../app/router';
import { dateTime } from '../../domain/time';
import { rpc, pageRpc, can, ApiError } from '../../services/api';
import { count } from '../../domain/money';
import { bridgeSweepAll, bridgeReasons } from './bridge-sweep';
import {
  esc, loading, empty, pageHeader, table, pager, kpiRow, chip,
  filterBar, wireFilters, type Column,
} from '../../components/ui';

type Row = Record<string, unknown>;
const num = (r: Row, k: string) => Number(r[k] || 0);
const str = (r: Row, k: string) => String(r[k] ?? '');
const when = (v: unknown) => (v ? dateTime(v) : '—');

const KIND_AR: Record<string, string> = {
  ACTIVATION_EVENTS: 'أحداث تفعيل',
  USERS_SNAPSHOT: 'لقطة مستخدمين',
};

const COMPLETENESS: Record<string, { label: string; tone: 'success' | 'warning' | 'critical' }> = {
  COMPLETE: { label: 'مكتمل', tone: 'success' },
  PARTIAL:  { label: 'ناقص', tone: 'warning' },
  UNKNOWN:  { label: 'غير مُثبَت', tone: 'critical' },
};

export const imports: Route = {
  pattern: '/system/imports',
  capability: 'saas.review',
  title: 'الاستيراد',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'النظام' },
    { label: 'الاستيراد' },
  ],
  async render(view, m) {
    const limit = 50;
    const offset = Number(m.query.get('offset') || 0);
    view.innerHTML = loading('جارٍ تحميل دفعات الاستيراد…');

    const args: Record<string, unknown> = { p_limit: limit, p_offset: offset };
    for (const [q, p] of [['kind', 'p_kind'], ['completeness', 'p_completeness'],
      ['search', 'p_search']] as const) {
      const v = m.query.get(q);
      if (v) args[p] = v;
    }

    const page = await pageRpc<Row>('page_import_batches', args, view.signal);
    if (!view.live) return;

    const rows = page.rows;
    const unproven = rows.filter((r) => str(r, 'completeness_status') === 'UNKNOWN').length;
    const storedTotal = rows.reduce((a, r) => a + num(r, 'stored_events'), 0);
    const sourceTotal = rows.reduce((a, r) => a + num(r, 'source_row_count'), 0);

    const columns: Array<Column<Row>> = [
      { key: 'file', label: 'الملف', cell: (r) =>
        `<a href="${esc(href(`/system/imports/${encodeURIComponent(str(r, 'id'))}`))}">
           <b>${esc(str(r, 'source_filename'))}</b></a>
         <div class="muted" dir="ltr" style="font-size:10px">${esc(str(r, 'source_checksum').slice(0, 16))}…</div>` },
      { key: 'kind', label: 'النوع', cell: (r) =>
        chip(KIND_AR[str(r, 'source_kind')] || str(r, 'source_kind'), 'info') },
      { key: 'comp', label: 'الاكتمال', cell: (r) => {
        const c = COMPLETENESS[str(r, 'completeness_status')];
        return chip(c ? c.label : str(r, 'completeness_status'), c?.tone || 'neutral');
      } },
      { key: 'cover', label: 'التغطية المرصودة', cell: (r) =>
        `<span dir="ltr" style="font-size:11px">${esc(String(r['observed_min_created_at'] ?? '').slice(0, 10) || '—')}
          → ${esc(String(r['observed_max_created_at'] ?? '').slice(0, 10) || '—')}</span>` },
      { key: 'src', label: 'صفوف الملف', cell: (r) => count(num(r, 'source_row_count')), numeric: true },
      { key: 'acc', label: 'المقبولة', cell: (r) => count(num(r, 'imported_row_count')), numeric: true },
      { key: 'dup', label: 'المكرّرة', cell: (r) =>
        num(r, 'duplicate_count') ? chip(count(num(r, 'duplicate_count')), 'warning') : '—', numeric: true },
      { key: 'err', label: 'المرفوضة', cell: (r) =>
        num(r, 'error_count') ? chip(count(num(r, 'error_count')), 'critical') : '—', numeric: true },
      { key: 'stored', label: 'في القاعدة', cell: (r) => count(num(r, 'stored_events')), numeric: true },
      { key: 'who', label: 'المستورِد', cell: (r) => esc(str(r, 'imported_by_email') || '—') },
      { key: 'at', label: 'الوقت', cell: (r) => `<span dir="ltr">${esc(when(r['imported_at']))}</span>` },
    ];

    view.innerHTML = pageHeader('مركز الاستيراد',
      'ما في الملف، وما قُبل، وما وصل إلى القاعدة — ثلاثة أرقام لا واحد')

      + kpiRow([
        { label: 'دفعات الاستيراد', value: count(page.total), tone: 'primary' },
        { label: 'صفوف المصدر', value: count(sourceTotal), tone: 'blue',
          sub: `${count(storedTotal)} في القاعدة` },
        { label: 'اكتمال غير مُثبَت', value: count(unproven), tone: unproven ? 'red' : 'green',
          sub: unproven ? 'لا تُمنح الجِدّة من مصدرٍ كهذا' : 'كلها مُثبتة' },
        { label: 'المرفوضة', value: count(rows.reduce((a, r) => a + num(r, 'error_count'), 0)),
          tone: 'red' },
      ])

      + `<div class="insight warn" style="margin-top:12px"><span class="insight-dot"></span><span>
          <b>الاكتمال يُعلَن ولا يُستنتَج</b>
          <small>مدى التواريخ لا يُثبت أن الملف كامل — ملفٌّ يغطّي الشهر كلّه قد
          ينقصه نصف صفوفه. تبقى الحالة «غير مُثبَت» حتى يُعلنها إنسان بشاهد،
          ولا تُمنح جِدّةُ مشترك من مصدرٍ غير مُثبَت.</small></span></div>`

      + (can('saas.import')
        ? `<div class="actions" style="margin:12px 0">
            <a class="btn gold" href="${esc(href('/system/imports/new'))}">استورد ملفاً</a>
          </div>`
        : '')
      + filterBar([
        { key: 'search', label: 'بحث بالاسم أو البصمة', type: 'search' },
        { key: 'kind', label: 'النوع', type: 'select',
          options: Object.entries(KIND_AR).map(([k, v]) => ({ value: k, label: v })) },
        { key: 'completeness', label: 'الاكتمال', type: 'select',
          options: Object.entries(COMPLETENESS).map(([k, v]) => ({ value: k, label: v.label })) },
      ], '/system/imports', m.query)

      + (page.rows.length ? table(columns, page.rows) : empty('لا دفعات استيراد'))
      + pager(page.total, limit, offset, '/system/imports', m.query);

    wireFilters(view.el);
  },
};

export const importDetail: Route = {
  pattern: '/system/imports/:id',
  capability: 'saas.review',
  title: 'دفعة استيراد',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'الاستيراد', href: href('/system/imports') },
    { label: 'التفصيل' },
  ],
  async render(view, m) {
    const id = m.params['id'] as string;
    view.innerHTML = loading('جارٍ تحميل الدفعة…');

    const doc = await rpc<Row>('import_batch_detail', { p_batch_id: id });
    if (!view.live) return;
    const b = (doc?.['batch'] || null) as Row | null;
    if (!b) { view.innerHTML = empty('الدفعة غير موجودة', id); return; }

    const stored = (doc?.['stored'] || {}) as Row;
    const parents = (doc?.['parents'] || []) as Row[];
    const unknownFdts = (doc?.['unknown_fdts'] || []) as Row[];
    const unknownPkgs = (doc?.['unknown_packages'] || []) as Row[];
    const decls = (doc?.['declarations'] || []) as Row[];
    const identityMatch = (doc?.['identity_match'] || {}) as Row;
    const comp = COMPLETENESS[str(b, 'completeness_status')];

    // الفارق بين الملف والقاعدة: يُحسب ويُعرض بدل أن يُترك للحساب الذهني.
    const gap = num(b, 'source_rows') - num(b, 'imported_rows');

    view.innerHTML = pageHeader(str(b, 'filename'),
      `${KIND_AR[str(b, 'source_kind')] || str(b, 'source_kind')} · ${esc(when(b['imported_at']))}`,
      chip(comp ? comp.label : str(b, 'completeness_status'), comp?.tone || 'neutral'))

      + kpiRow([
        { label: 'صفوف الملف', value: count(num(b, 'source_rows')), tone: 'blue' },
        { label: 'المقبولة', value: count(num(b, 'imported_rows')), tone: 'green',
          sub: gap ? `فارق ${count(gap)} صفّاً` : 'لا فارق' },
        { label: 'في القاعدة', value: count(num(stored, 'events')), tone: 'primary',
          sub: `${count(num(stored, 'subscribers'))} مشتركاً` },
        { label: 'مرفوضة / مكرّرة', value:
          `${count(num(b, 'errors'))} / ${count(num(b, 'duplicates'))}`, tone: 'red' },
      ])

      + `<div class="grid2" style="margin-top:12px">
        <div class="box">
          <h3>الملف</h3>
          <div class="minirow"><span class="muted">البصمة</span>
            <b dir="ltr" style="font-size:10px">${esc(str(b, 'checksum'))}</b></div>
          <div class="minirow"><span class="muted">إصدار المحلِّل</span>
            <b dir="ltr">${esc(str(b, 'parser_version') || '—')}</b></div>
          <div class="minirow"><span class="muted">التغطية المُعلَنة</span>
            <b dir="ltr">${esc(String(b['declared_coverage_start'] ?? '—').slice(0, 10))}
              → ${esc(String(b['declared_coverage_end'] ?? '—').slice(0, 10))}</b></div>
          <div class="minirow"><span class="muted">التغطية المرصودة</span>
            <b dir="ltr">${esc(String(b['observed_min'] ?? '—').slice(0, 10))}
              → ${esc(String(b['observed_max'] ?? '—').slice(0, 10))}</b></div>
          <div class="minirow"><span class="muted">المستورِد</span>
            <b>${esc(str(b, 'imported_by') || '—')}</b></div>
        </div>
        <div class="box">
          <h3>إعلانات الاكتمال</h3>
          ${decls.length
            ? decls.map((d) => `<div class="minirow">
                <span><b>${esc(str(d, 'previous_status') || '—')} ← ${esc(str(d, 'declared_status'))}</b>
                  <div class="muted">${esc(str(d, 'evidence') || 'بلا شاهد مكتوب')}</div></span>
                <span class="muted" dir="ltr">${esc(when(d['declared_at']))}</span></div>`).join('')
            : `<p class="muted">لم يُعلَن اكتمال هذه الدفعة. تبقى
               «غير مُثبَتة»، ولا تُمنح منها جِدّة مشترك.</p>`}
        </div>
      </div>`

      // ما يحتاج قراراً بعد هذا الاستيراد.
      + `<div class="grid2" style="margin-top:12px">
        <div class="box">
          <h3>كابينات مجهولة في هذه الدفعة</h3>
          ${unknownFdts.length
            ? unknownFdts.map((f) => `<a class="minirow" style="text-decoration:none;color:inherit"
                href="${esc(href(`/master/fdts/${encodeURIComponent(str(f, 'fdt_code'))}`))}">
                <span dir="ltr"><b>${esc(str(f, 'fdt_code'))}</b></span>
                <span>${count(num(f, 'subscribers'))} مشتركاً ·
                  ${count(num(f, 'events'))} حدثاً</span></a>`).join('')
            : '<p class="muted">لا كابينات مجهولة</p>'}
        </div>
        <div class="box">
          <h3>باقات غير معروفة</h3>
          <p class="muted" style="font-size:11px;margin:0 0 8px">
            الباقة غير المعرَّفة تمنع تسعير حدثها.</p>
          ${unknownPkgs.length
            ? unknownPkgs.map((p) => `<div class="minirow">
                <span dir="ltr">${esc(str(p, 'profile_name'))}</span>
                <b>${count(num(p, 'events'))} حدثاً</b></div>`).join('')
            : '<p class="muted">كل الباقات معرَّفة</p>'}
        </div>
      </div>`

      // مطابقة الهوية: حالة اليوم في subscriber_identities، لا تصنيف جِدّة.
      + (str(b, 'source_kind') === 'ACTIVATION_EVENTS' && num(identityMatch, 'total_subscribers')
        ? `<div class="box" style="margin-top:12px">
          <h3>مطابقة الهوية لمشتركي هذه الدفعة</h3>
          <p class="muted" style="font-size:11px;margin:0 0 8px">
            حالة المطابقة كما هي في سجلّ الهوية اليوم — لا حكم جِدّة هنا.</p>
          ${kpiRow([
            { label: 'مطابَق', value: count(num(identityMatch, 'matched')), tone: 'green' },
            { label: 'غير مطابَق', value: count(num(identityMatch, 'unmatched')), tone: 'blue',
              sub: 'لا يُصنَّف جديداً تلقائياً' },
            { label: 'تعارض', value: count(num(identityMatch, 'conflict')), tone: 'red',
              sub: num(identityMatch, 'conflict') ? 'يحتاج حسماً' : '—' },
            { label: 'يحتاج مراجعة', value: count(num(identityMatch, 'needs_review')), tone: 'gold' },
          ])}
          ${num(identityMatch, 'conflict') ? `<div class="actions" style="margin-top:10px">
            <a class="btn" href="${esc(href('/system/identities?status=CONFLICT'))}">
              افتح شاشة تعارض الهوية</a></div>` : ''}
        </div>`
        : '')

      + declarePanel(id, str(b, 'completeness_status'))

      + (str(b, 'source_kind') === 'ACTIVATION_EVENTS' ? bridgePanel(id) : '')

      + `<div class="box" style="margin-top:12px">
          <h3>الآباء في هذه الدفعة</h3>
          ${parents.length ? table<Row>([
            { key: 'p', label: 'الأب (كما ورد)', cell: (r) =>
              `<a class="parent-name" dir="ltr"
                 href="${esc(href(`/master/parents/${encodeURIComponent(str(r, 'parent_name'))}`))}">${esc(str(r, 'parent_name'))}</a>` },
            { key: 'own', label: 'العائدية', cell: (r) => {
              const o = str(r, 'ownership');
              return chip(o === 'RESELLER' ? 'وكيل' : o === 'DIRECT_COMPANY' ? 'الشركة' : 'تحتاج مراجعة',
                o === 'NEEDS_REVIEW' ? 'warning' : o === 'RESELLER' ? 'info' : 'brand');
            } },
            { key: 'subs', label: 'المشتركون', cell: (r) => count(num(r, 'subscribers')), numeric: true },
            { key: 'ev', label: 'الأحداث', cell: (r) => count(num(r, 'events')), numeric: true },
          ], parents) : '<p class="muted">لا آباء</p>'}
          ], parents) : '<p class="muted">لا آباء</p>'}
        </div>`;

    wireDeclare(view);
    wireBridge(view);
  },
};

/**
 * إعلان الاكتمال.
 *
 * الحكم الوحيد الذي يفتح باب «مشترك جديد»: الجِدّة لا تُمنح من مصدرٍ غير
 * مُثبَت الاكتمال. فيُشترط شاهدٌ مكتوب — لا مجرّد اختيار من قائمة.
 */
function declarePanel(batchId: string, current: string): string {
  if (!can('saas.import')) {
    return `<div class="box" style="margin-top:12px">
      <p class="muted">تحتاج صلاحية <code>saas.import</code> لإعلان اكتمال دفعة.</p></div>`;
  }
  return `<div class="box" style="margin-top:12px" id="declBox" data-batch="${esc(batchId)}">
    <h3>إعلان الاكتمال</h3>
    <p class="muted" style="font-size:11px;margin:0 0 10px">
      الحالة الآن: <b>${esc(COMPLETENESS[current]?.label || current)}</b>.
      إعلانُ الاكتمال يفتح إمكان منح الجِدّة من هذه الدفعة، فيُشترط له شاهد.</p>
    <div class="toolbar">
      <select class="select" id="dcStatus" aria-label="حالة الاكتمال">
        <option value="">— الحالة —</option>
        <option value="COMPLETE">مكتمل — كل صفوف الفترة موجودة</option>
        <option value="PARTIAL">ناقص — تغطية جزئية معروفة</option>
        <option value="UNKNOWN">غير مُثبَت</option>
      </select>
      <input class="search" type="date" id="dcFrom" aria-label="بداية التغطية">
      <input class="search" type="date" id="dcTo" aria-label="نهاية التغطية">
      <input class="search" id="dcEvidence" placeholder="الشاهد (إلزامي)" aria-label="الشاهد">
      <button class="btn gold" id="dcApply">أعلِن</button>
    </div>
    <div id="dcResult"></div>
  </div>`;
}

/**
 * الاستيراد يضع الأحداث في الجدول ولا يُنشئ حالة تنصيب. الجسر هو ما يُحوّل
 * التفعيل الخام إلى تسجيلٍ ثم حالةٍ رسمية — بالبوابة القائمة نفسها، فلا
 * يُسجَّل من لم تُجزه.
 *
 * وهو يُعاد هنا لا في الرفع وحده: الهوية والتصنيف واكتمال المصدر تُحسم بعد
 * الرفع عادةً، فأكثر الصفوف تُمنع في التشغيلة الأولى بحق ثم تُسجَّل لاحقاً.
 */
function bridgePanel(batchId: string): string {
  return `<div class="box" style="margin-top:12px" id="brBox" data-batch="${esc(batchId)}">
    <h3>تسجيل المؤهَّلين من هذه الدفعة</h3>
    <p class="muted" style="font-size:11px;margin:0 0 8px">
      يمرّ كل مشترك ببوابة التسجيل كما هي. مَن لم تُجزه يعود بسببه ولا يُسجَّل.
      أعِد التشغيل بعد حسم الهوية والتصنيف وإعلان الاكتمال.</p>
    <div class="actions"><button class="btn" id="brRun">شغّل الجسر</button></div>
    <div id="brResult"></div>
  </div>`;
}

function wireBridge(view: View): void {
  const box = view.el.querySelector<HTMLElement>('#brBox');
  if (!box) return;
  const batchId = box.dataset['batch'] || '';
  const run = box.querySelector<HTMLButtonElement>('#brRun');
  const out = box.querySelector<HTMLElement>('#brResult');
  if (!run || !out) return;

  run.addEventListener('click', async () => {
    run.disabled = true;
    out.innerHTML = loading('جارٍ تقييم المرشّحين على الخادم…');
    try {
      // مسحةٌ واحدةٌ لا تكفي: نافذة النداء محدودة، والممنوعون يبقون مرشّحين
      // فيملؤونها في كل مرّة. المرور الكامل بالمؤشّر في bridge-sweep.
      const swept = await bridgeSweepAll(batchId, (t) => {
        if (!view.live) return;
        out.innerHTML = loading(`جارٍ تقييم المرشّحين… (سُجّل ${count(t.enrolled)}`
          + ` · بقي ${count(t.remaining)})`);
      });
      if (!view.live) return;
      const why = bridgeReasons(swept);
      out.innerHTML = insight(swept.enrolled ? 'good' : 'warn',
        `سُجّل ${count(swept.enrolled)} من ${count(swept.considered)} مرشّحاً`,
        (why ? `الممنوعون — ${why}` : 'لا ممنوعين')
        + (swept.complete ? '' : ` · بقي ${count(swept.remaining)} مرشّحاً بلا نظر`));
    } catch (error) {
      if (!view.live) return;
      out.innerHTML = insight('danger', 'لم يُشغَّل الجسر',
        error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
    } finally {
      run.disabled = false;
    }
  });
}

function wireDeclare(view: View): void {
  const box = view.el.querySelector<HTMLElement>('#declBox');
  if (!box) return;
  const batchId = box.dataset['batch'] || '';
  const status = box.querySelector<HTMLSelectElement>('#dcStatus');
  const from = box.querySelector<HTMLInputElement>('#dcFrom');
  const to = box.querySelector<HTMLInputElement>('#dcTo');
  const evidence = box.querySelector<HTMLInputElement>('#dcEvidence');
  const apply = box.querySelector<HTMLButtonElement>('#dcApply');
  const out = box.querySelector<HTMLElement>('#dcResult');
  if (!status || !apply || !out) return;

  apply.addEventListener('click', async () => {
    if (!status.value) {
      out.innerHTML = insight('warn', 'اختر الحالة أولاً');
      return;
    }
    const why = evidence?.value.trim() || '';
    if (!why) {
      out.innerHTML = insight('warn', 'الشاهد إلزامي',
        'الاكتمال يُعلَن بدليل لا باختيار');
      return;
    }
    apply.disabled = true;
    out.innerHTML = loading('جارٍ حفظ الإعلان…');
    try {
      await rpc<Row>('declare_import_completeness', {
        p_batch_id: batchId,
        p_status: status.value,
        p_coverage_start: from?.value || null,
        p_coverage_end: to?.value || null,
        p_evidence: why,
        p_request_id: crypto.randomUUID(),
      });
      if (!view.live) return;
      out.innerHTML = insight('good', 'حُفظ الإعلان',
        status.value === 'COMPLETE'
          ? 'صار بالإمكان منح الجِدّة من هذه الدفعة.'
          : 'تبقى الجِدّة ممنوعة من هذه الدفعة.');
      window.setTimeout(() => { if (view.live) window.location.reload(); }, 1300);
    } catch (error) {
      if (!view.live) return;
      out.innerHTML = insight('danger', 'لم يُحفظ الإعلان',
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

export const routes: Route[] = [imports, importDetail];
