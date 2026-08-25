// رفع التعليق: `release_hold_v2` كان موجوداً بلا سلكٍ إلى الواجهة — لا زرّ
// يناديه في أيّ مكان. هذه الاختبارات تحرس السلك الجديد: من يملك القدرة فقط
// يرى الزرّ، ولا يظهر إلا على تعليقٍ حالته ACTIVE فعلاً؛ التأكيد يعرض
// المشترك والسبب والنوع والمصدر والتاريخ قبل أي تنفيذ؛ لا حذف مباشر؛
// والنقرة المكرّرة بلا أثرٍ ثانٍ.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');
const norm = (p) => read(p).split('\r\n').join('\n');

const src = norm('src/features/installation/holds.ts');

function slice(from, to) {
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

const { canReleaseHold } = evalTs(read('src/features/installation/holdRelease.ts'), ['canReleaseHold']);

/* ---------------------------------------------------------------------------
   الشرط النقيّ — نفّذ فعلاً، لا نمطاً نصّياً
   ------------------------------------------------------------------------ */

test('تعليقٌ ساري (ACTIVE) ومستخدمٌ بالقدرة → الزرّ يظهر', () => {
  assert.equal(canReleaseHold('ACTIVE', true), true);
});

test('حجب الصلاحية: بلا installation.release_hold → لا زرّ مهما كانت الحالة', () => {
  assert.equal(canReleaseHold('ACTIVE', false), false);
});

test('مرفوعٌ مسبقاً (RELEASED) → لا زرّ ثانٍ، بصلاحية أو بدونها', () => {
  assert.equal(canReleaseHold('RELEASED', true), false);
  assert.equal(canReleaseHold('RELEASED', false), false);
});

test('التعليق المنتهي زمنياً يبقى ACTIVE خادمياً، فالشرط يعتمد الحالة لا الفعالية', () => {
  // `effective` عمودٌ مشتقّ في page_installation_holds لا حالة مخزَّنة؛
  // تعليقٌ مؤقّت منتهٍ يبقى status='ACTIVE' حتى يُرفع صراحةً. الشرط هنا
  // يتحقّق من status فقط — تماماً كما يتحقّق release_hold_v2 خادمياً.
  assert.equal(canReleaseHold('ACTIVE', true), true);
  assert.doesNotMatch(read('src/features/installation/holdRelease.ts'), /effective/);
});

/* ---------------------------------------------------------------------------
   العمود في الشاشة: مُعاد استعمال الشرط نفسه، لا شرطٌ مواز
   ------------------------------------------------------------------------ */

test('عمود الرفع يستدعي canReleaseHold — لا تكرار للشرط في الشاشة', () => {
  const column = slice(`{ key: 'release', label: ''`, `\n    ];`);
  assert.match(column, /canReleaseHold\(str\(r, 'status'\), can\('installation\.release_hold'\)\)/);
});

test('الدائم يُعامَل كالمؤقّت — لا فرع خاصّ بالديمومة في شرط الظهور', () => {
  const column = slice(`{ key: 'release', label: ''`, `\n    ];`);
  assert.doesNotMatch(column, /PERMANENT|TEMPORARY/);
});

test('زرّ الرفع يحمل بيانات التأكيد كاملة: المعرّف، المشترك، السبب، النوع، المصدر، التاريخ', () => {
  const column = slice(`{ key: 'release', label: ''`, `\n    ];`);
  for (const attr of ['data-id', 'data-subscriber', 'data-permanence', 'data-source', 'data-placed', 'data-reason']) {
    assert.ok(column.includes(attr), `سمة ناقصة على الزرّ: ${attr}`);
  }
});

/* ---------------------------------------------------------------------------
   لوحة التأكيد: تُعرض قبل أيّ تنفيذ — المشترك والتعليق الحالي وسببه ونوعه
   ومصدره وتاريخه، ثم سبب الرفع صراحةً
   ------------------------------------------------------------------------ */

const panelFn = slice('function releaseConfirmPanel', '\nfunction wireReleaseHold');

test('اللوحة تعرض الشواهد الستّة قبل التأكيد', () => {
  assert.match(panelFn, /btn\.dataset\['subscriber'\]/);
  assert.match(panelFn, /btn\.dataset\['reason'\]/);
  assert.match(panelFn, /permanenceAr/);
  assert.match(panelFn, /btn\.dataset\['source'\]/);
  assert.match(panelFn, /btn\.dataset\['placed'\]/);
  assert.match(panelFn, /id="rcReason"/);
});

test('لا تنفيذ بلا نقرة تأكيد صريحة — الزرّ الأوّل يفتح المعاينة فقط', () => {
  const wireFn = slice('function wireReleaseHold', '\n\n/* ---- التعليق بالجملة');
  // نقرة الصفّ الأولى (release-hold) تكتب اللوحة فقط؛ RPC لا يُنادى إلا من
  // زرّ التأكيد الثاني (rcConfirm) بعد أن يُقرأ منها.
  const rowClick = wireFn.indexOf("btn.addEventListener('click'");
  const confirmClick = wireFn.indexOf('confirm.addEventListener');
  const rpcCall = wireFn.indexOf("rpc<Row>('release_hold_v2'");
  assert.ok(rowClick >= 0 && confirmClick > rowClick, 'زرّ التأكيد يُوصَل بعد فتح اللوحة من زرّ الصفّ');
  assert.ok(rpcCall > confirmClick, 'RPC يُنادى من داخل معالج زرّ التأكيد لا زرّ الصفّ');
});

/* ---------------------------------------------------------------------------
   التنفيذ: RPC وحده، لا حذف مباشر، معرّف طلبٍ لكلّ نقرة
   ------------------------------------------------------------------------ */

const wireFn = slice('function wireReleaseHold', '\n\n/* ---- التعليق بالجملة');

test('التنفيذ عبر release_hold_v2 فقط — لا حذف مباشر لسجلّ التعليق', () => {
  assert.match(wireFn, /rpc<Row>\('release_hold_v2', \{/);
  assert.match(wireFn, /p_hold_id: holdId/);
  assert.match(wireFn, /p_reason: why/);
  assert.doesNotMatch(src, /delete\s+from|\.delete\(/i);
});

test('سبب الرفع إلزاميّ قبل أيّ نداء', () => {
  assert.match(wireFn, /if \(!why\)/);
  const guardIdx = wireFn.indexOf('if (!why)');
  const rpcIdx = wireFn.indexOf("rpc<Row>('release_hold_v2'");
  assert.ok(guardIdx > -1 && guardIdx < rpcIdx);
});

test('كل نداء يحمل معرّف طلب — النقرة المكرّرة بلا أثر ثانٍ', () => {
  assert.match(wireFn, /p_request_id: crypto\.randomUUID\(\)/);
  assert.match(wireFn, /idempotent/);
});

test('الزرّ يُعطَّل أثناء التنفيذ ويُعاد تفعيله دوماً — لا نقرة مزدوجة تُنتج نداءين', () => {
  assert.match(wireFn, /confirm\.disabled = true;/);
  assert.match(wireFn, /finally \{\s*confirm\.disabled = false;/);
});

test('«مرفوعٌ مسبقاً» يُقال نجاحاً هادئاً لا عطلاً', () => {
  assert.match(wireFn, /result\?\.\['idempotent'\] === true/);
  assert.match(wireFn, /مرفوعٌ مسبقاً/);
});

test('عطل الخادم (رفض صلاحية، تعليق غير موجود...) يُقال برسالته لا يُبتلَع', () => {
  assert.match(wireFn, /catch \(error\)/);
  assert.match(wireFn, /error instanceof ApiError \? error\.message : 'خطأ غير متوقّع'/);
});

test('النجاح يُحدَّث نطاقياً — babil:refresh لا location.reload', () => {
  assert.match(wireFn, /dispatchEvent\(new CustomEvent\('babil:refresh'\)\)/);
  assert.doesNotMatch(wireFn, /location\.reload/);
});

test('الإلغاء يُفرغ اللوحة بلا أيّ نداء شبكة', () => {
  const cancelBlock = wireFn.slice(wireFn.indexOf("cancel.addEventListener"), wireFn.indexOf("cancel.addEventListener") + 90);
  assert.match(cancelBlock, /box\.innerHTML = '';/);
});
