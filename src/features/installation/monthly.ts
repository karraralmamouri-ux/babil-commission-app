/**
 * الشهر: مسارٌ واحدٌ من الملف إلى الاعتماد.
 *
 * قبل هذه الشاشة كان المشغّل يقطع ستّ شاشات ليُنهي شهراً واحداً: يرفع ملف
 * التفعيل، ثم يرفع ملف الفواتير ليُدقّقه بالجملة، ثم يبني الاستحقاق، ثم يفتح
 * المرشّحين، ثم يُنشئ دفعة، ثم يصرفها في الدفتر. وكان يظنّ — بحقٍّ، لأن
 * الشاشات قالت له ذلك — أنه يدفع. والدفع ليس هنا أصلاً.
 *
 * فصار المسار سبع خطواتٍ ظاهرةً مصدرها ملفٌ شهريٌّ واحد. والمسار القديم باقٍ
 * بحرفه لمن يحتاجه، لكنه لم يعد يُعرّف العمل الشهري.
 *
 * وحدّان لا تتجاوزهما هذه الشاشة:
 *   • لا تحسب مالاً. كلّ رقمٍ معروضٍ هنا خرج من الخادم — من
 *     installation_calculation_run_summary أو من عقود القراءة المرقَّمة —
 *     ولا جمعَ ولا طرحَ في المتصفّح.
 *   • «اعتماد نتيجة الشهر» ليس دفعاً، والنصّ يقولها في موضع الزرّ نفسه لا في
 *     صفحة توثيق. من يضغط يعرف ما يفعل.
 */

import type { Route, View } from '../../app/router';
import { href } from '../../app/router';
import { rpc, pageRpc, can, ApiError } from '../../services/api';
// مسار الاستيراد القائم نفسه — لا محلِّلَ ثانياً لملفٍّ واحد.
import { importMonthlyActivationFile } from '../system/import-run';
import { money, count } from '../../domain/money';
import {
  esc, loading, empty, pageHeader, table, pager, chip, kpiRow, type Column,
} from '../../components/ui';

type Row = Record<string, unknown>;
const num = (r: Row, k: string) => Number(r[k] || 0);
const str = (r: Row, k: string) => String(r[k] ?? '');

function insight(tone: 'good' | 'warn' | 'danger', title: string, detail = ''): string {
  return `<div class="insight ${tone}" style="margin-top:12px"><span class="insight-dot"></span><span>
    <b>${esc(title)}</b>${detail ? `<small>${esc(detail)}</small>` : ''}</span></div>`;
}

const RUN_STATE: Record<string, { label: string; tone: 'success' | 'warning' | 'critical' | 'info' }> = {
  CALCULATED: { label: 'محسوبة', tone: 'info' },
  NEEDS_REVIEW: { label: 'تحتاج حسم أسماء', tone: 'warning' },
  READY_TO_APPROVE: { label: 'جاهزة للاعتماد', tone: 'info' },
  APPROVED: { label: 'معتمَدة', tone: 'success' },
};

const OUTCOME: Record<string, { label: string; tone: 'success' | 'warning' | 'critical' | 'neutral' }> = {
  AWARDED: { label: 'ممنوح', tone: 'success' },
  NO_STAGE_REMAINING: { label: 'لا قسط متبقٍّ', tone: 'neutral' },
  BLOCKED: { label: 'محجوب', tone: 'critical' },
  NEEDS_REVIEW: { label: 'تحت المراجعة', tone: 'warning' },
};

/**
 * أسباب الخادم بالعربية — للعرض فقط.
 *
 * لا يُشتقّ من هذه الخريطة قرار: السبب المجهول يُعرض برمزه كما هو بدل أن
 * يُبتلع، لأن سبباً لا يُقرأ يساوي صفّاً بلا سبب.
 */
const REASON_AR: Record<string, string> = {
  SUBSCRIBER_ON_HOLD: 'تعليق فعّال',
  OWNERSHIP_NOT_RESELLER: 'العائدية ليست وكيلاً',
  STAGE_ALREADY_AWARDED: 'القسط مُنح واعتُمد سلفاً',
  INSTALMENTS_COMPLETE: 'انتهت الأقساط',
  GRACE_EXPIRED_REVIEW: 'انقضت مهلة التفعيل',
  CLASSIFICATION_NEEDS_REVIEW: 'التصنيف تحت المراجعة',
  NOT_CLASSIFIED: 'بلا تصنيف',
  SUBSCRIBER_IS_EXISTING: 'مشترك قائم لا جديد',
  EVENT_CANCELED: 'حدث ملغى',
  EVENT_ALREADY_USED: 'الحدث مستعمَل سلفاً',
  PACKAGE_NOT_QUALIFYING: 'باقة غير مؤهِّلة',
  DEBT_SERVICE_NEVER_QUALIFIES: 'خدمة دين لا تؤهِّل',
  UNKNOWN_PACKAGE: 'باقة غير معروفة',
  UNKNOWN_PARENT: 'اسم مصدر غير معروف',
  PARENT_NEEDS_REVIEW: 'اسم مصدر تحت المراجعة',
  EFFECTIVE_AGENT_UNRESOLVED: 'الوكيل الفعلي غير محسوم',
  IDENTITY_CONFLICT: 'تعارض هوية',
  IDENTITY_NOT_RESOLVED: 'هوية غير محسومة',
  DIRECT_COMPANY_NOT_ELIGIBLE: 'اشتراك مباشر لا يستحقّ',
  SOURCE_INCOMPLETE: 'المصدر غير مكتمل',
  BATCH_VOIDED: 'الدفعة ملغاة',
  STATE_UNRESOLVED: 'حالة المشترك غير محسومة',
  STATE_MISSING: 'لا حالة مفتوحة للمشترك',
  SCHEME_NOT_REPRESENTABLE_IN_STORAGE: 'مخطّط لا يقبله تخزين الحالة',
  SCHEME_STAGE_NOT_PRICEABLE: 'مرحلة بلا سعر في المخطّط',
  NO_EFFECTIVE_SCHEME_VERSION: 'لا إصدار مخطّط نافذ',
};

const reasonAr = (code: string) =>
  code.split(',').map((c) => REASON_AR[c.trim()] || c.trim()).join(' · ');

/** الخطوات السبع. حالة كلٍّ منها مقروءةٌ من نتيجة الشهر، لا معلَنةٌ يدوياً. */
function steps(run: Row | null, unmapped: number): string {
  const status = run ? str(run, 'status') : '';
  const has = Boolean(run);
  const approved = status === 'APPROVED';
  const gated = status === 'NEEDS_REVIEW';

  const rows: Array<[string, boolean, boolean, string]> = [
    ['رفع ملف الشهر', has, !has, 'ملفٌ واحد: أحداث التفعيل — وهو نفسه مصدر العمولات.'],
    ['مراجعة الملف', has, false, 'الاكتمال والتكرار والصفوف المرفوضة، في شاشة الاستيراد.'],
    ['حسم أسماء الوكلاء الجديدة', has && unmapped === 0, has && unmapped > 0,
      unmapped ? `${count(unmapped)} سطراً بلا مالكٍ محسوم` : 'لا اسم معلَّق'],
    ['حساب الأرباح وأجور التنصيب', has, false, 'العمولات ومحرّك التنصيب من المصدر ذاته.'],
    ['عرض نتيجة أجور التنصيب', has, has && !approved && !gated,
      'المراحل والمبالغ وتجميع الفروع والآباء.'],
    ['اعتماد نتيجة الشهر', approved, status === 'READY_TO_APPROVE', 'تثبيتُ مراحل — ليس دفعاً.'],
    ['التصدير والتقرير', approved, false, 'بعد الاعتماد.'],
  ];

  return `<div class="box" style="margin-top:14px">
    <h3>خطوات الشهر</h3>
    <p class="muted" style="font-size:11px;margin:0 0 10px">
      حالة كل خطوة مقروءةٌ من نتيجة الشهر نفسها، لا معلَنةٌ يدوياً.</p>
    ${rows.map(([label, done, active, detail], i) => `
      <div class="minirow">
        <span><b>${i + 1}. ${esc(label)}</b>
          ${chip(done ? 'مكتملة' : active ? 'جارية' : 'لم تبدأ',
                 done ? 'success' : active ? 'warning' : 'neutral')}</span>
        <span class="muted" style="font-size:11px">${esc(detail)}</span>
      </div>`).join('')}
  </div>`;
}

/* ---- الشاشة الأولى: أشهر الحساب، وبدءُ شهرٍ جديد ---------------------- */

export const monthly: Route = {
  pattern: '/installation/monthly',
  capability: 'installation.view',
  title: 'الشهر — أجور التنصيب',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'أجور التنصيب', href: href('/installation') },
    { label: 'الشهر' },
  ],
  async render(view, m) {
    const limit = 50;
    const offset = Number(m.query.get('offset') || 0);
    view.innerHTML = loading('جارٍ تحميل أشهر الحساب…');

    const [page, batches] = await Promise.all([
      pageRpc<Row>('page_installation_calculation_runs',
        { p_limit: limit, p_offset: offset }, view.signal),
      pageRpc<Row>('page_import_batches',
        { p_kind: 'ACTIVATION_EVENTS', p_limit: 50, p_offset: 0 }, view.signal),
    ]);
    if (!view.live) return;

    const latest = page.rows[0] || null;

    const columns: Array<Column<Row>> = [
      { key: 'period', label: 'الشهر', cell: (r) =>
        `<a href="${esc(href(`/installation/monthly/${str(r, 'id')}`))}"><b>${esc(str(r, 'period'))}</b></a>` },
      { key: 'status', label: 'الحالة', cell: (r) =>
        chip(RUN_STATE[str(r, 'status')]?.label || str(r, 'status'),
             RUN_STATE[str(r, 'status')]?.tone || 'neutral') },
      { key: 'source_filename', label: 'المصدر', cell: (r) =>
        `<span dir="ltr">${esc(str(r, 'source_filename') || '—')}</span>` },
      { key: 'awarded_count', label: 'أقساط', numeric: true,
        cell: (r) => count(num(r, 'awarded_count')) },
      { key: 'total_amount', label: 'النتيجة', numeric: true,
        cell: (r) => `<span class="money">${esc(money(num(r, 'total_amount')))}</span>` },
      { key: 'new_subscribers_count', label: 'جدد', numeric: true,
        cell: (r) => count(num(r, 'new_subscribers_count')) },
      { key: 'unresolved_print_count', label: 'أسطر معلَّقة', numeric: true, cell: (r) =>
        num(r, 'unresolved_print_count')
          ? chip(count(num(r, 'unresolved_print_count')), 'warning') : '—' },
    ];

    view.innerHTML = pageHeader('الشهر — أجور التنصيب',
      'من ملفٍ شهريٍّ واحد إلى نتيجةٍ معتمَدة. والحساب ليس دفعاً.')

      + (latest ? kpiRow([
        { label: 'آخر شهر', value: esc(str(latest, 'period')), tone: 'primary',
          sub: RUN_STATE[str(latest, 'status')]?.label || str(latest, 'status'),
          link: href(`/installation/monthly/${str(latest, 'id')}`) },
        { label: 'نتيجة ذلك الشهر', value: money(num(latest, 'total_amount')), tone: 'gold',
          sub: `${count(num(latest, 'awarded_count'))} قسطاً ممنوحاً` },
        { label: 'مشتركون جدد', value: count(num(latest, 'new_subscribers_count')),
          tone: 'blue', sub: 'دخلوا عند القسط الأول' },
        { label: 'محجوب أو تحت المراجعة', value: count(num(latest, 'blocked_count')),
          tone: num(latest, 'blocked_count') ? 'red' : 'green', sub: 'لكلِّ سطرٍ سببٌ مكتوب' },
      ]) : '')

      + steps(latest, latest ? num(latest, 'unresolved_print_count') : 0)

      + (can('installation.calculate') ? `<div class="box" style="margin-top:14px" id="mcNew">
        <h3>احسب شهراً</h3>
        <p class="muted" style="font-size:11px;margin:0 0 10px">
          ارفع ملفَ أحداث التفعيل هنا، أو اختر ملفاً رُفع سابقاً. والشهر يُقرأ
          من الملف نفسه ولا يُكتَب هنا — فلا يُحسب ملفُ شهرٍ على شهرٍ آخر.
          والحساب معاينةٌ لا تُغيّر حالةَ أيّ مشترك، ويمكن تكرارُه على المصدر
          نفسه بلا أثرٍ مضاعف.</p>
        ${can('saas.import') ? `<div class="toolbar">
          <input type="file" id="mcFile" accept=".xlsx,.xls"
            aria-label="ملف أحداث التفعيل">
          <button class="btn" id="mcUpload">ارفع الملف</button>
        </div>` : ''}
        <div class="toolbar">
          <select class="select" id="mcBatch" aria-label="ملف الشهر">
            <option value="">— اختر ملف الشهر —</option>
            ${batches.rows.map((b) => `<option value="${esc(str(b, 'id'))}">${
              esc(str(b, 'source_filename') || str(b, 'id'))}</option>`).join('')}
          </select>
          <button class="btn gold" id="mcRun" disabled>احسب نتيجة الشهر</button>
        </div>
        <div id="mcPeriod"></div>
        <div id="mcOut"></div>
      </div>` : '')

      + `<div class="box" style="margin-top:14px">
        <h3>أشهر الحساب</h3>
        ${page.rows.length
          ? table(columns, page.rows)
          : empty('لا شهر محسوب بعد', 'ابدأ برفع ملف الشهر ثم احسبه.')}
        ${pager(page.total, page.limit, page.offset, '/installation/monthly', m.query)}
      </div>`

      + insight('warn', 'الحساب ليس دفعاً',
        'اعتماد نتيجة الشهر يُثبّت مرحلة كل مشترك للشهر القادم ويحفظ الدليل كاملاً. '
        + 'ولا يُنشئ دفعةً ولا قيدَ دفترٍ ولا يَسِم قسطاً بأنه مدفوع — الدفع مسارٌ آخر.');

    wireCalculate(view);
  },
};

/** أعطابُ المصدر التي تمنع اشتقاق الشهر — بنصٍّ يقول للمشغّل ما يفعله،
 *  لا برمزٍ يحفظه. والرموز نفسها يرفعها الخادم في `saas_batch_period`. */
const PERIOD_FAULT: Record<string, { title: string; detail: string }> = {
  MIXED_MONTH_SOURCE: {
    title: 'هذا الملف يحمل أكثر من شهر',
    detail: 'ملفُ الشهر ملفُ شهرٍ واحد. افصل الأشهر في المصدر ثم أعد الرفع.' },
  PERIOD_NOT_PROVABLE: {
    title: 'شهر هذا الملف لا يُثبَت',
    detail: 'فيه أحداثٌ بلا تاريخ، وقد تكون من شهرٍ آخر. صحّح التواريخ في المصدر.' },
  NO_EVENTS: {
    title: 'لا أحداثَ تفعيلٍ في هذه الدفعة',
    detail: 'دفعةٌ فارغةٌ لا شهرَ لها، فلا شهرَ يُحسب منها.' },
  NOT_ACTIVATION_EVENTS: {
    title: 'هذه ليست دفعةَ أحداث تفعيل',
    detail: 'شاشة الشهر تقرأ ملفّ أحداث التفعيل وحده.' },
  BATCH_NOT_FOUND: {
    title: 'هذه الدفعة غير موجودة',
    detail: 'ربما أُلغيت. اختر ملفاً آخر أو ارفع الملف من جديد.' },
};

function wireCalculate(view: View): void {
  const box = view.el.querySelector<HTMLElement>('#mcNew');
  if (!box) return;
  const run = box.querySelector<HTMLButtonElement>('#mcRun');
  const batch = box.querySelector<HTMLSelectElement>('#mcBatch');
  const periodBox = box.querySelector<HTMLElement>('#mcPeriod');
  const out = box.querySelector<HTMLElement>('#mcOut');
  if (!run || !batch || !periodBox || !out) return;

  // الشهر المشتقّ من الملف المختار. لا يكتبه المشغّل ولا تحسبه هذه الشاشة:
  // يأتي من `saas_batch_period` كما اشتقّه الخادم من تواريخ الأحداث بتوقيت
  // العمل. ويُرسَل مع الطلب فيُعاد إثباته على الخادم قبل أن يُكتب أيّ سطر —
  // فلو تغيّرت الدفعة بين القراءة والضغط رُفض الطلب ولم يُحسب شهرٌ بالخطأ.
  let derived = '';

  const describe = async (): Promise<void> => {
    derived = '';
    run.disabled = true;
    if (!batch.value) { periodBox.innerHTML = ''; return; }
    periodBox.innerHTML = loading('جارٍ قراءة شهر الملف…');
    try {
      const facts = await rpc<Row>('saas_batch_period', { p_batch_id: batch.value });
      if (!view.live) return;
      const status = str(facts, 'status');
      if (status === 'OK') {
        derived = str(facts, 'period');
        periodBox.innerHTML = insight('good', `شهر هذا الملف: ${derived}`,
          `${count(num(facts, 'events'))} حدثاً، كلُّها في هذا الشهر بتوقيت العمل.`);
        run.disabled = false;
        return;
      }
      const fault = PERIOD_FAULT[status];
      const months = Array.isArray(facts['months']) ? (facts['months'] as string[]) : [];
      periodBox.innerHTML = insight('danger',
        fault?.title || 'هذا الملف لا يصلح مصدراً لشهر',
        (fault?.detail || status)
          + (status === 'MIXED_MONTH_SOURCE' && months.length
            ? ` الأشهر التي فيه: ${months.join('، ')}.` : ''));
    } catch (error) {
      if (!view.live) return;
      periodBox.innerHTML = insight('danger', 'لم يُقرأ شهر الملف',
        error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
    }
  };

  batch.addEventListener('change', () => { void describe(); });
  void describe();

  const file = box.querySelector<HTMLInputElement>('#mcFile');
  const upload = box.querySelector<HTMLButtonElement>('#mcUpload');
  if (file && upload) {
    upload.addEventListener('click', async () => {
      const f = file.files?.[0];
      if (!f) {
        out.innerHTML = insight('danger', 'اختر ملفاً أولاً');
        return;
      }
      upload.disabled = true;
      run.disabled = true;
      out.innerHTML = loading('جارٍ قراءة الملف…');
      try {
        // مسارُ الاستيراد القائم بحرفه: المحلِّل نفسه والنداء نفسه والجسر
        // نفسه المستعملة في مركز الاستيراد — مُصدَّرةً لا مكرَّرة.
        const result = await importMonthlyActivationFile(f, (message) => {
          if (view.live) out.innerHTML = loading(message);
        });
        if (!view.live) return;

        // والدفعة المستورَدة تصير مصدرَ الشهر في الحال — لا خطوةَ اختيارٍ
        // ثانية يسهو عنها المشغّل فيحسب شهره من ملفٍ قديم.
        const option = document.createElement('option');
        option.value = result.batchId;
        option.textContent = f.name;
        batch.insertBefore(option, batch.options[1] || null);
        batch.value = result.batchId;

        out.innerHTML = insight(result.complete ? 'good' : 'warn', 'رُفع ملف الشهر',
          `أحداث: مقبول ${count(result.accepted)} · مكرّر ${count(result.duplicates)}`
          + ` · مرفوض ${count(result.rejected)}`
          + ` — تسجيل: مؤهَّل ${count(result.enrolled)}`
          + ` · بانتظار المراجعة ${count(result.blocked)}`
          + (result.complete ? '' : ` · بقي ${count(result.remaining)} بلا نظر`)
          + (result.usersSkipped
            ? ` — وفيه ${count(result.usersSkipped)} صفَّ لقطة مستخدمين لم تُستورَد هنا؛`
              + ' ارفعها من مركز الاستيراد إن أردتها.'
            : ''));
        await describe();
      } catch (error) {
        if (!view.live) return;
        out.innerHTML = insight('danger', 'لم يُرفع الملف',
          error instanceof ApiError ? error.message
            : error instanceof Error ? error.message : 'خطأ غير متوقّع');
      } finally {
        upload.disabled = false;
      }
    });
  }

  run.addEventListener('click', async () => {
    if (!batch.value || !derived) {
      out.innerHTML = insight('danger', 'لا ملفَ شهرٍ صالحاً',
        'اختر ملفاً يُثبِت شهره، أو ارفع ملفَ الشهر أولاً.');
      return;
    }
    const p = derived;
    run.disabled = true;
    out.innerHTML = loading('جارٍ حساب نتيجة الشهر على الخادم…');
    try {
      const doc = await rpc<Row>('preview_installation_calculation', {
        p_period: p, p_batch_id: batch.value, p_request_id: crypto.randomUUID(),
      });
      if (!view.live) return;
      const id = str(doc, 'run_id');
      const gated = num(doc, 'unresolved_print_count');
      out.innerHTML = insight(gated ? 'warn' : 'good',
        `حُسب ${p}: ${money(num(doc, 'total_amount'))} في ${count(num(doc, 'awarded'))} قسطاً`,
        gated
          ? `${count(gated)} سطراً موقوفاً على حسم اسم المصدر — ولا يُعتمَد الشهر قبله.`
          : 'والمعاينة لم تُغيّر حالة أيّ مشترك.')
        + `<div class="zoneActions" style="justify-content:flex-start"><a class="btn gold"
             href="${esc(href(`/installation/monthly/${id}`))}">افتح النتيجة</a></div>`;
    } catch (error) {
      if (!view.live) return;
      out.innerHTML = insight('danger', 'لم يُحسَب الشهر',
        error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
    } finally {
      run.disabled = false;
    }
  });
}

/* ---- الشاشة الثانية: نتيجة شهرٍ واحد ----------------------------------- */

export const monthlyRun: Route = {
  pattern: '/installation/monthly/:id',
  capability: 'installation.view',
  title: 'نتيجة الشهر',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'أجور التنصيب', href: href('/installation') },
    { label: 'الشهر', href: href('/installation/monthly') },
    { label: 'النتيجة' },
  ],
  async render(view, m) {
    const id = m.params['id'] || '';
    const outcome = m.query.get('outcome') || '';
    const limit = 50;
    const offset = Number(m.query.get('offset') || 0);
    view.innerHTML = loading('جارٍ تحميل نتيجة الشهر…');

    const [sum, unmapped, lines] = await Promise.all([
      rpc<Row>('installation_calculation_run_summary', { p_run_id: id }),
      rpc<Row[]>('installation_unmapped_print_names', { p_run_id: id }),
      pageRpc<Row>('page_installation_calculation_lines',
        { p_run_id: id, p_outcome: outcome || null, p_limit: limit, p_offset: offset },
        view.signal),
    ]);
    if (!view.live) return;

    const status = str(sum, 'status');
    const stages = (sum['stages'] || {}) as Record<string, number>;
    const reasons = (sum['reasons'] || {}) as Record<string, number>;
    const byPrint = (sum['by_print'] || []) as Row[];
    const byParent = (sum['by_parent'] || []) as Row[];
    const pending = Array.isArray(unmapped) ? unmapped : [];
    const parentName = (pid: string) =>
      str(byParent.find((p) => str(p, 'parent_agent_id') === pid) || {}, 'parent_name');

    const pendingCols: Array<Column<Row>> = [
      { key: 'source_name', label: 'الاسم في الملف',
        cell: (r) => `<b>${esc(str(r, 'source_name'))}</b>` },
      { key: 'subscribers', label: 'مشتركون', numeric: true,
        cell: (r) => count(num(r, 'subscribers')) },
      { key: 'lines', label: 'أسطر', numeric: true, cell: (r) => count(num(r, 'lines')) },
      { key: 'resolution', label: 'الحالة', cell: (r) =>
        chip(str(r, 'resolution') === 'needs_review' ? 'تحت المراجعة' : 'غير مربوط', 'warning') },
    ];

    const printCols: Array<Column<Row>> = [
      { key: 'print_name', label: 'الفرع',
        cell: (r) => esc(str(r, 'print_name') || '— بلا فرعٍ محسوم') },
      { key: 'parent', label: 'الأب',
        cell: (r) => esc(parentName(str(r, 'parent_agent_id')) || '—') },
      { key: 'subscribers', label: 'مشتركون', numeric: true,
        cell: (r) => count(num(r, 'subscribers')) },
      { key: 'awarded', label: 'أقساط', numeric: true, cell: (r) => count(num(r, 'awarded')) },
      { key: 'amount', label: 'المبلغ', numeric: true,
        cell: (r) => `<span class="money">${esc(money(num(r, 'amount')))}</span>` },
    ];

    const parentCols: Array<Column<Row>> = [
      { key: 'parent_name', label: 'الأب',
        cell: (r) => esc(str(r, 'parent_name') || '— بلا أبٍ محسوم') },
      { key: 'prints', label: 'فروع', numeric: true, cell: (r) => count(num(r, 'prints')) },
      { key: 'subscribers', label: 'مشتركون', numeric: true,
        cell: (r) => count(num(r, 'subscribers')) },
      { key: 'awarded', label: 'أقساط', numeric: true, cell: (r) => count(num(r, 'awarded')) },
      { key: 'amount', label: 'المبلغ', numeric: true,
        cell: (r) => `<span class="money">${esc(money(num(r, 'amount')))}</span>` },
    ];

    const lineCols: Array<Column<Row>> = [
      { key: 'subscriber_key', label: 'المشترك', cell: (r) =>
        `<b dir="ltr">${esc(str(r, 'subscriber_key'))}</b>`
        + (r['registry_hit'] ? '' : ` ${chip('جديد', 'info')}`) },
      { key: 'sequence_in_subscriber', label: '#', numeric: true,
        cell: (r) => count(num(r, 'sequence_in_subscriber')) },
      { key: 'opening_stage', label: 'الافتتاح', cell: (r) => esc(str(r, 'opening_stage')) },
      { key: 'awarded_stage', label: 'الممنوح', cell: (r) =>
        str(r, 'awarded_stage') ? chip(str(r, 'awarded_stage'), 'success') : '—' },
      { key: 'closing_stage', label: 'الإغلاق', cell: (r) => esc(str(r, 'closing_stage')) },
      { key: 'amount', label: 'المبلغ', numeric: true, cell: (r) =>
        num(r, 'amount') ? `<span class="money">${esc(money(num(r, 'amount')))}</span>` : '—' },
      { key: 'print_name', label: 'الفرع', cell: (r) =>
        esc(str(r, 'print_name') || str(r, 'source_parent_name') || '—') },
      { key: 'outcome', label: 'النتيجة', cell: (r) =>
        chip(OUTCOME[str(r, 'outcome')]?.label || str(r, 'outcome'),
             OUTCOME[str(r, 'outcome')]?.tone || 'neutral') },
      { key: 'reason_code', label: 'السبب', cell: (r) => str(r, 'reason_code')
        ? `<span class="muted" style="font-size:11px">${esc(reasonAr(str(r, 'reason_code')))}</span>`
        : '—' },
    ];

    const tabs = ['', 'AWARDED', 'BLOCKED', 'NEEDS_REVIEW', 'NO_STAGE_REMAINING']
      .map((o) => {
        const q: Record<string, string | undefined> = { outcome: o || undefined };
        return `<a class="smallbtn" href="${esc(href(`/installation/monthly/${id}`, q))}"${
          o === outcome ? ' aria-current="true"' : ''}>${
          esc(o ? OUTCOME[o]?.label || o : 'الكل')}</a>`;
      }).join(' ');

    view.innerHTML = pageHeader(`نتيجة ${str(sum, 'period')}`,
      `${RUN_STATE[status]?.label || status} · ${count(num(sum, 'events'))} حدثاً`
      + ` لـ${count(num(sum, 'subscribers'))} مشتركاً`)

      + kpiRow([
        { label: 'نتيجة الشهر', value: money(num(sum, 'total_amount')), tone: 'gold',
          sub: `${count(num(sum, 'awarded'))} قسطاً ممنوحاً` },
        { label: 'مشتركون جدد', value: count(num(sum, 'new_subscribers')), tone: 'blue',
          sub: 'دخلوا عند القسط الأول' },
        { label: 'محجوب أو تحت المراجعة', value: count(num(sum, 'blocked')),
          tone: num(sum, 'blocked') ? 'red' : 'green', sub: 'لكلِّ سطرٍ سببٌ مكتوب' },
        { label: 'أسطر معلَّقة على اسم', value: count(num(sum, 'unresolved_print_count')),
          tone: num(sum, 'unresolved_print_count') ? 'red' : 'green',
          sub: num(sum, 'unresolved_print_count') ? 'تمنع الاعتماد' : 'لا شيء معلَّق' },
      ])

      + `<div class="box" style="margin-top:14px">
        <h3>المراحل الممنوحة</h3>
        ${['P1', 'P2', 'P3', 'P4'].map((s) => `<div class="minirow">
          <span><b>${s}</b></span>
          <span class="money">${count(Number(stages[s] || 0))}</span></div>`).join('')}
      </div>`

      + (pending.length ? `<div class="box" style="margin-top:14px">
        <h3>أسماء بلا مالكٍ محسوم ${chip(count(pending.length), 'warning')}</h3>
        <p class="muted" style="font-size:11px;margin:0 0 10px">
          هذه الأسماء وردت في ملف الشهر ولا نعرف صاحبها. لا يُخمَّن لها مالكٌ
          ولا تُطابَق تقريبياً: تُحسَم بقرارٍ مسجَّل في شاشة الوكلاء، ثم يُعاد
          حساب الشهر. وقبل ذلك لا يُعتمَد الشهر.</p>
        ${table(pendingCols, pending)}
      </div>` : '')

      + `<div class="box" style="margin-top:14px">
        <h3>تجميع الفروع (Print)</h3>
        ${byPrint.length ? table(printCols, byPrint) : empty('لا فرعَ في هذا الشهر')}
      </div>`

      + `<div class="box" style="margin-top:14px">
        <h3>تجميع الآباء</h3>
        ${byParent.length ? table(parentCols, byParent) : empty('لا أبَ في هذا الشهر')}
        <p class="muted" style="font-size:11px;margin:10px 0 0">
          التجميعان يخرجان من أسطر الشهر نفسها، فيتطابق مجموعهما مع نتيجة الشهر
          بالبناء لا بالمصادفة.</p>
      </div>`

      + (Object.keys(reasons).length ? `<div class="box" style="margin-top:14px">
        <h3>أسباب الاستبعاد</h3>
        ${Object.entries(reasons).sort((a, b) => Number(b[1]) - Number(a[1]))
          .map(([code, n]) => `<div class="minirow">
            <span>${chip(reasonAr(code), 'warning')}</span>
            <span class="money">${count(Number(n))}</span></div>`).join('')}
      </div>` : '')

      + `<div class="box" style="margin-top:14px">
        <h3>أسطر الشهر</h3>
        <div class="zoneActions" style="justify-content:flex-start">${tabs}</div>
        ${lines.rows.length ? table(lineCols, lines.rows) : empty('لا سطرَ بهذا الترشيح')}
        ${pager(lines.total, lines.limit, lines.offset,
                `/installation/monthly/${id}`, m.query)}
      </div>`

      + (status === 'APPROVED'
        ? insight('good', 'هذا الشهر معتمَد',
            'الدليل مجمَّدٌ لا يُعاد حسابه. والاعتماد ليس دفعاً — الدفع مسارٌ آخر.')
        : status === 'NEEDS_REVIEW'
        ? insight('danger', 'لا يُعتمَد هذا الشهر بعد',
            'فيه أسماءُ مصدرٍ بلا مالكٍ محسوم. احسمها في شاشة الوكلاء ثم أعد حساب الشهر.')
        : can('installation.calculation_approve')
        ? `<div class="box" style="margin-top:14px" id="mcAp" data-run="${esc(id)}">
            <h3>اعتماد نتيجة الشهر</h3>
            <p class="muted" style="font-size:11px;margin:0 0 10px">
              الاعتماد يُسجّل المشتركين الجدد، ويُثبّت مرحلة كل مشترك للشهر
              القادم، ويحفظ الدليل كاملاً. <b>وهو ليس دفعاً:</b> لا دفعةً
              يُنشئ، ولا قيدَ دفتر، ولا يَسِم قسطاً بأنه مدفوع.</p>
            <div class="zoneActions" style="justify-content:flex-start">
              <button class="btn gold" id="mcApRun">اعتمد نتيجة الشهر</button>
            </div>
            <div id="mcApOut"></div>
          </div>`
        : '');

    wireApprove(view);
  },
};

function wireApprove(view: View): void {
  const box = view.el.querySelector<HTMLElement>('#mcAp');
  if (!box) return;
  const runId = box.dataset['run'] || '';
  const btn = box.querySelector<HTMLButtonElement>('#mcApRun');
  const out = box.querySelector<HTMLElement>('#mcApOut');
  if (!btn || !out) return;

  btn.addEventListener('click', async () => {
    btn.disabled = true;
    out.innerHTML = loading('جارٍ اعتماد نتيجة الشهر…');
    try {
      const doc = await rpc<Row>('approve_installation_calculation', {
        p_run_id: runId, p_request_id: crypto.randomUUID(),
      });
      if (!view.live) return;
      // الزرّ لا يُعاد تسليحه بعد النجاح: الشهر صار معتمَداً.
      out.innerHTML = doc['replayed']
        ? insight('good', 'هذا الشهر معتمَدٌ سلفاً',
            'الاعتماد لا يتكرّر أثره، فالضغطة الثانية لا تُنشئ شيئاً.')
        : insight('good', 'اعتُمدت نتيجة الشهر',
            `${count(num(doc, 'awarded'))} قسطاً · ${money(num(doc, 'total_amount'))}`
            + ` · ${count(num(doc, 'new_subscribers'))} مشتركاً جديداً`
            + ' — ولا دفعةَ ولا قيدَ دفتر.');
    } catch (error) {
      if (!view.live) return;
      out.innerHTML = insight('danger', 'لم يُعتمَد الشهر',
        error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
      btn.disabled = false;
    }
  });
}

export const routes: Route[] = [monthly, monthlyRun];
