// نقل العائدية ومركز العمل.
//
// العقود التي تُكسَر صامتةً هنا ثلاثة: أن يُنقل التنصيب مع العائدية، وأن
// يُكتب نقلٌ داخل دورة محسومة، وأن يُخمَّن جوابُ سؤالٍ تجاري. الاختبارات
// تُثبّت أن الشيفرة تقول الثلاثة صراحةً ولا تفعلها.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');

const transfer = read('src/features/ownership/transfer.ts');
const work = read('src/features/work/index.ts');
const migration = read('supabase/migrations/20260902090000_subscriber_transfer.sql');

test('النقل مؤرَّخ: تاريخ السريان جزء من الطلب لا افتراض', () => {
  assert.match(transfer, /p_effective_from:/);
  assert.match(transfer, /type="date" id="trFrom"/);
  assert.match(migration, /p_effective_from timestamptz default null/);
  // والحدّ الأدنى داخلٌ والأعلى خارج — يُحسم في الطبقة المؤرَّخة القائمة.
  assert.match(migration, /effective_to = v_at/);
});

test('الفترة السابقة تُغلق ولا تُحذف', () => {
  assert.match(migration, /update public\.subscriber_ownership set effective_to = v_at/);
  const body = migration.replace(/--.*$/gm, '');
  assert.doesNotMatch(body, /delete\s+from\s+public\.subscriber_ownership/i);
});

test('لا كتابة داخل دورة محسومة', () => {
  assert.match(migration, /finalized_cycle_at/);
  assert.match(migration, /'FINALIZED', 'PARTIALLY_PAID', 'PAID', 'CLOSED'/);
  assert.match(migration, /Cannot transfer into finalized cycle/);
  // والواجهة تُعلن الحاجب وتُعطّل الزرّ بدل أن تكتشفه بعد الضغط.
  assert.match(transfer, /blocked_by/);
  assert.match(transfer, /\$\{blocked \? ' disabled' : ''\}/);
});

test('أجور التنصيب لا تُنقل مع العائدية', () => {
  const body = migration.replace(/--.*$/gm, '');
  // لا كتابة على تسجيل التنصيب في مسار النقل بحال.
  assert.doesNotMatch(body, /update\s+public\.installation_enrollments/i);
  assert.doesNotMatch(body, /update\s+public\.installation_payment_history/i);
  assert.match(migration, /'installation_moved', false/);
  assert.match(migration, /'moves_with_transfer', false/);
  // والشاشة تقولها للمستخدم لا للمطوّر وحده.
  assert.match(transfer, /لا تنتقل مع العائدية/);
});

test('السؤال التجاري يُعرض ولا يُجاب', () => {
  assert.match(migration, /'code', 'NEEDS_BUSINESS_DECISION'/);
  assert.match(migration, /من يستحق مراحل التنصيب المتبقّية بعد النقل؟/);
  assert.match(transfer, /NEEDS_BUSINESS_DECISION/);
  assert.match(transfer, /النظام لا يختار/);
  // لا قيمة مقترحة ولا اختيار افتراضي في الجواب.
  assert.doesNotMatch(migration, /'suggested_(agent|answer)'/);
});

test('النقل يحتاج سبباً ومعرّف طلب، والتكرار بلا أثر ثانٍ', () => {
  assert.match(migration, /A transfer must state its reason/);
  assert.match(migration, /request_id is required/);
  assert.match(migration, /where request_id = p_request_id/);
  assert.match(transfer, /p_request_id: crypto\.randomUUID\(\)/);
  assert.match(transfer, /النقل يحتاج سبباً مكتوباً/);
});

test('النقل محروس بصلاحية تصحيح العائدية', () => {
  assert.match(migration, /require_capability\('subscriber\.correct_attribution'\)/);
  assert.match(transfer, /can\('subscriber\.correct_attribution'\)/);
  assert.match(migration, /revoke execute on function public\.transfer_subscriber/);
});

test('التصنيف ثلاثي في النقل أيضاً', () => {
  const values = [...transfer.matchAll(/\{ value: '([A-Z_]+)', label:/g)].map((m) => m[1]);
  assert.deepEqual(values.sort(), ['DIRECT_COMPANY', 'NEEDS_REVIEW', 'RESELLER']);
  assert.match(migration, /p_ownership not in \('RESELLER', 'DIRECT_COMPANY', 'NEEDS_REVIEW'\)/);
});

test('اسم الأب يُحمل كما هو ولا يُشتقّ من التصنيف', () => {
  assert.match(migration, /p_company_parent text default null/);
  assert.match(migration, /nullif\(btrim\(coalesce\(p_company_parent, ''\)\), ''\)/);
  assert.match(transfer, /اسم الأب لا يتغيّر/);
});

test('مركز العمل يُجمِّع بوحدة القرار لا بالصفّ', () => {
  assert.match(work, /pattern: '\/work'/);
  assert.match(work, /REASON_UNIT/);
  assert.match(work, /وحدة القرار: الأب/);
  assert.match(work, /تُحسم على مستوى/);
  // ثلاث مجموعات: أب، مشترك، استثناء مجمَّع.
  assert.match(work, /list_parents/);
  assert.match(work, /pending_business_decisions/);
  assert.match(work, /report_commission_exception_impact/);
});

test('مركز العمل يقول إن مبالغه مؤشِّرة', () => {
  assert.match(work, /مؤشِّر/);
  assert.match(work, /لا ما سيُصرف/);
});

test('المسارات الجديدة مسجّلة في المُوجِّه والملاحة', () => {
  const main = read('src/main.ts');
  assert.match(main, /routes as workRoutes/);
  assert.match(main, /\.\.\.workRoutes,/);
  const shell = read('src/app/shell.ts');
  assert.match(shell, /'\/work'/);
  // وتبويب العائدية داخل ملفّ المشترك.
  const inst = read('src/features/installation/index.ts');
  assert.match(inst, /\{ key: 'ownership', label: 'العائدية' \}/);
  assert.match(inst, /wireTransfer\(view, id\.toLowerCase\(\)\.trim\(\)\)/);
});
