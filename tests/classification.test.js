// تصنيف الجِدّة على الخادم.
//
// الادعاء المالي هنا هو NEW. الاختبارات تحرس ألّا يُمنح من مصدرٍ غير مُثبت
// الاكتمال، وأن التصنيف يبقى مُدخَلاً للقرار لا قراراً مالياً بذاته.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');

const migration = read('supabase/migrations/20260904090000_server_side_classification.sql');
const panel = read('src/features/installation/classification.ts');
const cases = JSON.parse(read('tests/fixtures/newness-cases.json'));

test('الحالات تغطّي كل فرعٍ في القاعدة', () => {
  const reasons = new Set(cases.cases.map((c) => c.expect.reason_code));
  for (const r of [
    'REGISTRY_PREEXISTING', 'IDENTITY_CONFLICT', 'LIFETIME_COUNT_EXCEEDS_OBSERVED',
    'CANCELED_ONLY_HISTORY', 'NO_QUALIFYING_PAID_EVENT',
    'COMPLETE_LIFETIME_HISTORY_OBSERVED', 'PARTIAL_SOURCE', 'UNKNOWN_SOURCE_COMPLETENESS',
  ]) {
    assert.ok(reasons.has(r), `فرعٌ بلا حالة: ${r}`);
  }
});

test('الجانبان يقرآن المصدر نفسه', () => {
  const js = read('tests/sql/newness-parity-js.js');
  const sql = read('tests/sql/newness-parity-sql.js');
  for (const f of [js, sql]) {
    assert.match(f, /newness-cases\.json/, 'جانبٌ لا يقرأ ملف الحالات المشترك');
  }
  // وجانب المتصفّح يستدعي الدالة الحقيقية لا نسخةً منها.
  assert.match(js, /require\(path\.join\(root, 'assets', 'js', 'saas-import\.js'\)\)/);
  assert.match(js, /classifyNewness/);
  // وجانب الخادم يستدعي الدالة الحقيقية أيضاً.
  assert.match(sql, /public\.classify_newness/);
});

test('ترتيب القواعد في SQL هو ترتيبها في JS', () => {
  const order = [
    'REGISTRY_PREEXISTING',
    'IDENTITY_CONFLICT',
    'LIFETIME_COUNT_EXCEEDS_OBSERVED',
    'CANCELED_ONLY_HISTORY',
    'COMPLETE_LIFETIME_HISTORY_OBSERVED',
  ];
  const at = order.map((r) => migration.indexOf(r));
  assert.ok(at.every((i) => i > -1), 'سببٌ مفقود من المهاجرة');
  for (let i = 1; i < at.length; i += 1) {
    assert.ok(at[i] > at[i - 1], `الترتيب مكسور عند ${order[i]}`);
  }
});

test('NEW لا يُمنح إلا من مصدرٍ مكتمل', () => {
  assert.match(migration, /when coalesce\(v_complete, 'UNKNOWN'\) = 'COMPLETE'/);
  assert.match(migration, /and v_lifetime > 0 and v_lifetime = v_observed then/);
  // والقاعدة نفسها مسنودة بقيدٍ في الجدول لا بالشيفرة وحدها.
  const js = read('assets/js/saas-import.js');
  assert.match(js, /completeness === 'COMPLETE' && lifetime > 0 && lifetime === observed/);
});

test('اكتمال المصدر يؤخذ من أضعف دفعة ساهمت', () => {
  // دفعةٌ ناقصة تكفي لإسقاط الادعاء ولو كانت الأخرى مكتملة.
  assert.match(migration, /when bool_or\(b\.completeness_status = 'UNKNOWN'\) then 'UNKNOWN'/);
  assert.match(migration, /when bool_or\(b\.completeness_status = 'PARTIAL'\) then 'PARTIAL'/);
});

test('التثبيت لا يُنشئ استحقاقاً ولا يمسّ مالاً', () => {
  const body = migration.replace(/--.*$/gm, '');
  for (const forbidden of [
    /insert\s+into\s+public\.installation_entitlements/i,
    /update\s+public\.installation_entitlements/i,
    /insert\s+into\s+public\.installation_payment_history/i,
    /update\s+public\.commission_/i,
  ]) {
    assert.doesNotMatch(body, forbidden, 'التصنيف يكتب في جدول مالي');
  }
  // الكتابة الوحيدة هي جدول التصنيف نفسه.
  const writes = [...body.matchAll(/insert\s+into\s+(public\.\w+)/gi)].map((m) => m[1]);
  assert.deepEqual([...new Set(writes)], ['public.subscriber_classifications']);
});

test('التثبيت محروس ومُعاد التشغيل بلا تكرار', () => {
  assert.match(migration, /require_capability\('saas\.review'\)/);
  assert.match(migration, /create unique index if not exists subscriber_classifications_username_uidx/);
  assert.match(migration, /on conflict \(username_key\) do update set/);
  assert.match(migration, /revoke execute on function public\.refresh_subscriber_classifications/);
});

test('الشاشة تعرض الأسباب لا الأعداد وحدها', () => {
  assert.match(panel, /REASON_AR/);
  assert.match(panel, /عدّاد العمر يتجاوز ما رُصد/);
  assert.match(panel, /اكتمال المصدر غير مُثبت/);
  // وتقول لماذا قد يكون NEW صفراً بدل أن يُقرأ عطلاً.
  assert.match(panel, /الجِدّة لا تُمنح من مصدرٍ غير مُثبت الاكتمال/);
  const inst = read('src/features/installation/index.ts');
  assert.match(inst, /classificationPanel\(classState\)/);
  assert.match(inst, /rpc<Row>\('classification_state', \{\}\)/);
  // ولم يعد في الشاشة اعترافٌ بأن التصنيف لا يُحفَظ.
  assert.doesNotMatch(inst, /التصنيف لا يُحفَظ بعد على الخادم/);
});
