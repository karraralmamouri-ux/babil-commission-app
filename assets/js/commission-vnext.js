/*!
 * طبقة عرض محرّك العمولة vNext.
 *
 * لا حساب مالي هنا. الشريحة والمبالغ وأساسها كلها تأتي من الخادم؛ ووظيفة هذا
 * الملف ترتيبُ ما وصل وتسميةُ أسبابه. أي حساب يجري هنا يصير حقيقةً ثانية
 * تتباعد عن الأولى، وهذا ما تمنعه الاختبارات صراحةً.
 */
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.CommissionVNext = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // ---------------------------------------------------------------------------
  // المقياسان اللذان لا يجوز خلطهما
  // ---------------------------------------------------------------------------

  const METRICS = {
    tierBasis: {
      key: 'unique_activated_subscribers',
      label: 'المشتركون المميّزون المفعَّلون',
      hint: 'أساس اختيار الشريحة — يُحسب المشترك مرة واحدة مهما تكرّرت تفعيلاته',
    },
    billable: {
      key: 'qualifying_event_count',
      label: 'أحداث التفعيل المُعمَّلة',
      hint: 'كل حدث مؤهِّل يُحسب على حدة، وعليه تُحسب العمولة',
    },
  };

  /**
   * يقرأ اللقطة كما وصلت. لا يشتق أحدهما من الآخر: خلطهما هو الخطأ الذي
   * أُنشئ هذا المحرّك لإزالته.
   */
  function readSnapshot(row) {
    if (!row) return null;
    return {
      cycleId: row.cycle_id,
      scopeType: row.scope_type,
      scopeId: row.scope_id,
      scopeLabel: row.scope_label || row.scope_id,
      zone: row.zone,
      uniqueActivatedSubscribers: Number(row.unique_activated_subscribers) || 0,
      qualifyingEvents: Number(row.qualifying_event_count) || 0,
      tier: row.tier_code || null,
      packageBreakdown: row.package_breakdown || {},
      gross: Number(row.gross_commission) || 0,
      finalized: Boolean(row.finalized_at),
      measurementStart: row.measurement_start || null,
      measurementEnd: row.measurement_end || null,
      schemeVersionId: row.scheme_version_id || null,
    };
  }

  /** متوقَّع أم نهائي — الفرق قرار تشغيلي يجب أن يظهر للمستخدم. */
  function snapshotMode(snapshot) {
    if (!snapshot) return { key: 'none', label: '—' };
    return snapshot.finalized
      ? { key: 'final', label: 'نهائي' }
      : { key: 'projected', label: 'متوقَّع' };
  }

  const ZONE_LABELS = { old: 'المنطقة القديمة', new: 'المنطقة الجديدة' };
  const SCOPE_LABELS = { AGENT: 'وكيل', FDT: 'كابينة', GLOBAL: 'عام' };

  function describeScope(snapshot) {
    if (!snapshot) return '';
    const zone = ZONE_LABELS[snapshot.zone] || snapshot.zone;
    const scope = SCOPE_LABELS[snapshot.scopeType] || snapshot.scopeType;
    return `${zone} · ${scope}`;
  }

  // ---------------------------------------------------------------------------
  // تجميع الدورة
  // ---------------------------------------------------------------------------

  /**
   * إجماليات الدورة من اللقطات.
   * المشتركون تُجمَع عبر النطاقات لأن النطاق هو وحدة القياس المعتمدة؛ ولا
   * تُدمَج نطاقات في رقم واحد «مميّز» لأن ذلك يخلط مقياسين.
   */
  function summarizeCycle(snapshots) {
    const rows = (snapshots || []).map(readSnapshot).filter(Boolean);
    return {
      scopes: rows.length,
      subscribersByScope: rows.reduce((n, r) => n + r.uniqueActivatedSubscribers, 0),
      qualifyingEvents: rows.reduce((n, r) => n + r.qualifyingEvents, 0),
      gross: rows.reduce((n, r) => n + r.gross, 0),
      finalizedScopes: rows.filter((r) => r.finalized).length,
      byZone: ['old', 'new'].map((zone) => {
        const inZone = rows.filter((r) => r.zone === zone);
        return {
          zone,
          label: ZONE_LABELS[zone],
          scopes: inZone.length,
          subscribers: inZone.reduce((n, r) => n + r.uniqueActivatedSubscribers, 0),
          events: inZone.reduce((n, r) => n + r.qualifyingEvents, 0),
          gross: inZone.reduce((n, r) => n + r.gross, 0),
        };
      }).filter((z) => z.scopes > 0),
    };
  }

  /** تفصيل الباقات من اللقطة، مرتَّباً ليقرأ الإنسان. */
  function packageRows(snapshot) {
    const breakdown = (snapshot && snapshot.packageBreakdown) || {};
    return Object.keys(breakdown).sort().map((code) => ({
      code, count: Number(breakdown[code]) || 0,
    }));
  }

  // ---------------------------------------------------------------------------
  // الاستثناءات
  // ---------------------------------------------------------------------------

  const EXCEPTION_LABELS = {
    UNKNOWN_AGENT: 'وكيل غير معروف',
    UNKNOWN_FDT: 'كابينة غير معروفة',
    UNKNOWN_PACKAGE: 'باقة غير معروفة',
    IDENTITY_CONFLICT: 'تعارض هوية',
    SOURCE_INCOMPLETE: 'اكتمال المصدر غير مُثبت',
    EVENT_CONFLICT: 'تعارض في الحدث',
    ATTRIBUTION_REVIEW: 'العائدية تحتاج مراجعة',
    MISSING_PERIOD: 'فترة ناقصة',
  };

  function describeException(code) {
    return EXCEPTION_LABELS[code] || code;
  }

  /** ما يحجب الاعتماد أولاً؛ فالمستخدم يحتاج أن يعرف ما يوقفه لا ما يزعجه. */
  function groupExceptions(rows) {
    const open = (rows || []).filter((row) => row.status === 'OPEN');
    const blocking = open.filter((row) => row.blocks_finalization);
    const counts = new Map();
    open.forEach((row) => {
      const entry = counts.get(row.reason_code) || { code: row.reason_code, open: 0, blocking: 0 };
      entry.open += 1;
      if (row.blocks_finalization) entry.blocking += 1;
      counts.set(row.reason_code, entry);
    });
    return {
      open: open.length,
      blocking: blocking.length,
      canFinalize: blocking.length === 0,
      reasons: [...counts.values()]
        .map((entry) => Object.assign(entry, { label: describeException(entry.code) }))
        .sort((a, b) => b.blocking - a.blocking || b.open - a.open),
    };
  }

  // ---------------------------------------------------------------------------
  // التهيئة
  // ---------------------------------------------------------------------------

  function orderedTiers(tiers) {
    return (tiers || []).slice().sort((a, b) => Number(a.sequence) - Number(b.sequence));
  }

  function describeTierBand(tier) {
    if (!tier) return '';
    const max = tier.max_subscribers;
    return max === null || max === undefined
      ? `${tier.min_subscribers} فأكثر`
      : `${tier.min_subscribers}–${max}`;
  }

  /** الإصدار المنشور لا يُحرَّر؛ الواجهة تقول هذا بدل أن تسمح ثم تفشل. */
  function isEditableVersion(version) {
    return Boolean(version) && version.status === 'DRAFT';
  }

  /** ما الشريحة التي يقع فيها هذا العدد؟ للعرض التوضيحي في شاشة التهيئة. */
  function tierForSubscribers(tiers, count) {
    const n = Number(count);
    if (!Number.isFinite(n)) return null;
    return orderedTiers(tiers).find((tier) => {
      const max = tier.max_subscribers;
      return n >= Number(tier.min_subscribers)
        && (max === null || max === undefined || n <= Number(max));
    }) || null;
  }

  return {
    METRICS, ZONE_LABELS, SCOPE_LABELS, EXCEPTION_LABELS,
    readSnapshot, snapshotMode, describeScope, summarizeCycle, packageRows,
    describeException, groupExceptions,
    orderedTiers, describeTierBand, isEditableVersion, tierForSubscribers,
  };
});
