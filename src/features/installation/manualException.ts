/**
 * إضافة مشترك استثنائي (Manual Exception Intake).
 *
 * ينفّذ العقد المصمَّم في docs/product/manual-exception-intake-design.md:
 * قدرة مخصّصة، سبب إلزامي، تأكيدٌ صريح، ودخولٌ أوّليٌّ NEEDS_REVIEW لا يصير
 * NEW ولا يُنشئ استحقاقاً أبداً من هذه الشاشة. الحسم شاشةٌ ثانية بقدرةٍ ثانية
 * — من يُنشئ الاستثناء لا يملك بالضرورة إغلاقه.
 */

import type { Route, View } from '../../app/router';
import { href } from '../../app/router';
import { rpc, pageRpc, can, ApiError } from '../../services/api';
import { count } from '../../domain/money';
import {
  esc, loading, empty, pageHeader, table, pager, chip,
  filterBar, wireFilters, type Column,
} from '../../components/ui';

type Row = Record<string, unknown>;
const s = (r: Row, k: string) => String(r[k] ?? '');

const EXCEPTION_TYPES: Array<{ value: string; label: string }> = [
  { value: 'NOT_VISIBLE_IN_SAAS', label: 'غير ظاهر في نظام SaaS' },
  { value: 'MISSING_HISTORICAL_DATA', label: 'بيانات تاريخية ناقصة' },
  { value: 'IMPORT_SOURCE_ERROR', label: 'خطأ في مصدر الاستيراد' },
  { value: 'APPROVED_ADMINISTRATIVE_EXCEPTION', label: 'استثناء إداري معتمد' },
  { value: 'OTHER', label: 'أخرى (اذكر السبب بدقّة)' },
];

const RESOLUTION_ACTIONS: Array<{ value: string; label: string }> = [
  { value: 'LINKED_TO_REAL_IDENTITY', label: 'رَبْط بهويّة حقيقية موجودة' },
  { value: 'CONFIRMED_ADMINISTRATIVE_EXCEPTION', label: 'تثبيت الاستثناء الإداري' },
  { value: 'REJECTED_DUPLICATE', label: 'رفض — تكرار' },
  { value: 'REJECTED_INVALID', label: 'رفض — غير صالح' },
];

function insight(tone: 'good' | 'warn' | 'danger', title: string, detail = ''): string {
  return `<div class="insight ${tone}" style="margin-top:10px"><span class="insight-dot"></span><span>
    <b>${esc(title)}</b>${detail ? `<small>${esc(detail)}</small>` : ''}</span></div>`;
}

/* ---------------------------------------------------------------------------
   الإنشاء — /installation/manual-exception/new
   ------------------------------------------------------------------------- */

export const manualExceptionIntake: Route = {
  pattern: '/installation/manual-exception/new',
  capability: 'installation.manual_exception_create',
  title: 'إضافة مشترك استثنائي',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'أجور التنصيب', href: href('/installation') },
    { label: 'مراجعة الاستثناء اليدوي', href: href('/installation/manual-exception') },
    { label: 'إضافة مشترك استثنائي' },
  ],
  render(view) {
    view.write(pageHeader('إضافة مشترك استثنائي',
      'مسارٌ نادرٌ ومتعمَّد — لا بديل عن الاستيراد الطبيعي. يدخل بحالة «بانتظار مراجعة» ولا يصير مؤهَّلاً أو يُنشئ استحقاقاً إلا بقرار مراجعٍ لاحق صريح.')
      + `<div class="box">
        <div class="toolbar" style="flex-direction:column;align-items:stretch;gap:10px">
          <select class="select" id="meType" aria-label="نوع الاستثناء">
            <option value="">اختر نوع الاستثناء (إلزامي)</option>
            ${EXCEPTION_TYPES.map((t) => `<option value="${esc(t.value)}">${esc(t.label)}</option>`).join('')}
          </select>
          <input class="search" id="meUsername" dir="ltr" placeholder="معرّف المشترك / اسم المستخدم (إلزامي)" aria-label="معرّف المشترك">
          <input class="search" id="meName" placeholder="اسم المشترك (إن عُرف)" aria-label="اسم المشترك">
          <input class="search" id="meReseller" placeholder="الوكيل / الأب (إن عُرف)" aria-label="الوكيل">
          <input class="search" id="meSource" placeholder="سياق المصدر / الدفعة (إن عُرف)" aria-label="سياق المصدر">
          <input class="search" id="meRef" placeholder="مرجع داعم (رابط، رقم مذكرة، إن وُجد)" aria-label="مرجع داعم">
          <textarea class="search" id="meReason" rows="3" placeholder="السبب (إلزامي — يُحفظ في التدقيق)" aria-label="السبب" style="resize:vertical;min-height:64px"></textarea>
        </div>
        <div class="actions" style="margin-top:12px">
          <button class="btn gold" id="meSubmitBtn">إرسال الاستثناء</button>
          <a class="btn" href="${esc(href('/installation/manual-exception'))}">إلغاء</a>
        </div>
        <div id="meResult"></div>
      </div>`);

    const type = view.el.querySelector<HTMLSelectElement>('#meType');
    const username = view.el.querySelector<HTMLInputElement>('#meUsername');
    const name = view.el.querySelector<HTMLInputElement>('#meName');
    const reseller = view.el.querySelector<HTMLInputElement>('#meReseller');
    const source = view.el.querySelector<HTMLInputElement>('#meSource');
    const ref = view.el.querySelector<HTMLInputElement>('#meRef');
    const reason = view.el.querySelector<HTMLTextAreaElement>('#meReason');
    const submit = view.el.querySelector<HTMLButtonElement>('#meSubmitBtn');
    const out = view.el.querySelector<HTMLElement>('#meResult');
    if (!type || !username || !reason || !submit || !out) return;

    submit.addEventListener('click', async () => {
      const exceptionType = type.value;
      const usernameKey = username.value.trim();
      const why = reason.value.trim();
      if (!exceptionType) { out.innerHTML = insight('warn', 'نوع الاستثناء إلزامي'); return; }
      if (!usernameKey) { out.innerHTML = insight('warn', 'معرّف المشترك إلزامي'); return; }
      if (!why) { out.innerHTML = insight('warn', 'السبب إلزامي', 'يُحفظ في التدقيق'); return; }

      const typeLabel = EXCEPTION_TYPES.find((t) => t.value === exceptionType)?.label || exceptionType;
      if (!window.confirm(`تأكيد إنشاء استثناء يدوي؟\n\nالمشترك: ${usernameKey}\nالنوع: ${typeLabel}\n\nيدخل بحالة «بانتظار مراجعة» فقط — لا يصير مؤهَّلاً تلقائياً.`)) return;

      submit.disabled = true;
      out.innerHTML = loading('جارٍ الإرسال…');
      try {
        const result = await rpc<Row>('create_manual_exception_intake', {
          p_exception_type: exceptionType,
          p_username_key: usernameKey,
          p_reason: why,
          p_subscriber_name: name?.value.trim() || null,
          p_reseller: reseller?.value.trim() || null,
          p_source_context: source?.value.trim() || null,
          p_supporting_reference: ref?.value.trim() || null,
          p_request_id: crypto.randomUUID(),
        });
        if (!view.live) return;
        out.innerHTML = result?.['replayed'] === true
          ? insight('good', 'مُرسَلٌ مسبقاً', 'لم يُنشأ صفٌّ ثانٍ')
          : insight('good', 'أُرسل الاستثناء', 'دخل طابور «مراجعة الاستثناء اليدوي» بانتظار قرار مراجع.');
        window.setTimeout(() => { if (view.live) window.location.hash = href('/installation/manual-exception').slice(1); }, 1100);
      } catch (error) {
        if (!view.live) return;
        out.innerHTML = insight('danger', 'لم يُرسَل الاستثناء',
          error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
      } finally {
        submit.disabled = false;
      }
    });
  },
};

/* ---------------------------------------------------------------------------
   المراجعة — /installation/manual-exception
   ------------------------------------------------------------------------- */

const RESOLVE_BOX_ID = 'meResolveBox';

function resolvePanel(intakeId: string): string {
  return `<div class="box" id="meResolveConfirm">
    <h3>حسم الاستثناء اليدوي</h3>
    <div class="toolbar" style="flex-direction:column;align-items:stretch;gap:8px">
      <select class="select" id="meResAction" aria-label="فعل الحسم">
        <option value="">اختر فعل الحسم (إلزامي)</option>
        ${RESOLUTION_ACTIONS.map((a) => `<option value="${esc(a.value)}">${esc(a.label)}</option>`).join('')}
      </select>
      <div id="meLinkHost"></div>
      <input class="search" id="meResReason" placeholder="سبب الحسم (إلزامي)" aria-label="سبب الحسم">
    </div>
    <div class="actions" style="margin-top:10px">
      <button class="btn gold" id="meResConfirmBtn">تأكيد الحسم</button>
      <button class="btn" id="meResCancelBtn">إلغاء</button>
    </div>
    <div id="meResResult"></div>
  </div>`;
}

function wireResolve(view: View, root: HTMLElement): void {
  const container = root.querySelector<HTMLElement>(`#${RESOLVE_BOX_ID}`);
  if (!container) return;

  root.addEventListener('click', (ev) => {
    const btn = (ev.target as HTMLElement)?.closest<HTMLButtonElement>('.me-resolve-action');
    if (!btn || !root.contains(btn)) return;
    const intakeId = btn.dataset['id'] || '';

    container.innerHTML = resolvePanel(intakeId);
    const actionSel = container.querySelector<HTMLSelectElement>('#meResAction');
    const linkHost = container.querySelector<HTMLElement>('#meLinkHost');
    const reason = container.querySelector<HTMLInputElement>('#meResReason');
    const confirm = container.querySelector<HTMLButtonElement>('#meResConfirmBtn');
    const cancel = container.querySelector<HTMLButtonElement>('#meResCancelBtn');
    const out = container.querySelector<HTMLElement>('#meResResult');
    if (!actionSel || !linkHost || !reason || !confirm || !cancel || !out) return;

    cancel.addEventListener('click', () => { container.innerHTML = ''; });

    // اكتشافٌ فقط — لا دمج تلقائي: مرشّحو الهوية الحقيقية يُعرَضون لاختيار
    // المراجع، ولا يُختار أحدهم إلا عند اختيار فعل «رَبْط بهويّة حقيقية».
    actionSel.addEventListener('change', async () => {
      if (actionSel.value !== 'LINKED_TO_REAL_IDENTITY') { linkHost.innerHTML = ''; return; }
      linkHost.innerHTML = loading('جارٍ البحث عن مرشّحي الهوية…');
      try {
        const doc = await rpc<Row>('manual_exception_merge_candidates', { p_intake_id: intakeId });
        const candidates = (doc?.['candidates'] || []) as Row[];
        if (!view.live) return;
        if (!candidates.length) {
          linkHost.innerHTML = insight('warn', 'لا مرشّح هوية مطابقٍ الآن', 'لا يمكن الربط قبل ظهور هوية SaaS حقيقية بنفس المعرّف');
          return;
        }
        linkHost.innerHTML = `<select class="select" id="meLinkSelect" aria-label="اختر الهوية المطابقة">
          <option value="">اختر الهوية المطابقة (إلزامي للربط)</option>
          ${candidates.map((c) => `<option value="${esc(s(c, 'subscriber_identity_id'))}">${esc(s(c, 'saas_user_id') || s(c, 'subscriber_identity_id'))} — ${esc(s(c, 'match_method'))}</option>`).join('')}
        </select>`;
      } catch (error) {
        if (!view.live) return;
        linkHost.innerHTML = insight('danger', 'تعذّر البحث عن المرشّحين', error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
      }
    });

    confirm.addEventListener('click', async () => {
      const action = actionSel.value;
      const why = reason.value.trim();
      if (!action) { out.innerHTML = insight('warn', 'فعل الحسم إلزامي'); return; }
      if (!why) { out.innerHTML = insight('warn', 'سبب الحسم إلزامي', 'يُحفظ في التدقيق'); return; }
      const linkSelect = container.querySelector<HTMLSelectElement>('#meLinkSelect');
      const linkedId = linkSelect?.value || null;
      if (action === 'LINKED_TO_REAL_IDENTITY' && !linkedId) {
        out.innerHTML = insight('warn', 'اختر الهوية المطلوب الربط بها'); return;
      }

      const label = RESOLUTION_ACTIONS.find((a) => a.value === action)?.label || action;
      if (!window.confirm(`تأكيد الحسم: ${label}؟`)) return;

      confirm.disabled = true;
      out.innerHTML = loading('جارٍ الحسم…');
      try {
        const result = await rpc<Row>('resolve_manual_exception_intake', {
          p_intake_id: intakeId, p_resolution_action: action, p_resolution_reason: why,
          p_linked_subscriber_identity_id: linkedId, p_request_id: crypto.randomUUID(),
        });
        if (!view.live) return;
        out.innerHTML = result?.['replayed'] === true
          ? insight('good', 'مُنفَّذ مسبقاً', 'لم يتغيّر شيء إضافي')
          : insight('good', 'تمّ الحسم', label);
        window.setTimeout(() => { if (view.live) window.dispatchEvent(new Event('babil:refresh')); }, 900);
      } catch (error) {
        if (!view.live) return;
        out.innerHTML = insight('danger', 'لم يُحسَم الاستثناء', error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
      } finally {
        confirm.disabled = false;
      }
    });
  });
}

export const manualExceptionReview: Route = {
  pattern: '/installation/manual-exception',
  capability: 'installation.view',
  title: 'مراجعة الاستثناء اليدوي',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'أجور التنصيب', href: href('/installation') },
    { label: 'مراجعة الاستثناء اليدوي' },
  ],
  async render(view, m) {
    const limit = 50;
    const offset = Number(m.query.get('offset') || 0);
    const search = m.query.get('search') || undefined;
    // الافتراض «بانتظار مراجعة» — لا «الكل» — فيبقى الرابط من مركز القرار
    // نازلاً مباشرةً على العمل المفتوح. الاستعلام المعروض يُطابق هذا صراحةً،
    // وإلا بدا شريط المرشِّحات مختاراً «كل الحالة» بينما المعروض غير ذلك.
    const query = new URLSearchParams(m.query);
    if (!query.get('status')) query.set('status', 'NEEDS_REVIEW');
    const status = query.get('status') as string;
    view.write(loading('جارٍ تحميل الاستثناءات اليدوية…'));

    const page = await pageRpc<Row>('page_manual_exceptions',
      { p_status: status, p_search: search, p_limit: limit, p_offset: offset }, view.signal);

    const canResolve = can('installation.manual_exception_resolve');
    const canCreate = can('installation.manual_exception_create');
    const isNeedsReview = status === 'NEEDS_REVIEW';

    const columns: Array<Column<Row>> = [
      { key: 'type', label: 'النوع', cell: (r) => esc(EXCEPTION_TYPES.find((t) => t.value === s(r, 'exception_type'))?.label || s(r, 'exception_type')) },
      { key: 'subscriber', label: 'المشترك', cell: (r) => `<b dir="ltr">${esc(s(r, 'username_key'))}</b>${s(r, 'subscriber_name') ? `<div class="muted" style="font-size:11px">${esc(s(r, 'subscriber_name'))}</div>` : ''}` },
      { key: 'reseller', label: 'الوكيل', cell: (r) => esc(s(r, 'reseller') || '—') },
      { key: 'reason', label: 'السبب', cell: (r) => esc(s(r, 'reason')) },
      { key: 'created', label: 'تاريخ الإنشاء', cell: (r) => esc(String(r['created_at'] ?? '').slice(0, 10)) },
      { key: 'status', label: 'الحالة', cell: (r) => s(r, 'status') === 'RESOLVED'
        ? chip(`محسوم — ${RESOLUTION_ACTIONS.find((a) => a.value === s(r, 'resolution_action'))?.label || s(r, 'resolution_action')}`, 'success')
        : chip('بانتظار مراجعة', 'warning') },
      { key: 'act', label: '', cell: (r) => (isNeedsReview && canResolve)
        ? `<button class="smallbtn me-resolve-action" data-id="${esc(s(r, 'id'))}">حسم</button>` : '' },
    ];

    view.write(pageHeader('مراجعة الاستثناء اليدوي', `${count(page.total)} — الحسم لا يُصيّر المشترك مؤهَّلاً ولا يُنشئ استحقاقاً تلقائياً`,
        canCreate ? `<a class="btn gold" href="${esc(href('/installation/manual-exception/new'))}">+ استثناء جديد</a>` : '')
      + filterBar([
        { key: 'search', label: 'بحث بالمعرّف أو الاسم', type: 'search' },
        { key: 'status', label: 'الحالة', type: 'select', options: [
          { value: 'NEEDS_REVIEW', label: 'بانتظار مراجعة' },
          { value: 'RESOLVED', label: 'محسوم' },
        ] },
      ], '/installation/manual-exception', query)
      + (page.rows.length ? table(columns, page.rows) : empty(isNeedsReview ? 'لا استثناءات بانتظار مراجعة' : 'لا استثناءات محسومة'))
      + pager(page.total, limit, offset, '/installation/manual-exception', query)
      + `<div id="${RESOLVE_BOX_ID}" style="margin-top:12px"></div>`);

    wireFilters(view.el);
    wireResolve(view, view.el);
  },
};

export const routes: Route[] = [manualExceptionIntake, manualExceptionReview];
