// نظرة عامة (Overview) لدورة مسوّدة: بطاقةُ توجيهٍ لا تكرار.
//
// المسار المُختبَر: DRAFT + القدرة + Overview → مسارٌ ظاهر → تبويب المراجعة.
// المسوّدة العرضية (كدورة آب) لا نتيجة محسوبة لها، فلا يهبط بها المستخدم
// إلا على نظرة عامة تقول «لا نتيجة محسوبة». بلا بطاقة، لا دليل من هناك إلى
// حيث يعيش زرّ «إلغاء المسودة». والبطاقة رابطٌ فقط — تكرار الـRPC أو منطق
// الإلغاء هنا يُعيد بالضبط الخطأ الذي أُصلح في PR السابق: مكانان لقاعدةٍ
// واحدة.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');
const norm = (p) => read(p).split('\r\n').join('\n');

const uiSrc = norm('src/features/commissions/index.ts');

function slice(from, to) {
  const a = uiSrc.indexOf(from);
  const b = uiSrc.indexOf(to, a);
  assert.ok(a >= 0, `لم يوجد: ${from}`);
  assert.ok(b > a, `لم يوجد: ${to}`);
  return uiSrc.slice(a, b);
}

// الحدّ الفاصل يقف عند التعليق التوثيقي التالي، لا عند تعريف الدالّة —
// وإلا ابتلع القطعُ تعليق draftActionsCard نفسه، وهو يذكر اسم الدالّة
// الخادمية نصّاً ليشرح أنها لا تُنادى هنا، فيُبلَّغ عنه كذباً استدعاءً.
const overview = slice('export const overview: Route = {', '\n/**\n * بطاقة توجيهٍ لدورةٍ لا تزال مسوّدة');
const cardFn = slice('function draftActionsCard', '\n/**\n * المصالحة المرئية');

/* ---------------------------------------------------------------------------
   القاعدة النقيّة تُنفَّذ فعلاً
   ------------------------------------------------------------------------ */

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

const { canCancelDraft } = evalTs(read('src/features/commissions/cancelDraft.ts'), ['canCancelDraft']);

/* ---------------------------------------------------------------------------
   المسار: DRAFT + القدرة + Overview → مسارٌ ظاهر → تبويب المراجعة
   ------------------------------------------------------------------------ */

test('a capable user viewing Overview of a DRAFT cycle sees a way into the review tab', () => {
  // شرط الظهور في Overview هو نفس شرط الإلغاء نفسه — لا شرطٌ موازٍ يُكتب هنا.
  assert.match(overview, /canCancelDraft\(current\.status, can\('commission\.manage_cycle'\)\)/);
  assert.equal(canCancelDraft('DRAFT', true), true);

  // والبطاقة تظهر في الحالتين اللتين تصلهما Overview لمسوّدة: قبل أن
  // تُحسب (وهي حالة المسوّدة العرضية تحديداً) وبعد أن تُحسب.
  const noResultBranch = slice('if (!result) {', 'return;\n    }');
  assert.match(noResultBranch, /\+ draftCard/);
  const fullResultBranch = slice("chip('معتمدة', 'success'))", '+ kpiRow([');
  assert.match(fullResultBranch, /\+ draftCard/);
});

test('the card links to the review tab where the cancel button actually lives', () => {
  assert.match(cardFn, /href\(`\/commissions\/cycles\/\$\{cycle\.id\}\/review`\)/);
  // ونفس نمط الرابط الذي تستعمله بقيّة الشاشة لتبويب المراجعة — لا مسار مُختَرَع.
  assert.match(overview, /href\(`\/commissions\/cycles\/\$\{current\.id\}\/review`\)/);
});

/* ---------------------------------------------------------------------------
   بلا حالات مالية أخرى
   ------------------------------------------------------------------------ */

test('a non-DRAFT cycle, or a DRAFT without the capability, gets no card', () => {
  for (const status of ['UNDER_REVIEW', 'FINALIZED', 'PAID', 'CLOSED', 'CANCELLED']) {
    assert.equal(canCancelDraft(status, true), false, status);
  }
  assert.equal(canCancelDraft('DRAFT', false), false);
});

/* ---------------------------------------------------------------------------
   لا تكرار: لا RPC ولا منطق إلغاء داخل Overview
   ------------------------------------------------------------------------ */

test('Overview calls no RPC belonging to the cancellation flow, and duplicates no cancel UI', () => {
  assert.doesNotMatch(overview, /cancel_empty_commission_cycle/);
  assert.doesNotMatch(overview, /cancelDraftError|cancelDraftSuccess/);
  // ولا زرّ تنفيذٍ هنا — البطاقة رابطٌ لا فعل.
  assert.doesNotMatch(overview + cardFn, /wfCancelDraft|wfCancelGo|تأكيد إلغاء المسودة/);
  // والبطاقة نفسها بلا RPC مطلقاً.
  assert.doesNotMatch(cardFn, /\brpc\(/);
});

test('the card is presentation only: a title, a note, one link — no form, no button', () => {
  assert.match(cardFn, /<h3>إجراءات الدورة<\/h3>/);
  assert.doesNotMatch(cardFn, /<button|<input/);
});

/* ---------------------------------------------------------------------------
   حدث الصلاحيات: يُرسَل فعلاً بعد اكتمال التحميل، ويُقرأ فعلاً
   ------------------------------------------------------------------------ */

test('loadMyCapabilities dispatches babil:capabilities only after the map is applied', () => {
  const html = norm('index.html');
  const fn = html.slice(html.indexOf('async function loadMyCapabilities'));
  const body = fn.slice(0, fn.indexOf('catch(error)'));
  const applyAt = body.indexOf('applyCapabilityVisibility()');
  const dispatchAt = body.indexOf("dispatchEvent(new CustomEvent(\"babil:capabilities\"))");
  assert.ok(applyAt > -1, 'applyCapabilityVisibility غير موجودة');
  assert.ok(dispatchAt > applyAt, 'الحدث يجب أن يُرسَل بعد تطبيق الصلاحيات، لا قبله');
});

test('the app actually listens for babil:capabilities and repaints', () => {
  const mainSrc = norm('src/main.ts');
  const listener = mainSrc.slice(mainSrc.indexOf("addEventListener('babil:capabilities'"));
  const body = listener.slice(0, listener.indexOf('});') + 3);
  assert.match(body, /renderNav\(/);
  assert.match(body, /router\.refresh\(\)/);
});
