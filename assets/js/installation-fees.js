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

  /* صفوف التصدير — نفس الحقول لـCSV وExcel حتى لا يختلف الملفان.
     تقبل الشكل المدموج المعروض في اللوحة، والشكل الخام للاستحقاق كما يأتي
     من قاعدة البيانات، فلا يتغير التصدير بتغير مصدر الصف. */
  function buildExportRows(rows) {
    const pickField = (row, camel, snake) =>
      row[camel] !== undefined ? row[camel] : row[snake];
    return (rows || []).map((row) => ({
      SubscriberID: text(pickField(row, 'subscriberId', 'subscriber_id')),
      SubscriberName: text(pickField(row, 'subscriberName', 'subscriber_name')),
      Reseller: text(row.reseller),
      Zone: text(row.zone).toUpperCase(),
      FDT: text(row.fdt),
      Remaining: Number(row.remaining) || 0,
      Stage: text(row.stage),
      Resolution: text(row.resolution),
      PaymentEligible: row.paymentEligible === true ? 'yes' : 'no',
      Warnings: Array.isArray(row.warnings) ? row.warnings.join(' ') : '',
      HistoricalPayments: Number(row.historicalPayments) || 0,
      AsOfDate: text(pickField(row, 'asOfDate', 'as_of_date')).slice(0, 10),
      DueAmount: Number(row.amount) || 0,
      InvoiceStatus: text(pickField(row, 'invoiceStatus', 'invoice_status')),
      InvoiceAuditDate: text(pickField(row, 'invoiceAuditedAt', 'invoice_audited_at')).slice(0, 10),
      PaymentStatus: text(pickField(row, 'paymentStatus', 'payment_status')),
      PaidAmount: Number(pickField(row, 'paidAmount', 'paid_amount')) || 0,
      PaymentDate: text(pickField(row, 'paidAt', 'paid_at')).slice(0, 10),
      Period: text(row.period),
    }));
  }

  /* ---------------------------------------------------------------------
     الاستيراد التاريخي الابتدائي.

     ملف المتابعة يحمل لكل مشترك أربع دفعات بتواريخها، لا الاستحقاق الحالي
     وحده. الفرق الجوهري عن mapImportRow أعلاه: هناك الـstage هو كامل
     المعلومة، وهنا الـstage حالة حاضرة مشتقة من المتبقي بينما الدفعات
     السابقة وقائع مستقلة يجب حفظها كما هي.

     Stage تعني "الدفعة التالية"، ولا تعني إطلاقاً أن ما قبلها لم يُدفع.
     --------------------------------------------------------------------- */

  const HISTORY_ALIASES = {
    subscriberId: ['subscriber name', 'subscriber_id', 'subscriber id', 'subscriber', 'اسم المشترك', 'رقم المشترك'],
    startDate: ['start date', 'start_date', 'تاريخ البدء', 'تاريخ التنصيب'],
    fdt: ['fdt', 'cabinet', 'الكابينة'],
    totalAmount: ['total amount', 'total_amount', 'المبلغ الكلي'],
    receivedTotal: ['received total', 'received_total', 'المستلم', 'إجمالي المستلم'],
    remaining: ['remaining', 'المتبقي'],
    notes: ['notes', 'note', 'ملاحظات', 'ملاحظة'],
  };

  /* الدفعة رقم i تُقرأ من PaymentN وDateN. المرحلة هنا رقم الدفعة نفسه،
     وليست مشتقة من المتبقي. */
  const HISTORY_PAYMENT_ALIASES = [1, 2, 3, 4].map((i) => ({
    stage: `P${i}`,
    amount: [`payment${i}`, `payment ${i}`, `payment_${i}`, `الدفعة ${i}`],
    date: [`date${i}`, `date ${i}`, `date_${i}`, `تاريخ ${i}`],
  }));

  /* المبلغ المتوقع لكل دفعة حسب ترتيبها. للتحقق فقط،
     ولا يُستنتج منه مبلغ غير موجود في الملف. */
  const HISTORY_STAGE_AMOUNT = new Map([['P1', 3000], ['P2', 3000], ['P3', 3000], ['P4', 4000]]);

  function normalizedCells(row) {
    const map = new Map();
    Object.keys(row || {}).forEach((key) => {
      map.set(String(key).trim().toLowerCase().replace(/\s+/g, ' '), row[key]);
    });
    return map;
  }

  function pick(cells, aliases) {
    for (const alias of aliases) {
      if (cells.has(alias)) return cells.get(alias);
      const squashed = alias.replace(/\s+/g, '');
      for (const [key, value] of cells) {
        if (key.replace(/\s+/g, '') === squashed) return value;
      }
    }
    return null;
  }

  function historyInteger(value) {
    if (value === null || value === undefined) return null;
    const raw = String(value).trim();
    if (raw === '') return null;
    const cleaned = raw.replace(/[,\s]/g, '');
    if (!/^-?\d+$/.test(cleaned)) return null;
    return Number(cleaned);
  }

  /* التواريخ تصل إما ككائن Date من SheetJS أو كنص. لا نخترع تاريخاً أبداً:
     غياب التاريخ يُحفظ كغياب. */
  function historyDate(value) {
    if (value === null || value === undefined) return null;
    if (value instanceof Date && !Number.isNaN(value.getTime())) {
      const y = value.getFullYear();
      const m = String(value.getMonth() + 1).padStart(2, '0');
      const d = String(value.getDate()).padStart(2, '0');
      return `${y}-${m}-${d}`;
    }
    const raw = String(value).trim();
    if (raw === '') return null;
    const iso = raw.match(/^(\d{4})-(\d{2})-(\d{2})/);
    if (iso) return `${iso[1]}-${iso[2]}-${iso[3]}`;
    const parsed = new Date(raw);
    if (Number.isNaN(parsed.getTime())) return null;
    return historyDate(parsed);
  }

  /* هوية المشترك. الملف الحقيقي يعطي معرّفات فريدة عالمياً عبر كل الشيتات،
     فالمفتاح هو المعرّف وحده: هذا يجعل انتقال المشترك بين وكيلين تحديثاً
     لسجله لا نسخة ثانية منه. الوكيل يُحفظ ويُراقب تغيّره بدل أن يكون جزءاً
     من الهوية. */
  function subscriberKey(subscriberId) {
    return text(subscriberId).toLowerCase();
  }

  /* مفتاح الدفعة التاريخية. المشترك لا يملك أكثر من دفعة واحدة لكل مرحلة،
     فالمفتاح (المشترك، المرحلة) أقوى من (المشترك، المرحلة، التاريخ، المبلغ):
     إعادة الرفع بتاريخ مصحّح تحدّث الدفعة بدل أن تنشئ ثانية. */
  function historyPaymentKey(subscriberId, stage) {
    return `${subscriberKey(subscriberId)}${text(stage)}`;
  }

  /* يحوّل صفاً من شيت وكيل إلى سجل مشترك + وقائع دفع.
     يعيد null للصفوف التي لا تحمل مشتركاً فعلياً — صفوف القالب الفارغة. */
  function parseHistoryRow(row, options) {
    const settings = options || {};
    const cells = normalizedCells(row);
    const subscriberId = text(pick(cells, HISTORY_ALIASES.subscriberId));
    if (!subscriberId) return null;

    const remaining = historyInteger(pick(cells, HISTORY_ALIASES.remaining));
    const receivedTotal = historyInteger(pick(cells, HISTORY_ALIASES.receivedTotal));
    const totalAmount = historyInteger(pick(cells, HISTORY_ALIASES.totalAmount));

    const payments = [];
    HISTORY_PAYMENT_ALIASES.forEach((spec) => {
      const amount = historyInteger(pick(cells, spec.amount));
      /* لا تُنشأ واقعة دفع من خانة فارغة أو صفرية. */
      if (amount === null || amount <= 0) return;
      payments.push({
        stage: spec.stage,
        amount,
        paymentDate: historyDate(pick(cells, spec.date)),
      });
    });

    /* المرحلة تُشتق من المتبقي وحده. اشتقاقها لا يعني أنها نهائية:
       النهائية تقررها المطابقة المحاسبية أدناه. */
    const stageKnown = remaining !== null && STAGE_BY_REMAINING.has(remaining);
    const currentStage = stageKnown ? STAGE_BY_REMAINING.get(remaining).stage : null;

    const warnings = [];
    if (!stageKnown) warnings.push(remaining === null ? 'remaining_missing' : 'remaining_unmapped');

    const paidSum = payments.reduce((sum, payment) => sum + payment.amount, 0);
    if (receivedTotal !== null && payments.length && paidSum !== receivedTotal) {
      warnings.push('received_total_mismatch');
    }

    /* الاختلال المحاسبي: المبلغ الكلي ناقص المستلم لا يساوي المتبقي.
       القيم الخام تُحفظ كما هي ولا تُصحَّح، لكن الصف يخرج من دائرة الثقة. */
    const financialMismatch = totalAmount !== null && receivedTotal !== null && remaining !== null
      && totalAmount - receivedTotal !== remaining;
    if (financialMismatch) warnings.push('remaining_mismatch');

    payments.forEach((payment) => {
      if (!payment.paymentDate) warnings.push(`payment_date_missing:${payment.stage}`);
    });

    /* حالة مكتملة بلا دفعة رابعة مسجّلة. لا تُخترع P4: يُعلَّم النقص فقط.
       إن كانت الأرقام متطابقة محاسبياً تبقى الحالة محسومة، وإلا فقاعدة
       الاختلال أعلاه هي التي تحكم. */
    const historyIncomplete = currentStage === 'DONE'
      && !payments.some((payment) => payment.stage === 'P4');
    if (historyIncomplete) warnings.push('historical_payment_detail_incomplete');

    const resolution = (stageKnown && !financialMismatch) ? 'resolved' : 'unresolved';

    /* الأهلية للصرف مشتقة، لا مُدخلة: صف غير محسوم لا يصرف مهما بدا،
       وDONE لا يبقى فيه شيء يُصرف. */
    const paymentEligible = resolution === 'resolved'
      && PENDING_STAGES.includes(currentStage);

    return {
      subscriberId,
      subscriberKey: subscriberKey(subscriberId),
      reseller: text(settings.reseller),
      fdt: text(pick(cells, HISTORY_ALIASES.fdt)) || null,
      startDate: historyDate(pick(cells, HISTORY_ALIASES.startDate)),
      totalAmount,
      receivedTotal,
      remaining,
      currentStage,
      stageIsFinal: resolution === 'resolved',
      resolution,
      financialMismatch,
      historyIncomplete,
      paymentEligible,
      notes: text(pick(cells, HISTORY_ALIASES.notes)) || null,
      payments,
      paidSum,
      warnings,
    };
  }

  /* معاينة الاستيراد التاريخي عبر كل شيتات الوكلاء.
     `sheets` مصفوفة { reseller, rows }. `known` خريطة اختيارية للحالة
     المخزّنة حالياً، تُستعمل للتمييز بين مشترك جديد ومشترك يُحدَّث. */
  function buildHistoricalPreview(sheets, options) {
    const settings = options || {};
    const known = settings.known instanceof Map ? settings.known : new Map();
    const asOfDate = historyDate(settings.asOfDate);

    const subscribers = new Map();
    const perReseller = new Map();
    const stages = { P1: 0, P2: 0, P3: 0, P4: 0, DONE: 0 };
    const paymentsByStage = { P1: 0, P2: 0, P3: 0, P4: 0 };
    const warningRows = [];
    const duplicates = [];
    let totalRows = 0;
    let ignoredRows = 0;
    let resolved = 0;
    let unresolved = 0;
    let financialMismatches = 0;
    let incompleteHistories = 0;
    let eligible = 0;
    let blocked = 0;
    let newSubscribers = 0;
    let existingUpdated = 0;
    let resellerChanged = 0;
    let newPayments = 0;
    let duplicatePayments = 0;

    (sheets || []).forEach((sheet) => {
      const reseller = text(sheet && sheet.reseller);
      const rows = (sheet && sheet.rows) || [];
      const bucket = perReseller.get(reseller) || {
        reseller, real: 0, ignored: 0, resolved: 0, unresolved: 0,
        financialMismatches: 0, incompleteHistories: 0, eligible: 0, blocked: 0,
        stages: { P1: 0, P2: 0, P3: 0, P4: 0, DONE: 0 },
        payments: { P1: 0, P2: 0, P3: 0, P4: 0 },
        warnings: 0,
      };

      rows.forEach((raw, index) => {
        totalRows += 1;
        const parsed = parseHistoryRow(raw, { reseller });
        if (!parsed) { ignoredRows += 1; bucket.ignored += 1; return; }

        /* نفس المعرّف مرتين داخل الرفعة نفسها: يُحتسب مرة واحدة ويُبلَّغ عنه. */
        if (subscribers.has(parsed.subscriberKey)) {
          duplicates.push({ subscriberKey: parsed.subscriberKey, reseller, row: index + 2 });
          return;
        }

        bucket.real += 1;
        subscribers.set(parsed.subscriberKey, parsed);

        /* المرحلة تُعدّ حيثما اشتُقت، حتى لو كان الصف غير محسوم — فالعدّ
           وصف لما في الملف. الحسم والأهلية يُعدّان منفصلين حتى لا يختلط
           "أين يقف" بـ"هل يُصرف". */
        if (parsed.currentStage) {
          stages[parsed.currentStage] += 1;
          bucket.stages[parsed.currentStage] += 1;
        }
        if (parsed.resolution === 'resolved') {
          resolved += 1;
          bucket.resolved += 1;
        } else {
          unresolved += 1;
          bucket.unresolved += 1;
        }
        if (parsed.financialMismatch) { financialMismatches += 1; bucket.financialMismatches += 1; }
        if (parsed.historyIncomplete) { incompleteHistories += 1; bucket.incompleteHistories += 1; }
        if (parsed.paymentEligible) { eligible += 1; bucket.eligible += 1; }
        else { blocked += 1; bucket.blocked += 1; }

        parsed.payments.forEach((payment) => {
          paymentsByStage[payment.stage] += 1;
          bucket.payments[payment.stage] += 1;
        });

        const prior = known.get(parsed.subscriberKey);
        if (!prior) {
          newSubscribers += 1;
          newPayments += parsed.payments.length;
        } else {
          existingUpdated += 1;
          if (prior.reseller && text(prior.reseller) !== parsed.reseller) resellerChanged += 1;
          const seen = new Set(prior.paymentStages || []);
          parsed.payments.forEach((payment) => {
            if (seen.has(payment.stage)) duplicatePayments += 1;
            else newPayments += 1;
          });
        }

        if (parsed.warnings.length) {
          bucket.warnings += 1;
          warningRows.push({
            subscriberKey: parsed.subscriberKey,
            reseller,
            row: index + 2,
            warnings: parsed.warnings.slice(),
            remaining: parsed.remaining,
            receivedTotal: parsed.receivedTotal,
            totalAmount: parsed.totalAmount,
            paidSum: parsed.paidSum,
          });
        }
      });

      perReseller.set(reseller, bucket);
    });

    const historicalPayments = paymentsByStage.P1 + paymentsByStage.P2
      + paymentsByStage.P3 + paymentsByStage.P4;

    return {
      asOfDate: asOfDate || null,
      asOfDateProvided: Boolean(asOfDate),
      totalRows,
      ignoredRows,
      realSubscribers: subscribers.size,
      stages,
      resolved,
      unresolved,
      financialMismatches,
      incompleteHistories,
      eligible,
      blocked,
      paymentsByStage,
      historicalPayments,
      newSubscribers,
      existingUpdated,
      resellerChanged,
      newPayments,
      duplicatePayments,
      duplicates,
      warnings: warningRows,
      warningCount: warningRows.length,
      perReseller: Array.from(perReseller.values()),
      rows: Array.from(subscribers.values()),
    };
  }

  /* الشكل الذي يُرسل إلى RPC الاستيراد التاريخي. المراحل والمبالغ تُشتق
     مجدداً على الخادم؛ ما يُرسل هنا هو ما قُرئ من الملف فقط. */
  function buildHistoricalImportRows(preview) {
    return (preview && preview.rows ? preview.rows : []).map((row) => ({
      subscriber_id: row.subscriberId,
      reseller: row.reseller,
      fdt: row.fdt,
      start_date: row.startDate,
      total_amount: row.totalAmount,
      received_total: row.receivedTotal,
      remaining: row.remaining,
      notes: row.notes,
      warnings: row.warnings,
      payments: row.payments.map((payment) => ({
        stage: payment.stage,
        amount: payment.amount,
        payment_date: payment.paymentDate,
      })),
    }));
  }

  /* ---------------------------------------------------------------------
     خط الأساس مقابل الاستحقاق التشغيلي.

     مصدران مختلفان لا يلغي أحدهما الآخر:

       installation_subscriber_state  الحالة الحالية لكل مشترك وتاريخه.
                                      هذه هي حقيقة "أين يقف كل مشترك الآن".
       installation_entitlements      الاستحقاق التشغيلي: الفاتورة والصرف.
                                      تُنشأ عند تجهيز دفعة صرف، وقد لا توجد.

     اللوحة كانت تقرأ الثاني وحده، فعرضت أصفاراً لأن لا استحقاقات تشغيلية
     بعد، بينما خط الأساس يحمل آلاف المشتركين. الصف المعروض يجمع الاثنين:
     الحالة من خط الأساس دائماً، وأعمدة الفاتورة والصرف حين يوجد استحقاق.
     --------------------------------------------------------------------- */

  /* PostgREST يعيد العلاقة المضمّنة إما ككائن أو كمصفوفة بعنصر واحد. */
  function embedded(value) {
    if (Array.isArray(value)) return value[0] || null;
    return value || null;
  }

  /* يسطّح سجل مشترك قادماً من قاعدة البيانات إلى شكل واحد تستهلكه اللوحة. */
  function normalizeSubscriberRecord(row) {
    const record = row || {};
    const state = embedded(record.installation_subscriber_state) || {};
    const history = record.installation_payment_history || [];
    return {
      subscriberId: text(record.subscriber_id),
      reseller: text(record.reseller),
      fdt: record.fdt === null || record.fdt === undefined ? null : text(record.fdt),
      startDate: text(record.start_date) || null,
      asOfDate: text(state.as_of_date) || null,
      remaining: state.remaining === null || state.remaining === undefined
        ? null : Number(state.remaining),
      currentStage: text(state.current_stage) || null,
      resolution: text(state.resolution) || 'resolved',
      /* الأهلية تُقرأ كما خزّنها الخادم ولا تُشتق هنا مطلقاً. */
      paymentEligible: state.payment_eligible === true,
      warnings: Array.isArray(state.warnings) ? state.warnings.slice() : [],
      payments: history.map((payment) => ({
        stage: text(payment.stage),
        amount: Number(payment.amount) || 0,
        paymentDate: text(payment.payment_date) || null,
      })),
    };
  }

  /* عدّادات اللوحة من خط الأساس. المرحلة تُعدّ حيثما اشتُقت، والأهلية
     تُعدّ من القيمة المخزّنة، فلا يختلط "أين يقف" بـ"هل يجوز الصرف".

     تقبل الشكلين: السجل المطبَّع القادم من normalizeSubscriberRecord،
     والصف المدموج المعروض في اللوحة بعد التصفية. بدون ذلك تُعدّ الكروت
     أصفاراً حين تُمرَّر إليها الصفوف المصفّاة. */
  function stateStage(record) {
    return record.currentStage !== undefined ? record.currentStage : (record.stage || null);
  }

  function statePaymentCount(record) {
    if (Array.isArray(record.payments)) return record.payments.length;
    return Number(record.historicalPayments) || 0;
  }

  function summarizeSubscriberStates(records) {
    const summary = {
      total: 0,
      stages: { P1: 0, P2: 0, P3: 0, P4: 0, DONE: 0 },
      noStage: 0,
      resolved: 0,
      unresolved: 0,
      eligible: 0,
      blocked: 0,
      historicalPayments: 0,
      paymentsByStage: { P1: 0, P2: 0, P3: 0, P4: 0 },
      warnings: {},
      resellers: 0,
    };
    const resellers = new Set();

    (records || []).forEach((record) => {
      summary.total += 1;
      if (record.reseller) resellers.add(record.reseller);

      const stage = stateStage(record);
      if (stage && summary.stages[stage] !== undefined) summary.stages[stage] += 1;
      else summary.noStage += 1;

      if (record.resolution === 'unresolved') summary.unresolved += 1;
      else summary.resolved += 1;

      if (record.paymentEligible) summary.eligible += 1;
      else summary.blocked += 1;

      summary.historicalPayments += statePaymentCount(record);
      (record.payments || []).forEach((payment) => {
        if (summary.paymentsByStage[payment.stage] !== undefined) {
          summary.paymentsByStage[payment.stage] += 1;
        }
      });

      (record.warnings || []).forEach((warning) => {
        const kind = String(warning).split(':')[0];
        summary.warnings[kind] = (summary.warnings[kind] || 0) + 1;
      });
    });

    summary.resellers = resellers.size;
    return summary;
  }

  /* يدمج خط الأساس مع الاستحقاقات التشغيلية بمفتاح المشترك.
     كل مشترك في خط الأساس يظهر؛ ومن له استحقاق يحمل أعمدة الفاتورة والصرف
     ومعرّف الاستحقاق الذي تعمل عليه أزرار التدقيق والصرف. */
  function buildInstallationDashboardRows(records, entitlements) {
    const bySubscriber = new Map();
    (entitlements || []).forEach((entitlement) => {
      const key = text(entitlement.subscriber_id).toLowerCase();
      if (!key) return;
      /* أحدث فترة تمثّل الاستحقاق القائم لهذا المشترك. */
      const current = bySubscriber.get(key);
      if (!current || text(entitlement.period) > text(current.period)) {
        bySubscriber.set(key, entitlement);
      }
    });

    const seen = new Set();
    const rows = (records || []).map((record) => {
      const key = record.subscriberId.toLowerCase();
      seen.add(key);
      const entitlement = bySubscriber.get(key) || null;
      return {
        source: entitlement ? 'baseline+entitlement' : 'baseline',
        entitlementId: entitlement ? entitlement.id : null,
        subscriberId: record.subscriberId,
        subscriberName: entitlement ? text(entitlement.subscriber_name) : '',
        reseller: record.reseller,
        zone: entitlement ? text(entitlement.zone) : '',
        fdt: record.fdt,
        startDate: record.startDate,
        asOfDate: record.asOfDate,
        remaining: record.remaining,
        stage: record.currentStage,
        resolution: record.resolution,
        paymentEligible: record.paymentEligible,
        warnings: record.warnings,
        historicalPayments: record.payments.length,
        period: entitlement ? text(entitlement.period) : '',
        amount: entitlement ? Number(entitlement.amount) || 0 : null,
        invoiceStatus: entitlement ? text(entitlement.invoice_status) : null,
        invoiceNote: entitlement ? text(entitlement.invoice_note) : '',
        paymentStatus: entitlement ? text(entitlement.payment_status) : null,
        paidAmount: entitlement ? Number(entitlement.paid_amount) || 0 : 0,
        paidAt: entitlement ? text(entitlement.paid_at) : '',
      };
    });

    /* استحقاق بلا مشترك في خط الأساس يبقى ظاهراً بدل أن يختفي بصمت. */
    (entitlements || []).forEach((entitlement) => {
      const key = text(entitlement.subscriber_id).toLowerCase();
      if (!key || seen.has(key)) return;
      seen.add(key);
      rows.push({
        source: 'entitlement',
        entitlementId: entitlement.id,
        subscriberId: text(entitlement.subscriber_id),
        subscriberName: text(entitlement.subscriber_name),
        reseller: text(entitlement.reseller),
        zone: text(entitlement.zone),
        fdt: entitlement.fdt === null || entitlement.fdt === undefined ? null : text(entitlement.fdt),
        startDate: null,
        asOfDate: null,
        remaining: entitlement.remaining === null || entitlement.remaining === undefined
          ? null : Number(entitlement.remaining),
        stage: text(entitlement.stage) || null,
        resolution: 'resolved',
        paymentEligible: text(entitlement.payment_status) === 'eligible',
        warnings: [],
        historicalPayments: 0,
        period: text(entitlement.period),
        amount: Number(entitlement.amount) || 0,
        invoiceStatus: text(entitlement.invoice_status),
        invoiceNote: text(entitlement.invoice_note),
        paymentStatus: text(entitlement.payment_status),
        paidAmount: Number(entitlement.paid_amount) || 0,
        paidAt: text(entitlement.paid_at),
      });
    });

    return rows;
  }

  return {
    ALL_STAGES,
    HISTORY_ALIASES,
    HISTORY_STAGE_AMOUNT,
    IMPORT_ALIASES,
    INVOICE_STATUSES,
    PAYMENT_STATUSES,
    PENDING_STAGES,
    STAGE_BY_REMAINING,
    buildExportRows,
    buildHistoricalImportRows,
    buildHistoricalPreview,
    buildImportPreview,
    buildInstallationDashboardRows,
    entitlementKey,
    historyPaymentKey,
    mapImportRow,
    normalizeInstallationRow,
    normalizeSubscriberRecord,
    parseHistoryRow,
    parseRemaining,
    resolveInstallationStage,
    subscriberKey,
    summarizeByReseller,
    summarizeEntitlements,
    summarizeInstallationBatch,
    summarizeSubscriberStates,
  };
});
