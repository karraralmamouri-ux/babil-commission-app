// الدفعة ٢ — تصحيح/عكس الدفعات، وتشغيل مطابقة الهوية: كلاهما كان قدرةً
// خلفيةً بلا سلكٍ إلى الواجهة. هذه الاختبارات تحرس السلك: القدرة تُخفي
// الزرّ لا تُقرّر الأمان (الخادم يتحقّق من admin مباشرةً)، والسبب إلزاميّ،
// ولا تنفيذ إلا بعد تأكيدٍ صريح، ومعرّف طلبٍ جديد لكلّ نقرة، والنقرة
// المكرّرة (إعادة الإرسال) تُقال نجاحاً هادئاً لا خطأً ولا أثراً ثانياً.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');

const corrSrc = read('src/features/finance/paymentCorrections.ts');
const idSrc = read('src/features/system/identities.ts');
const classSrc = read('src/features/installation/classification.ts');

function slice(src, from, to) {
  const a = src.indexOf(from);
  const b = src.indexOf(to, a);
  assert.ok(a >= 0, `لم يوجد: ${from}`);
  assert.ok(b > a, `لم يوجد: ${to}`);
  return src.slice(a, b);
}

function evalTs(source, names) {
  const js = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
  }).outputText;
  const sandbox = { module: { exports: {} }, exports: {}, console, require: () => ({}) };
  sandbox.exports = sandbox.module.exports;
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(js, sandbox);
  const out = {};
  names.forEach((n) => { out[n] = sandbox.module.exports[n]; });
  return out;
}

const { canReversePayment, canCorrectPayment } = evalTs(corrSrc, ['canReversePayment', 'canCorrectPayment']);

/* ---------------------------------------------------------------------------
   الشرط النقيّ — القدرة تُخفي الزرّ فقط، لا تقرِّر الأمان
   ------------------------------------------------------------------------ */

test('قدرة ومبلغ مدفوع → زرّا العكس والتصحيح يظهران', () => {
  assert.equal(canReversePayment(true, true), true);
  assert.equal(canCorrectPayment(true, true), true);
});

test('بلا قدرة → لا زرّ مهما كانت حالة الدفع', () => {
  assert.equal(canReversePayment(false, true), false);
  assert.equal(canCorrectPayment(false, true), false);
});

test('غير مدفوع بعد → لا شيء يُصحَّح أو يُعكس', () => {
  assert.equal(canReversePayment(true, false), false);
  assert.equal(canCorrectPayment(true, false), false);
});

/* ---------------------------------------------------------------------------
   لوحة التأكيد: تُفتح من نقرة الصفّ ولا تُنفِّذ شيئاً بنفسها
   ------------------------------------------------------------------------ */

const wireFn = slice(corrSrc, 'export function wireCorrectionActions', '\n}\n');

test('نقرة الصفّ تفتح اللوحة فقط — RPC لا يُنادى إلا من زرّ التأكيد', () => {
  const rowClick = wireFn.indexOf("closest<HTMLButtonElement>('.correction-action')");
  const confirmClick = wireFn.indexOf("confirm.addEventListener('click'");
  const rpcReverse = wireFn.indexOf("rpc<Row>('reverse_financial_entry'");
  const rpcCorrect = wireFn.indexOf("rpc<Row>('correct_financial_entry'");
  assert.ok(rowClick >= 0 && confirmClick > rowClick);
  assert.ok(rpcReverse > confirmClick && rpcCorrect > confirmClick);
});

test('السبب إلزاميّ قبل أيّ نداء', () => {
  assert.match(wireFn, /if \(!why\) \{ out\.innerHTML = insight\('warn', 'السبب إلزامي'/);
  const guardIdx = wireFn.indexOf("if (!why)");
  const rpcIdx = wireFn.indexOf("const result = action === 'reverse'");
  assert.ok(guardIdx > -1 && guardIdx < rpcIdx);
});

test('التصحيح يحتاج تغييراً فعلياً: مبلغاً أو اسماً، وإلا يُرفض قبل النداء', () => {
  const guardIdx = wireFn.indexOf("correctedAmount === null && !correctedAgent");
  const rpcIdx = wireFn.indexOf("const result = action === 'reverse'");
  assert.ok(guardIdx > -1 && guardIdx < rpcIdx);
});

test('كل نداء يحمل معرّف طلبٍ جديد — لا إعادة استعمال بين النقرات', () => {
  assert.match(wireFn, /p_request_id: crypto\.randomUUID\(\)/);
  const matches = wireFn.match(/crypto\.randomUUID\(\)/g) || [];
  assert.equal(matches.length, 2, 'مرّة للعكس ومرّة للتصحيح — كلٌّ بمعرّفه');
});

test('الزرّ يُعطَّل أثناء التنفيذ ويُعاد تفعيله دوماً عبر finally', () => {
  assert.match(wireFn, /confirm\.disabled = true;/);
  assert.match(wireFn, /finally \{\s*confirm\.disabled = false;/);
});

test('«مُنفَّذ مسبقاً» (إعادة إرسال) يُقال نجاحاً هادئاً لا عطلاً', () => {
  assert.match(wireFn, /result\?\.\['replayed'\] === true/);
  assert.match(wireFn, /مُنفَّذ مسبقاً/);
});

test('عطل الخادم يُقال برسالته لا يُبتلَع', () => {
  assert.match(wireFn, /catch \(error\)/);
  assert.match(wireFn, /error instanceof ApiError \? error\.message : 'خطأ غير متوقّع'/);
});

test('الإلغاء يُفرغ اللوحة بلا أيّ نداء شبكة', () => {
  const cancelIdx = wireFn.indexOf("cancel.addEventListener('click'");
  const cancelBlock = wireFn.slice(cancelIdx, cancelIdx + 80);
  assert.match(cancelBlock, /container\.innerHTML = '';/);
});

test('لا حذف أو كتابة مباشرة على جداول الدفتر — التنفيذ عبر RPC فقط', () => {
  assert.doesNotMatch(corrSrc, /\.delete\(|\.update\(|\.insert\(/);
  assert.doesNotMatch(corrSrc, /from\(['"]financial_ledger/);
});

test('اللوحة تعرض المبلغ الأصلي قبل أيّ تأكيد', () => {
  const panelFn = slice(corrSrc, 'function confirmPanel', '\nexport const CORRECTION_BOX_ID');
  assert.match(panelFn, /المبلغ الأصلي/);
  assert.match(panelFn, /money\(amount\)/);
});

/* ---------------------------------------------------------------------------
   مطابقة الهوية: التشغيل يحتاج تأكيداً صريحاً، ومعرّف طلبٍ لكلّ نقرة
   ------------------------------------------------------------------------ */

test('القدرة subscriber.match تُخفي لوحة التشغيل كلّها بلا صلاحية', () => {
  const panelFn = slice(idSrc, 'function bootstrapPanel', '\nfunction wireBootstrap');
  assert.match(panelFn, /if \(!can\('subscriber\.match'\)\) return '';/);
});

const bootstrapWire = slice(idSrc, 'function wireBootstrap', '\nexport const routes');

test('تشغيل المطابقة يحتاج تأكيد window.confirm قبل أيّ نداء', () => {
  const confirmIdx = bootstrapWire.indexOf('window.confirm(');
  const rpcIdx = bootstrapWire.indexOf("rpc<Row>('run_identity_bootstrap'");
  assert.ok(confirmIdx > -1 && confirmIdx < rpcIdx);
  assert.match(bootstrapWire, /if \(!window\.confirm\(.*\)\) return;/);
});

test('كل تشغيل يحمل معرّف طلبٍ جديد', () => {
  assert.match(bootstrapWire, /p_request_id: crypto\.randomUUID\(\)/);
});

test('الزرّ يُعطَّل أثناء التشغيل ويُعاد تفعيله عبر finally', () => {
  assert.match(bootstrapWire, /btn\.disabled = true;/);
  assert.match(bootstrapWire, /finally \{\s*btn\.disabled = false;/);
});

test('التكرار (replayed) يُقال بلفظه لا عطلاً', () => {
  assert.match(bootstrapWire, /res\?\.\['replayed'\] === true/);
});

test('لا إشارة لإنشاء مشترك أو استحقاق أو دفعة في شاشة المطابقة — التشغيل ربطٌ فقط', () => {
  assert.doesNotMatch(idSrc, /installation_entitlements|installation_payment|create_subscriber/);
});

test('القراءة المُصفَّحة تمرّ عبر page_subscriber_identities وحدها — لا استعلام مباشر آخر', () => {
  const renderFn = slice(idSrc, 'async render(view, m)', '\n  },\n};');
  assert.match(renderFn, /pageRpc<Row>\('page_subscriber_identities'/);
  assert.doesNotMatch(renderFn, /\.from\(['"]subscriber_identities/);
});

/* ---------------------------------------------------------------------------
   الدفعة ٣ — تصنيف الجِدّة: نفس الحرص، نفس التأكيد، بلا معرّف طلبٍ (لا
   audit_logs يكتبه refresh_subscriber_classifications — upsert طبيعي الإعادة)
   ------------------------------------------------------------------------ */

const classRunPanel = slice(classSrc, 'export function classificationRunPanel', '\nexport function wireClassificationRun');
const classRunWire = classSrc.slice(classSrc.indexOf('export function wireClassificationRun'));

test('القدرة saas.review تُخفي لوحة تشغيل التصنيف كلّها بلا صلاحية', () => {
  assert.match(classRunPanel, /if \(!can\('saas\.review'\)\) return '';/);
});

test('تشغيل التصنيف يحتاج تأكيد window.confirm قبل أيّ نداء', () => {
  const confirmIdx = classRunWire.indexOf('window.confirm(');
  const rpcIdx = classRunWire.indexOf("rpc<Row>('refresh_subscriber_classifications'");
  assert.ok(confirmIdx > -1 && confirmIdx < rpcIdx);
  assert.match(classRunWire, /if \(!window\.confirm\(.*\)\) return;/);
});

test('زرّ تشغيل التصنيف يُعطَّل أثناء التنفيذ ويُعاد تفعيله عبر finally', () => {
  assert.match(classRunWire, /btn\.disabled = true;/);
  assert.match(classRunWire, /finally \{\s*btn\.disabled = false;/);
});

test('لا إشارة لإنشاء مشترك أو استحقاق أو دفعة في لوحة تشغيل التصنيف — الكتابة تصل التصنيف فقط', () => {
  assert.doesNotMatch(classSrc, /installation_entitlements|installation_payment|create_subscriber/);
});
