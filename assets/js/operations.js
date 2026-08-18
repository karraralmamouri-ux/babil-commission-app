/*!
 * طبقة العرض لمحرّك العمليات المالية.
 *
 * كل ما هنا عرضٌ وترتيب. لا قرار مالي يُتَّخذ في هذا الملف: القدرة تُفحص على
 * الخادم قبل كل RPC، والأهلية تُحسَب هناك وتُعاد قبل الترحيل. ما يفعله هذا
 * الملف هو إخفاء ما لا فائدة من عرضه، وترجمة أسباب المنع إلى لغة مفهومة.
 */
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.Operations = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // ---------------------------------------------------------------------------
  // القدرات
  // ---------------------------------------------------------------------------

  /** يبني فهرساً من نتيجة my_capabilities. */
  function indexCapabilities(rows) {
    const map = new Map();
    (rows || []).forEach((row) => {
      map.set(row.capability_key, {
        effective: row.effective === true,
        source: row.source || 'NONE',
      });
    });
    return map;
  }

  /**
   * هل يملك المستخدم هذه القدرة؟
   * الغياب يعني «لا»: قدرة لم تصل من الخادم لا تُفترض ممنوحة.
   */
  function can(capabilities, key) {
    const entry = capabilities && capabilities.get ? capabilities.get(key) : null;
    return Boolean(entry && entry.effective);
  }

  /** أول قدرة مفقودة من قائمة مطلوبة — لرسالة دقيقة بدل «غير مصرّح». */
  function firstMissing(capabilities, keys) {
    return (keys || []).find((key) => !can(capabilities, key)) || null;
  }

  const SOURCE_LABELS = {
    DENY: 'ممنوع صراحةً',
    GRANT: 'ممنوح صراحةً',
    TEMPLATE: 'موروث من الدور',
    NONE: 'غير ممنوح',
  };

  /** يشرح مصدر القدرة للواجهة الإدارية. */
  function explainSource(capabilities, key) {
    const entry = capabilities && capabilities.get ? capabilities.get(key) : null;
    const source = entry ? entry.source : 'NONE';
    return { source, label: SOURCE_LABELS[source] || SOURCE_LABELS.NONE };
  }

  // ---------------------------------------------------------------------------
  // أسباب المنع
  // ---------------------------------------------------------------------------

  const BLOCKER_LABELS = {
    NOT_FOUND: 'الاستحقاق غير موجود',
    ALREADY_PAID: 'مدفوع سلفاً',
    INVALID_STAGE: 'المرحلة غير قابلة للدفع',
    NOT_ENROLLED: 'المشترك غير مسجَّل في مخطط',
    ENROLLMENT_INACTIVE: 'التسجيل غير نشط',
    STAGE_OUT_OF_SEQUENCE: 'المرحلة ليست التالية في التسلسل',
    STAGE_NOT_IN_SCHEME: 'المرحلة ليست ضمن المخطط',
    AMOUNT_DOES_NOT_MATCH_SCHEME: 'المبلغ لا يطابق المخطط',
    IDENTITY_CONFLICT: 'تعارض هوية',
    UNKNOWN_PARENT: 'أب غير معروف',
    DIRECT_COMPANY_NOT_PAYABLE: 'اشتراك شركة مباشر لا يُستحق لوكيل',
    MISSING_INVOICE: 'لا فاتورة مدقَّقة',
    ON_HOLD: 'عليه تعليق نشط',
    UNRESOLVED_HISTORICAL_STATE: 'حالة تاريخية غير محسومة',
    EVENT_NOT_FOUND: 'حدث التفعيل غير موجود',
    EVENT_CANCELED: 'حدث التفعيل ملغى',
    UNKNOWN_PACKAGE: 'باقة غير معروفة',
    DEBT_SERVICE_NEVER_QUALIFIES: 'خدمة دَين لا تؤهِّل',
    PACKAGE_NOT_QUALIFYING: 'الباقة لا تؤهِّل',
    SOURCE_INCOMPLETE: 'اكتمال المصدر غير مُثبت',
    UNMATCHED_SUBSCRIBER: 'مشترك غير مطابَق',
    IDENTITY_NOT_RESOLVED: 'الهوية غير محسومة',
    DIRECT_COMPANY_NOT_ELIGIBLE: 'شركة مباشرة غير مؤهَّلة',
    EFFECTIVE_AGENT_UNRESOLVED: 'الوكيل الفعلي غير محدَّد',
    PARENT_NEEDS_REVIEW: 'الأب يحتاج مراجعة',
    NOT_CLASSIFIED: 'لم يُصنَّف بعد',
    SUBSCRIBER_IS_EXISTING: 'مشترك قديم لا تنصيب جديد له',
    CLASSIFICATION_NEEDS_REVIEW: 'التصنيف يحتاج مراجعة',
    ALREADY_ENROLLED: 'مسجَّل سلفاً',
    EVENT_ALREADY_USED: 'الحدث استُعمل في تسجيل آخر',
  };

  function describeBlocker(code) {
    // السبب المجهول يُعرض كما ورد بدل أن يُبتلع: رمز غير مترجَم أفضل من صمت.
    return BLOCKER_LABELS[code] || code;
  }

  function describeBlockers(blockers) {
    return (blockers || []).map(describeBlocker);
  }

  // ---------------------------------------------------------------------------
  // طوابير العمل
  // ---------------------------------------------------------------------------

  // ترتيب مقصود: ما يحتاج قراراً بشرياً أولاً، والجاهز والمدفوع في الذيل.
  const QUEUES = [
    { key: 'needs_review',      label: 'يحتاج مراجعة',   blockers: ['CLASSIFICATION_NEEDS_REVIEW', 'NOT_CLASSIFIED', 'PARENT_NEEDS_REVIEW', 'STAGE_OUT_OF_SEQUENCE', 'AMOUNT_DOES_NOT_MATCH_SCHEME'] },
    { key: 'missing_invoice',   label: 'فاتورة ناقصة',   blockers: ['MISSING_INVOICE'] },
    { key: 'identity_conflict', label: 'تعارض هوية',     blockers: ['IDENTITY_CONFLICT', 'UNMATCHED_SUBSCRIBER', 'IDENTITY_NOT_RESOLVED'] },
    { key: 'unknown_parent',    label: 'أب غير معروف',   blockers: ['UNKNOWN_PARENT', 'EFFECTIVE_AGENT_UNRESOLVED'] },
    { key: 'on_hold',           label: 'معلَّق',          blockers: ['ON_HOLD'] },
    { key: 'ready',             label: 'جاهز للدفع',     blockers: [] },
    { key: 'paid',              label: 'مدفوع',          blockers: ['ALREADY_PAID'] },
  ];

  /**
   * يوزّع تقييمات الأهلية على الطوابير.
   * البند المحجوب بأكثر من سبب يظهر في أول طابور يطابقه فقط، فلا يُعدّ مرتين
   * ولا يبدو العمل أكبر مما هو.
   */
  function buildQueues(evaluations) {
    const buckets = new Map(QUEUES.map((q) => [q.key, []]));

    (evaluations || []).forEach((evaluation) => {
      const blockers = evaluation.blockers || [];
      if (evaluation.eligible) {
        buckets.get('ready').push(evaluation);
        return;
      }
      const queue = QUEUES.find(
        (q) => q.blockers.length && q.blockers.some((code) => blockers.includes(code)));
      // المحجوب بسبب لا طابور له يبقى مرئياً في المراجعة بدل أن يختفي.
      buckets.get(queue ? queue.key : 'needs_review').push(evaluation);
    });

    return QUEUES.map((q) => ({
      key: q.key,
      label: q.label,
      count: buckets.get(q.key).length,
      items: buckets.get(q.key),
    }));
  }

  /** مجموع مبالغ الجاهز — الرقم الذي يهمّ قبل تكوين دفعة. */
  function readyTotal(evaluations) {
    return (evaluations || [])
      .filter((evaluation) => evaluation.eligible)
      .reduce((sum, evaluation) => sum + (Number(evaluation.amount) || 0), 0);
  }

  // ---------------------------------------------------------------------------
  // المخططات
  // ---------------------------------------------------------------------------

  /** المبلغ يأتي من تعريفات المخطط. لا جدول ثابت في الواجهة. */
  function stageAmount(stages, code) {
    const stage = (stages || []).find((item) => item.code === code);
    return stage ? Number(stage.amount) : null;
  }

  function orderedStages(stages) {
    return (stages || []).slice().sort((a, b) => Number(a.sequence) - Number(b.sequence));
  }

  function schemeTotal(stages) {
    return (stages || []).reduce((sum, stage) => sum + (Number(stage.amount) || 0), 0);
  }

  /** الإصدار المنشور لا يُحرَّر. الواجهة تعرض هذا بدل أن تسمح ثم تفشل. */
  function isEditableVersion(version) {
    return Boolean(version) && version.status === 'DRAFT';
  }

  return {
    indexCapabilities, can, firstMissing, explainSource,
    describeBlocker, describeBlockers, BLOCKER_LABELS,
    QUEUES, buildQueues, readyTotal,
    stageAmount, orderedStages, schemeTotal, isEditableVersion,
  };
});
