// السلسلة: مرشّح ← استحقاق ← دفعة ← دفع.
//
// الخطر المحروس أن تتسرّب حلقةٌ من قبضة ما قبلها: أن يُثبَّت محجوبٌ
// استحقاقاً، أو تُنشأ دفعةٌ من غير مثبَّت، أو يُدفع غير متحقَّق منه.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');

const sql = read('supabase/migrations/20260913090000_materialize_and_batch.sql');
const ui = read('src/features/finance/installation-batches.ts');

test('التثبيت لا يُثبِّت إلا من اجتاز كل الفحوص', () => {
  // الخمسة كلها، لا التعليق وحده.
  assert.match(sql, /status = 'VERIFIED'/);
  assert.match(sql, /hold_is_effective\(h\.status, h\.permanence, h\.expires_at\)/);
  assert.match(sql, /identity_status = 'CONFLICT'/);
  assert.match(sql, /subscriber_ownership_type\(s\.subscriber_id\) = 'RESELLER'/);
  assert.match(sql, /st\.resolution = 'resolved'/);
  assert.match(sql, /st\.payment_eligible/);
});

test('التثبيت التزامٌ لا دفع', () => {
  assert.match(sql, /'approved', 'eligible'/);
  const body = sql.replace(/--.*$/gm, '');
  assert.doesNotMatch(body, /insert\s+into\s+public\.installation_payments/i);
  assert.doesNotMatch(body, /insert\s+into\s+public\.financial_ledger/i);
  assert.doesNotMatch(body, /insert\s+into\s+public\.installation_payment_history/i);
});

test('لا التزام مكرَّر: الحارس على مفتاح الجدول الحقيقي', () => {
  // المفتاح (period, subscriber_id, stage) لا حالة الدفع؛ استثناء غير
  // المدفوع وحده كان يصطدم بالمفتاح حين يكون القائم مدفوعاً.
  assert.match(sql, /where t\.period = p_period/);
  assert.match(sql, /and t\.subscriber_id = s\.subscriber_id/);
  assert.match(sql, /and t\.stage = st\.current_stage\)/);
});

test('إنشاء الدفعة ليس دفعاً', () => {
  assert.match(sql, /values \(btrim\(p_name\), 'DRAFT'/);
  assert.match(ui, /الإنشاء ليس دفعاً/);
  assert.match(ui, /لم يُدفع شيء بعد/);
});

test('الدفعة تضمّ ما يجتاز التعريف المشترك، ولا تُدرِج سطراً مرّتين', () => {
  assert.match(sql, /installation_line_payable\(t\.id\) ->> 'payable'/);
  assert.match(sql, /b\.status in \('DRAFT','VALIDATED','READY','PAID'\)/);
});

test('المدفوعة لا تُلغى: العكس يمرّ بالدفتر', () => {
  assert.match(sql, /A paid batch cannot be cancelled; reverse it in the ledger/);
  assert.match(sql, /require_capability\('payment\.prepare'\)/);
});

test('التأكيد يطلب تاريخاً وإشعاراً، والشاشة تقولهما إلزاميَّين', () => {
  assert.match(ui, /الدفع يحتاج تاريخاً/);
  assert.match(ui, /الدفع يحتاج رقم إشعار خارجي/);
  assert.match(ui, /p_payment_date: date, p_reference: ref/);
});

test('السطر المحجوب يُعطّل التأكيد ويُقال سببه', () => {
  assert.match(ui, /const payable = \['VALIDATED', 'READY'\]\.includes\(status\) && blocked === 0/);
  assert.match(ui, /يُحسم أو يُخرَج قبل الدفع/);
  assert.match(ui, /blocked_reason/);
});

test('رفض الخادم يُعرض بنصّه لا يُستبَق بمنطق في المتصفّح', () => {
  assert.match(ui, /error instanceof ApiError \? error\.message/);
  assert.match(ui, /نصّ الخادم كما ورد/);
});

test('كل فعلٍ يحمل معرّف طلب', () => {
  const calls = [...ui.matchAll(/rpc<Row>\('(\w+)'/g)].map((m) => m[1]);
  for (const fn of ['create_installation_batch', 'cancel_installation_batch',
    'confirm_installation_batch_payment']) {
    assert.ok(calls.includes(fn), `استدعاء مفقود: ${fn}`);
  }
  assert.equal((ui.match(/crypto\.randomUUID\(\)/g) || []).length, 3);
});
