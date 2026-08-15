/* أجور التنصيب — نطاق مستقل منطقياً عن عمولات الوكلاء.
 *
 * لا تخلط هذا الملف مع حساب العمولات: P35/P45/P65 وشرائح التير تخص العمولات،
 * بينما P1..P4 وDONE تخص أجور التنصيب. لا يشترك النطاقان في أي قاعدة حساب.
 *
 * كل المبالغ بالدينار العراقي كأعداد صحيحة. لا تستخدم أرقاماً عشرية للمال.
 */
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.InstallationFees = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  /* خريطة المتبقي إلى الدفعة المستحقة. مصدرها قرار تجاري معتمد،
     ولا يجوز اشتقاق قيم أخرى منها أو مطابقتها تقريبياً. */
  const STAGE_BY_REMAINING = new Map([
    [13000, { stage: 'P1', amount: 3000 }],
    [10000, { stage: 'P2', amount: 3000 }],
    [7000, { stage: 'P3', amount: 3000 }],
    [4000, { stage: 'P4', amount: 4000 }],
    [0, { stage: 'DONE', amount: 0 }],
  ]);

  const PENDING_STAGES = ['P1', 'P2', 'P3', 'P4'];
  const ALL_STAGES = [...PENDING_STAGES, 'DONE'];

  function isExactInteger(value) {
    return typeof value === 'number' && Number.isInteger(value);
  }

  /* يحوّل قيمة المتبقي إلى عدد صحيح دون قبول صيغ غامضة.
     تُقبل الفواصل الألفية والمسافات فقط، ولا تُقبل الكسور. */
  function parseRemaining(value) {
    if (isExactInteger(value)) return value;
    if (typeof value === 'number') return null;
    if (typeof value !== 'string') return null;
    const clean = value.replace(/[\s,٬،]/g, '').replace(/[٠-٩]/g, (d) =>
      String(d.charCodeAt(0) - 0x0660),
    );
    if (!/^-?\d+$/.test(clean)) return null;
    return Number(clean);
  }

  /* القاعدة الأساسية: المتبقي يحدد الدفعة المستحقة الآن.
     أي قيمة خارج الخريطة تعود كـunresolved ولا يُخترع لها stage. */
  function resolveInstallationStage(remaining) {
    const parsed = parseRemaining(remaining);
    if (parsed === null) {
      return { resolved: false, stage: null, amount: 0, reason: 'قيمة المتبقي غير رقمية أو تحتوي كسوراً' };
    }
    const match = STAGE_BY_REMAINING.get(parsed);
    if (!match) {
      return { resolved: false, stage: null, amount: 0, remaining: parsed, reason: `قيمة متبقٍ غير معروفة: ${parsed}` };
    }
    return { resolved: true, stage: match.stage, amount: match.amount, remaining: parsed };
  }

  function text(value) {
    return String(value === undefined || value === null ? '' : value).trim();
  }

  /* هوية الاستحقاق التجارية: المشترك + الدفعة + الفترة.
     لا يُستخدم رقم السطر أبداً كهوية مالية. */
  function entitlementKey({ subscriberId, stage, period }) {
    return [text(subscriberId).toLowerCase(), text(stage), text(period)].join('');
  }

  function normalizeInstallationRow(row, index) {
    const subscriberId = text(row && row.subscriberId);
    const subscriberName = text(row && row.subscriberName);
    const reseller = text(row && row.reseller);
    const zone = text(row && row.zone).toLowerCase();
    const fdt = text(row && row.fdt);
    const resolved = resolveInstallationStage(row ? row.remaining : undefined);
    const problems = [];

    if (!subscriberId) problems.push('معرّف المشترك مفقود');
    if (!reseller) problems.push('الوكيل مفقود');
    if (!resolved.resolved) problems.push(resolved.reason);

    return {
      sourceRow: index + 2,
      subscriberId,
      subscriberName,
      reseller,
      zone: zone === 'new' || zone === 'old' ? zone : '',
      fdt,
      remaining: resolved.remaining === undefined ? null : resolved.remaining,
      stage: resolved.stage,
      amount: resolved.amount,
      valid: problems.length === 0,
      problems,
    };
  }

  function emptyStageCounts() {
    return ALL_STAGES.reduce((counts, stage) => Object.assign(counts, { [stage]: 0 }), {});
  }

  /* يبني ملخص دفعة استيراد كاملة دون كتابة أي شيء.
     التكرار يُحتسب مرة واحدة ولا يضاعف الاستحقاق. */
  function summarizeInstallationBatch(rows, options) {
    const period = text(options && options.period);
    const normalized = (rows || []).map(normalizeInstallationRow);
    const seen = new Map();
    const accepted = [];
    const duplicates = [];
    const invalid = [];

    normalized.forEach((row) => {
      if (!row.valid) {
        invalid.push(row);
        return;
      }
      const key = entitlementKey({ subscriberId: row.subscriberId, stage: row.stage, period });
      if (seen.has(key)) {
        duplicates.push({ ...row, duplicateOfRow: seen.get(key).sourceRow });
        return;
      }
      seen.set(key, row);
      accepted.push(row);
    });

    const stages = emptyStageCounts();
    const stageAmounts = emptyStageCounts();
    accepted.forEach((row) => {
      stages[row.stage] += 1;
      stageAmounts[row.stage] += row.amount;
    });

    const done = stages.DONE;
    const pending = PENDING_STAGES.reduce((sum, stage) => sum + stages[stage], 0);
    const amount = PENDING_STAGES.reduce((sum, stage) => sum + stageAmounts[stage], 0);

    return {
      period,
      total: accepted.length,
      done,
      pending,
      stages,
      stageAmounts,
      amount,
      accepted,
      duplicates,
      invalid,
      sourceRows: (rows || []).length,
      /* التطابق الإلزامي: DONE + المعلقة = الإجمالي المقبول. */
      reconciled: done + pending === accepted.length,
    };
  }

  /* ملخص لكل وكيل، مشتق من نفس نتيجة الدفعة حتى لا تختلف الأرقام بين الشاشات. */
  function summarizeByReseller(batch) {
    const resellers = new Map();
    batch.accepted.forEach((row) => {
      const key = row.reseller;
      const entry =
        resellers.get(key) ||
        Object.assign(
          { reseller: key, total: 0, done: 0, pending: 0, amount: 0 },
          { stages: emptyStageCounts(), stageAmounts: emptyStageCounts() },
        );
      entry.total += 1;
      entry.stages[row.stage] += 1;
      entry.stageAmounts[row.stage] += row.amount;
      if (row.stage === 'DONE') entry.done += 1;
      else {
        entry.pending += 1;
        entry.amount += row.amount;
      }
      resellers.set(key, entry);
    });
    return [...resellers.values()].sort((a, b) => b.amount - a.amount || a.reseller.localeCompare(b.reseller, 'ar'));
  }

  return {
    ALL_STAGES,
    PENDING_STAGES,
    STAGE_BY_REMAINING,
    entitlementKey,
    normalizeInstallationRow,
    parseRemaining,
    resolveInstallationStage,
    summarizeByReseller,
    summarizeInstallationBatch,
  };
});
