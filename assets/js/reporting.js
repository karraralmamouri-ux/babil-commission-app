/*!
 * طبقة التقارير والدفع في الواجهة.
 *
 * كل رقم هنا يأتي محسوباً من الخادم. لا تجميع مالي في المتصفح: ما يُعرض هو
 * ما تقرّر، وما يُصدَّر هو ما عُرض. الفرق بين الاثنين هو ما يجعل تقريراً
 * يناقض قاعدةَ بياناته.
 */
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.Reporting = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // ---------------------------------------------------------------------------
  // مفردات الحالة — واحدة في كل الشاشات
  // ---------------------------------------------------------------------------

  const STATUS_LABELS = {
    DRAFT: 'مسودّة',
    DATA_IMPORTED: 'بيانات مُستوردة',
    UNDER_REVIEW: 'قيد المراجعة',
    READY_TO_FINALIZE: 'جاهزة للاعتماد',
    READY_FOR_PAYMENT: 'جاهزة للدفع',
    READY: 'جاهزة',
    FINALIZED: 'معتمدة',
    PARTIALLY_PAID: 'مدفوعة جزئياً',
    PAID: 'مدفوعة',
    POSTED: 'مُرحَّلة',
    CLOSED: 'مقفلة',
    CANCELLED: 'ملغاة',
    PENDING: 'بانتظار',
    BLOCKED: 'محجوبة',
    SKIPPED: 'متجاوَزة',
  };

  function statusLabel(code) {
    return STATUS_LABELS[code] || code || '—';
  }

  // الترتيب يعكس تقدّم العمل، فتقرأ الشاشة كخط زمني لا كقائمة عشوائية.
  const CYCLE_FLOW = ['DRAFT', 'DATA_IMPORTED', 'UNDER_REVIEW', 'READY_TO_FINALIZE',
    'FINALIZED', 'PARTIALLY_PAID', 'PAID', 'CLOSED'];

  function flowPosition(status) {
    const i = CYCLE_FLOW.indexOf(status);
    return i < 0 ? null : { index: i, total: CYCLE_FLOW.length, label: statusLabel(status) };
  }

  // ---------------------------------------------------------------------------
  // الملخص التنفيذي
  // ---------------------------------------------------------------------------

  /**
   * يحوّل ردّ report_management_summary إلى بطاقات.
   * لا يُعيد حساب شيء — يقرأ ويسمّي، ويترك كل رقم قابلاً للنزول إلى مصدره.
   */
  function summaryCards(payload) {
    if (!payload) return [];
    const g = payload.global || {};
    const c = (payload.commission && payload.commission.totals) || {};
    const i = payload.installation || {};

    return [
      { key: 'obligations', label: 'إجمالي الالتزامات', value: g.total_obligations || 0,
        unit: 'د.ع', drill: 'commission' },
      { key: 'paid', label: 'المدفوع', value: g.total_paid || 0, unit: 'د.ع', drill: 'ledger' },
      { key: 'remaining', label: 'المتبقي', value: g.total_remaining || 0,
        unit: 'د.ع', drill: 'commission' },
      { key: 'unresolved', label: 'حالات تحتاج حسماً', value: g.unresolved_cases || 0,
        unit: '', drill: 'exceptions' },
      { key: 'subscribers', label: 'مشتركون مميّزون مفعَّلون',
        value: c.unique_activated_subscribers || 0, unit: '', drill: 'commission' },
      { key: 'events', label: 'أحداث مُعمَّلة', value: c.qualifying_events || 0,
        unit: '', drill: 'commission' },
      { key: 'inst_ready', label: 'أجور تنصيب جاهزة', value: i.ready || 0,
        unit: '', drill: 'installation' },
      { key: 'inst_held', label: 'أجور تنصيب معلَّقة', value: i.held || 0,
        unit: '', drill: 'exceptions' },
    ];
  }

  // ---------------------------------------------------------------------------
  // المصالحة — الحارس ضد تقرير يناقض نفسه
  // ---------------------------------------------------------------------------

  /**
   * هل يساوي مجموع التفصيل مجموع الملخّص؟
   * تُستدعى قبل العرض: رقمان متعارضان في شاشة واحدة أسوأ من رقم واحد ناقص.
   */
  function reconcile(summaryTotals, detailRows) {
    const sum = (rows, key) => (rows || []).reduce((n, r) => n + (Number(r[key]) || 0), 0);
    const gross = sum(detailRows, 'gross');
    const paid = sum(detailRows, 'net_paid');
    const remaining = sum(detailRows, 'remaining');
    const t = summaryTotals || {};
    const diffs = [];
    if (Number(t.gross || 0) !== gross) diffs.push({ field: 'gross', summary: Number(t.gross || 0), detail: gross });
    if (Number(t.net_paid || 0) !== paid) diffs.push({ field: 'net_paid', summary: Number(t.net_paid || 0), detail: paid });
    if (Number(t.remaining || 0) !== remaining) diffs.push({ field: 'remaining', summary: Number(t.remaining || 0), detail: remaining });
    return { ok: diffs.length === 0, diffs, detail: { gross, paid, remaining } };
  }

  // ---------------------------------------------------------------------------
  // التصدير
  // ---------------------------------------------------------------------------

  /** يهرب حقلاً واحداً لـCSV. الفاصلة والاقتباس وسطر جديد كلها تكسر الملف. */
  function csvField(value) {
    if (value === null || value === undefined) return '';
    const text = String(value);
    return /[",\n\r]/.test(text) ? '"' + text.replace(/"/g, '""') + '"' : text;
  }

  /**
   * يبني CSV من صفوف الخادم.
   * الأعمدة تُملى صراحةً: تصديرٌ يتبع شكل الردّ يتغيّر بصمت مع أي تغيير فيه.
   */
  function toCsv(rows, columns) {
    const cols = columns || (rows && rows.length ? Object.keys(rows[0]) : []);
    const head = cols.map((c) => csvField(c.label || c.key || c)).join(',');
    const body = (rows || []).map((row) => cols
      .map((c) => csvField(row[c.key || c]))
      .join(',')).join('\r\n');
    // BOM حتى تفتح إكسل العربية بالترميز الصحيح بدل حروف مشوّهة.
    return '﻿' + head + (body ? '\r\n' + body : '');
  }

  const COMMISSION_EXPORT_COLUMNS = [
    { key: 'cycle_name', label: 'الدورة' },
    { key: 'zone', label: 'المنطقة' },
    { key: 'scope_type', label: 'نوع النطاق' },
    { key: 'scope_label', label: 'النطاق' },
    { key: 'tier_code', label: 'الشريحة' },
    { key: 'unique_activated_subscribers', label: 'مشتركون مميّزون' },
    { key: 'qualifying_event_count', label: 'أحداث مُعمَّلة' },
    { key: 'p35_count', label: 'P-35000' },
    { key: 'p45_count', label: 'P-45000' },
    { key: 'p65_count', label: 'P-65000' },
    { key: 'gross', label: 'الإجمالي' },
    { key: 'net_paid', label: 'المدفوع' },
    { key: 'remaining', label: 'المتبقي' },
    { key: 'scheme_version_id', label: 'إصدار المخطط' },
    { key: 'finalized_at', label: 'تاريخ الاعتماد' },
  ];

  const EXCEPTION_EXPORT_COLUMNS = [
    { key: 'domain', label: 'المجال' },
    { key: 'subject', label: 'الموضوع' },
    { key: 'reason_code', label: 'السبب' },
    { key: 'detail', label: 'التفصيل' },
    { key: 'blocking', label: 'يحجب' },
    { key: 'created_at', label: 'التاريخ' },
  ];

  // ---------------------------------------------------------------------------
  // الصفحات
  // ---------------------------------------------------------------------------

  /** يمنع طلب صفحة أكبر مما يسمح به الخادم، فلا يُردّ الطلب بعد رحلة كاملة. */
  const MAX_PAGE = 500;

  /** حجم غير موجب يعني «غير محدَّد» فيُؤخذ الافتراضي — لا صفّاً واحداً. */
  function normalizeSize(size) {
    const n = Number(size);
    if (!Number.isFinite(n) || n <= 0) return 100;
    return Math.min(Math.max(Math.trunc(n), 1), MAX_PAGE);
  }

  function pageParams(page, size) {
    const limit = normalizeSize(size);
    const offset = Math.max((Number(page) || 1) - 1, 0) * limit;
    return { limit, offset };
  }

  function pageInfo(totalCount, page, size) {
    const limit = normalizeSize(size);
    const total = Number(totalCount) || 0;
    const pages = Math.max(Math.ceil(total / limit), 1);
    const current = Math.min(Math.max(Number(page) || 1, 1), pages);
    return { total, pages, current, limit, hasPrev: current > 1, hasNext: current < pages };
  }

  // ---------------------------------------------------------------------------
  // عرض دورة الحياة
  //
  // الحالات الفعلية ثمانٍ، وعرضها ثمانيَ خطوات يجعل الشريط ضجيجاً. تُطوى إلى
  // خمس مراحل يفهمها المستخدم، ولا تُخترع حالة ولا تُغيَّر حالة: الطيّ عرضٌ
  // فقط، والمصدر يبقى status كما هو.
  // ---------------------------------------------------------------------------

  const CYCLE_STAGES = [
    { key: 'draft',    label: 'مسودة',        css: 'cycle-draft' },
    { key: 'review',   label: 'مراجعة',       css: 'cycle-review' },
    { key: 'approved', label: 'معتمدة',       css: 'cycle-approved' },
    { key: 'payable',  label: 'جاهزة للصرف', css: 'cycle-payable' },
    { key: 'closed',   label: 'مغلقة',        css: 'cycle-closed' },
  ];

  const STAGE_OF_STATUS = {
    DRAFT: 0, DATA_IMPORTED: 0,
    UNDER_REVIEW: 1,
    READY_TO_FINALIZE: 2, FINALIZED: 2,
    READY_FOR_PAYMENT: 3, PARTIALLY_PAID: 3, PAID: 3,
    CLOSED: 4,
  };

  /** المرحلة المعروضة لحالة فعلية. المجهول لا يُنسب إلى مرحلة. */
  function cycleStage(status) {
    const i = STAGE_OF_STATUS[status];
    if (i === undefined) return null;
    return Object.assign({ index: i, status, statusLabel: statusLabel(status) }, CYCLE_STAGES[i]);
  }

  // الرقم غير المعتمد لا يجوز أن يبدو نهائياً. أي حالة قبل الاعتماد تقديرية.
  const FINAL_STATUSES = new Set(['FINALIZED', 'PARTIALLY_PAID', 'PAID', 'CLOSED']);
  function isProjected(status) { return !FINAL_STATUSES.has(status); }

  // ---------------------------------------------------------------------------
  // المال
  //
  // قاعدة تنسيق واحدة في كل الشاشات. الدينار لا كسور، والفاصلة كل ثلاث خانات،
  // والوحدة تلي الرقم. تعدُّد الصيغ في تطبيق مالي يجعل رقمين متطابقين يبدوان
  // مختلفين.
  // ---------------------------------------------------------------------------

  const IQD = 'د.ع';

  function amount(value) {
    const n = Math.round(Number(value) || 0);
    return n.toLocaleString('en-US');
  }

  function money(value) { return amount(value) + ' ' + IQD; }

  /** الصفر يُقال صفراً لا يُترك فراغاً: الفراغ يُقرأ «غير معروف». */
  function moneyOrZero(value) { return money(value || 0); }

  return {
    STATUS_LABELS, statusLabel, CYCLE_FLOW, flowPosition,
    CYCLE_STAGES, cycleStage, isProjected, IQD, amount, money, moneyOrZero,
    summaryCards, reconcile,
    csvField, toCsv, COMMISSION_EXPORT_COLUMNS, EXCEPTION_EXPORT_COLUMNS,
    MAX_PAGE, pageParams, pageInfo,
  };
});
