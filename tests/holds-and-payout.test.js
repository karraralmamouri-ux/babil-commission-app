// التعليق والصرف.
//
// ثلاثة أعطال مالية تحرسها هذه الاختبارات: تعليقٌ يمسّ التاريخ المدفوع،
// وإنشاءُ دفعةٍ يُقرأ دفعاً، وسطرٌ عُلّق بعد إدراجه فيمرّ لأنه كان مؤهَّلاً
// ساعةَ الإدراج.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');

const holdsUi = read('src/features/installation/holds.ts');
const payoutUi = read('src/features/installation/payout.ts');
const holdsSql = read('supabase/migrations/20260906090000_installation_holds.sql');
const payoutSql = read('supabase/migrations/20260907090000_installation_payout.sql');

/* ---- التعليق: المحاور الثلاثة ------------------------------------------- */

test('الدوام والمصدر محوران مستقلّان عن نوع التعليق', () => {
  assert.match(holdsSql, /permanence text not null default 'PERMANENT'/);
  assert.match(holdsSql, /source\s+text not null default 'INDIVIDUAL'/);
  assert.match(holdsSql, /check \(permanence in \('PERMANENT', 'TEMPORARY'\)\)/);
  assert.match(holdsSql, /check \(source in \('INDIVIDUAL', 'BULK'\)\)/);
  // ولم يُعَد تعريف hold_type: SYSTEM/MANUAL محورٌ آخر.
  assert.doesNotMatch(holdsSql, /drop constraint[^;]*installation_holds_type_check/);
});

test('المؤقّت بلا أجل ليس مؤقّتاً، والدائم بأجل ليس دائماً', () => {
  assert.match(holdsSql, /check \(\(permanence = 'TEMPORARY' and expires_at is not null\)/);
  assert.match(holdsSql, /or \(permanence = 'PERMANENT' and expires_at is null\)\)/);
  assert.match(holdsSql, /A temporary hold needs an end date/);
  assert.match(holdsSql, /A permanent hold cannot carry an end date/);
  assert.match(holdsSql, /A temporary hold cannot end in the past/);
});

test('الانقضاء يُفحص وقت القراءة لا بمهمّة تكنس', () => {
  assert.match(holdsSql, /create or replace function public\.hold_is_effective/);
  assert.match(holdsSql, /p_permanence <> 'TEMPORARY' or p_expires_at > now\(\)/);
  // والأهلية تستعمله بدل فحص الحالة وحدها.
  assert.match(holdsSql, /and public\.hold_is_effective\(h\.status, h\.permanence, h\.expires_at\)/);
  assert.match(holdsSql, /v_blockers := v_blockers \|\| 'ON_HOLD'::text;/);
});

test('التعليق لا يمسّ التاريخ المدفوع', () => {
  const body = holdsSql.replace(/--.*$/gm, '');
  for (const forbidden of [
    /delete\s+from\s+public\.installation_payment_history/i,
    /update\s+public\.installation_payment_history/i,
    /update\s+public\.installation_entitlements/i,
    /delete\s+from\s+public\.financial_ledger/i,
    /update\s+public\.financial_ledger/i,
  ]) {
    assert.doesNotMatch(body, forbidden, 'التعليق يمسّ التاريخ المالي');
  }
});

/* ---- الرفع بالجملة ------------------------------------------------------- */

test('المعاينة تسبق التطبيق، وتفرز كل معرّف في دلوٍ واحد', () => {
  for (const bucket of ['unknown', 'already_held', 'already_done', 'already_paid', 'valid']) {
    assert.ok(holdsSql.includes(`'${bucket}'`), `دلو مفقود: ${bucket}`);
  }
  assert.match(holdsSql, /'duplicate', \(select coalesce\(sum\(times - 1\), 0\) from first_seen\)/);
  // والمعاينة قراءةٌ محضة.
  const preview = holdsSql.slice(holdsSql.indexOf('function public.preview_bulk_hold'),
                                 holdsSql.indexOf('function public.apply_bulk_hold'));
  assert.match(preview, /\bstable\b/);
  assert.doesNotMatch(preview.replace(/--.*$/gm, ''), /insert\s+into/i);
});

test('التطبيق يُعلّق ما يستحق وحده، ويحفظ اسم الملف', () => {
  assert.match(holdsSql, /coalesce\(st\.remaining, 0\) > 0/);
  assert.match(holdsSql, /not exists \(\s*select 1 from public\.installation_holds h/);
  assert.match(holdsSql, /'BULK', v_upload/);
  assert.match(holdsSql, /The source file must be named/);
  assert.match(holdsSql, /create table if not exists public\.installation_hold_uploads/);
});

test('كل تعليق وكل رفع مُدقَّق ومعرَّف بطلب', () => {
  assert.match(holdsSql, /'installation\.hold\.bulk_applied'/);
  assert.match(holdsSql, /'installation\.hold\.released'/);
  assert.match(holdsSql, /request_id is required/);
  assert.match(holdsSql, /A hold must state its reason/);
  assert.match(holdsSql, /A release must state its reason/);
});

test('رفع الدائم يحتاج إذناً أعلى من وضعه', () => {
  assert.match(holdsSql, /require_capability\('installation\.hold'\)/);
  assert.match(holdsSql, /require_capability\('installation\.release_hold'\)/);
});

/* ---- شاشة التعليق -------------------------------------------------------- */

test('الشاشة تعرض ما تطلبه القاعدة عن كل تعليق', () => {
  for (const label of ['نوع الحجب', 'السبب', 'البداية', 'الانتهاء', 'من علّق', 'المصدر']) {
    assert.ok(holdsUi.includes(label), `عمود مفقود: ${label}`);
  }
  assert.match(holdsUi, /upload_filename/);
  assert.match(holdsUi, /PERMANENCE_AR/);
  assert.match(holdsUi, /SOURCE_AR/);
  // والدائم يُقال إنه لا ينتهي بدل أن يُترك فارغاً.
  assert.match(holdsUi, /لا ينتهي/);
});

test('قارئ الملف يُسقط سطر العنوان ويقبل CSV', () => {
  const src = holdsUi.slice(holdsUi.indexOf('function parseIds'));
  const compiled = ts.transpileModule(
    src.slice(0, src.indexOf('function wireBulkHold')), { compilerOptions: { target: 'ES2022' } });
  const ctx = { module: { exports: {} } };
  vm.createContext(ctx);
  vm.runInContext(compiled.outputText + '\nmodule.exports = { parseIds };', ctx);
  // النتيجة تُنسَخ إلى مصفوفة هذا السياق: القيم هي المقصودة لا النموذج.
  const raw = ctx.module.exports.parseIds;
  const parseIds = (t) => [...raw(t)];

  assert.deepEqual(parseIds('Subscriber ID\na-1\na-2'), ['a-1', 'a-2']);
  assert.deepEqual(parseIds('a-1,3000\na-2,4000'), ['a-1', 'a-2']);
  assert.deepEqual(parseIds('a-1\n\n  a-2  \n'), ['a-1', 'a-2']);
  // عمودٌ أوّل عربيّ العنوان يُسقَط أيضاً.
  assert.deepEqual(parseIds('المشترك\nb-1'), ['b-1']);
  // ولا يُسقَط معرّفٌ حقيقي لمجرّد أنه أوّل سطر.
  assert.deepEqual(parseIds('a-1\na-2'), ['a-1', 'a-2']);
});

test('لا يُطبَّق تعليق قبل معاينة، ولا بلا سبب', () => {
  assert.match(holdsUi, /if \(!previewed\.length\)/);
  assert.match(holdsUi, /السبب إلزامي/);
  assert.match(holdsUi, /المؤقّت يحتاج تاريخ انتهاء/);
  assert.match(holdsUi, /p_request_id: crypto\.randomUUID\(\)/);
  // والزرّ لا يُفتح إن لم يكن هناك ما يُطبَّق.
  assert.match(holdsUi, /apply\.disabled = Number\(counts\['valid'\] \|\| 0\) === 0/);
});

/* ---- الصرف --------------------------------------------------------------- */

test('المرشّحون قراءة: لا استحقاق يُنشأ ولا مال يُلتزم به', () => {
  const fn = payoutSql.slice(payoutSql.indexOf('function public.installation_payout_candidates'),
                             payoutSql.indexOf('function public.page_payout_candidate_lines'));
  assert.match(fn, /\bstable\b/);
  assert.doesNotMatch(fn.replace(/--.*$/gm, ''), /insert\s+into/i);
  // والقسط التالي من المتبقّي المسجَّل، لا إعادة بناءٍ لمراحل ماضية.
  assert.match(fn, /st\.current_stage as stage/);
  assert.match(fn, /public\.installation_amount_for_stage\(st\.current_stage\)/);
  assert.match(fn, /coalesce\(st\.remaining, 0\) > 0/);
});

test('التجميع بالوكيل يحمل ما تطلبه الشاشة', () => {
  for (const key of ['p1', 'p2', 'p3', 'p4', 'held', 'ready', 'subscribers', 'amount']) {
    assert.ok(payoutSql.includes(`as ${key}`) || payoutSql.includes(`'${key}'`),
      `حقل مفقود في التجميع: ${key}`);
  }
  // الأعمدة صارت تفصّل الحجب بدل عمود «محجوب» واحد.
  for (const label of ['الوكيل', 'المرشّحون', 'محجوب — تعليق', 'محجوب — فاتورة',
    'محجوب — أهلية', 'محجوب — أخرى', 'جاهز', 'المبلغ الجاهز']) {
    assert.ok(payoutUi.includes(label), `عمود مفقود: ${label}`);
  }
});

test('السطر وحدة التخزين: مشترك ومرحلة ومبلغ', () => {
  assert.match(payoutUi, /سطرٌ لكل مشترك ومرحلة/);
  for (const label of ['المشترك', 'المرحلة', 'المبلغ', 'الفاتورة', 'التعليق', 'الأهلية']) {
    assert.ok(payoutUi.includes(label), `عمود مفقود في السطور: ${label}`);
  }
});

test('الشاشة تقول «مرشّح» لا «مستحقّ»', () => {
  assert.match(payoutUi, /مرشّح لا مستحقّ/);
  assert.match(payoutUi, /ولا تُدفع إلا بتأكيدٍ/);
});

/* ---- الدفعة والتأكيد ----------------------------------------------------- */

test('حالات الدفعة هي المعتمدة، ولا اسمان لحالةٍ واحدة', () => {
  assert.match(payoutSql, /check \(status in \('DRAFT', 'VALIDATED', 'READY', 'PAID', 'CANCELLED'\)\)/);
  assert.match(payoutSql, /drop constraint if exists installation_payment_batches_status_check/);
});

test('إنشاء الدفعة ليس دفعاً', () => {
  assert.match(payoutSql, /check \(status <> 'PAID'/);
  assert.match(payoutSql, /payment_date is not null/);
  assert.match(payoutSql, /btrim\(coalesce\(payment_ref, ''\)\) <> ''/);
  assert.match(payoutSql, /A payment needs its date/);
  assert.match(payoutSql, /A payment needs an external reference/);
});

test('التأكيد يُعيد الفحص في معاملته ويرفض المحجوب', () => {
  assert.match(payoutSql, /v_check := public\.revalidate_installation_batch\(p_batch_id\)/);
  assert.match(payoutSql, /blocked line\(s\); they must be resolved or removed/);
  assert.match(payoutSql, /A % batch cannot be paid; validate it first/);
});

test('التعريف المشترك يمنع خلاف الشاشة والترحيل', () => {
  assert.match(payoutSql, /create or replace function public\.installation_line_payable/);
  assert.match(payoutSql, /b <> 'NOT_ENROLLED'/);
  assert.match(payoutSql, /v_eval := public\.installation_line_payable\(v_item\.entitlement_id\)/);
});

test('الترحيل يمرّ بمسار الدفع القائم لا بنسخةٍ منه', () => {
  assert.match(payoutSql, /perform public\.record_installation_payment\(/);
  // ومعرّف الطلب مشتقّ، فإعادة التأكيد لا تدفع مرّتين.
  assert.match(payoutSql, /public\.uuid_from_parts\(p_request_id, v_item\.id\)/);
  assert.match(payoutSql, /\bimmutable\b/);
});

test('لا صفّ ماليّ يُكتب ثم يُرقَّع', () => {
  const body = payoutSql.replace(/--.*$/gm, '');
  assert.doesNotMatch(body, /update\s+public\.installation_payments/i);
  assert.doesNotMatch(body, /update\s+public\.installation_entitlements/i);
  assert.doesNotMatch(body, /update\s+public\.financial_ledger/i);
  assert.doesNotMatch(body, /delete\s+from\s+public\.installation_payment_history/i);
});

test('حالات السطر يقرّرها الخادم', () => {
  for (const state of ['PAID', 'BLOCKED', 'IN_BATCH', 'READY']) {
    assert.ok(payoutSql.includes(`'state', '${state}'`), `حالة مفقودة: ${state}`);
  }
  assert.match(payoutSql, /require_capability\('payment\.execute'\)/);
  assert.match(payoutSql, /require_capability\('payment\.prepare'\)/);
});

test('المسارات مسجّلة، ولا نمط مسارٍ مكرّر', () => {
  const inst = read('src/features/installation/index.ts');
  assert.match(inst, /routes as holdRoutes/);
  assert.match(inst, /routes as payoutRoutes/);
  // الشاشتان القديمتان أُزيلتا بدل أن تتعايشا مع بديلَيهما.
  assert.doesNotMatch(inst, /export const ready = queueScreen/);
  assert.doesNotMatch(inst, /export const holds: Route/);

  const patterns = [
    ...inst.matchAll(/pattern: '([^']+)'/g),
    ...holdsUi.matchAll(/pattern: '([^']+)'/g),
    ...payoutUi.matchAll(/pattern: '([^']+)'/g),
  ].map((m) => m[1]);
  assert.equal(new Set(patterns).size, patterns.length, `نمط مكرّر: ${patterns.join(', ')}`);
});
