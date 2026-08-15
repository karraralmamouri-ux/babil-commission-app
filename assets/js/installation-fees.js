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

  /* أسماء الأعمدة تتغير بين الملفات، فالربط بالاسم لا بالموقع. */
  const IMPORT_ALIASES = {
    subscriberId: ['subscriber_id', 'subscriberid', 'subscriber id', 'subscriber', 'id', 'معرف المشترك', 'معرّف المشترك', 'رقم المشترك', 'المشترك'],
    subscriberName: ['subscriber_name', 'subscribername', 'subscriber name', 'name', 'full_name', 'اسم المشترك', 'الاسم'],
    reseller: ['reseller', 'agent', 'agent_name', 'الوكيل', 'اسم الوكيل', 'الموزع'],
    zone: ['zone', 'المنطقة', 'النطاق'],
    fdt: ['fdt', 'cabinet', 'الكابينة'],
    remaining: ['remaining', 'remaining_amount', 'balance', 'المتبقي', 'الرصيد المتبقي', 'المبلغ المتبقي'],
  };

  function headerLookup(row) {
    const byNormalized = new Map();
    Object.keys(row || {}).forEach((key) => {
      byNormalized.set(String(key).trim().toLowerCase(), row[key]);
    });
    return (field) => {
      for (const alias of IMPORT_ALIASES[field]) {
        if (byNormalized.has(alias)) return byNormalized.get(alias);
      }
      return '';
    };
  }

  /* يحوّل صفاً خاماً من Excel/CSV إلى شكل النطاق دون الاعتماد على ترتيب الأعمدة. */
  function mapImportRow(raw) {
    const get = headerLookup(raw);
    return {
      subscriberId: text(get('subscriberId')),
      subscriberName: text(get('subscriberName')),
      reseller: text(get('reseller')),
      zone: text(get('zone')).toLowerCase(),
      fdt: text(get('fdt')),
      remaining: get('remaining'),
    };
  }

  /* معاينة الاستيراد: لا تكتب شيئاً، وتصنّف كل صف قبل أي حفظ.
     `existingKeys` هي هويات الاستحقاقات المحفوظة سابقاً، فيُكشف التكرار
     عبر الملفات لا داخل الملف الواحد فقط. */
  function buildImportPreview(rawRows, options) {
    const period = text(options && options.period);
    const existing = new Set((options && options.existingKeys) || []);
    const mapped = (rawRows || []).map(mapImportRow);
    const batch = summarizeInstallationBatch(mapped, { period });

    const alreadyStored = [];
    const fresh = [];
    batch.accepted.forEach((row) => {
      const key = entitlementKey({ subscriberId: row.subscriberId, stage: row.stage, period });
      if (existing.has(key)) alreadyStored.push(row);
      else fresh.push(row);
    });

    const reasons = { unknownRemaining: 0, missingSubscriber: 0, missingReseller: 0 };
    batch.invalid.forEach((row) => {
      const problems = row.problems.join(' ');
      if (problems.includes('متبقٍ') || problems.includes('غير رقمية')) reasons.unknownRemaining += 1;
      if (problems.includes('معرّف المشترك مفقود')) reasons.missingSubscriber += 1;
      if (problems.includes('الوكيل مفقود')) reasons.missingReseller += 1;
    });

    const freshAmount = fresh.reduce((sum, row) => sum + row.amount, 0);
    return {
      period,
      /* الصفوف كما قُرئت، تُرسل إلى الخادم ليتحقق ويصنّف بنفسه. */
      mappedRows: mapped,
      totalRows: (rawRows || []).length,
      valid: batch.accepted.length,
      invalid: batch.invalid.length,
      duplicatesInFile: batch.duplicates.length,
      duplicatesAlreadyStored: alreadyStored.length,
      reasons,
      stages: batch.stages,
      stageAmounts: batch.stageAmounts,
      amount: batch.amount,
      newEntitlements: fresh,
      newAmount: freshAmount,
      invalidRows: batch.invalid,
      duplicateRows: batch.duplicates,
      /* لا يُستورد شيء إذا لم يبقَ صف جديد صالح. */
      importable: fresh.length > 0,
    };
  }

  const INVOICE_STATUSES = ['pending', 'approved', 'missing', 'rejected'];
  const PAYMENT_STATUSES = ['not_eligible', 'awaiting_invoice', 'eligible', 'paid'];

  /* عدادات لوحة أجور التنصيب، محسوبة من الاستحقاقات المحفوظة. */
  function summarizeEntitlements(rows) {
    const list = rows || [];
    const stages = emptyStageCounts();
    const invoices = INVOICE_STATUSES.reduce((acc, key) => Object.assign(acc, { [key]: 0 }), {});
    const payments = PAYMENT_STATUSES.reduce((acc, key) => Object.assign(acc, { [key]: 0 }), {});
    let amountBeforeAudit = 0;
    let eligibleAmount = 0;
    let paidAmount = 0;

    list.forEach((row) => {
      const stage = text(row.stage);
      const amount = Number(row.amount) || 0;
      if (stages[stage] !== undefined) stages[stage] += 1;
      if (invoices[row.invoice_status] !== undefined) invoices[row.invoice_status] += 1;
      if (payments[row.payment_status] !== undefined) payments[row.payment_status] += 1;
      if (stage !== 'DONE') amountBeforeAudit += amount;
      if (row.payment_status === 'eligible') eligibleAmount += amount;
      if (row.payment_status === 'paid') paidAmount += Number(row.paid_amount) || 0;
    });

    const pending = PENDING_STAGES.reduce((sum, stage) => sum + stages[stage], 0);
    return {
      total: list.length,
      done: stages.DONE,
      pending,
      stages,
      invoices,
      payments,
      amountBeforeAudit,
      eligibleAmount,
      paidAmount,
      remainingToPay: eligibleAmount,
    };
  }

  /* صفوف التصدير — نفس الحقول لـCSV وExcel حتى لا يختلف الملفان. */
  function buildExportRows(rows) {
    return (rows || []).map((row) => ({
      SubscriberID: text(row.subscriber_id),
      SubscriberName: text(row.subscriber_name),
      Reseller: text(row.reseller),
      Zone: text(row.zone).toUpperCase(),
      FDT: text(row.fdt),
      Remaining: Number(row.remaining) || 0,
      Stage: text(row.stage),
      DueAmount: Number(row.amount) || 0,
      InvoiceStatus: text(row.invoice_status),
      InvoiceAuditDate: text(row.invoice_audited_at).slice(0, 10),
      PaymentStatus: text(row.payment_status),
      PaidAmount: Number(row.paid_amount) || 0,
      PaymentDate: text(row.paid_at).slice(0, 10),
      Period: text(row.period),
    }));
  }

  return {
    ALL_STAGES,
    IMPORT_ALIASES,
    INVOICE_STATUSES,
    PAYMENT_STATUSES,
    PENDING_STAGES,
    STAGE_BY_REMAINING,
    buildExportRows,
    buildImportPreview,
    entitlementKey,
    mapImportRow,
    normalizeInstallationRow,
    parseRemaining,
    resolveInstallationStage,
    summarizeByReseller,
    summarizeEntitlements,
    summarizeInstallationBatch,
  };
});
