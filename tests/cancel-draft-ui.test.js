// إلغاء المسوّدة من الواجهة.
//
// الإلغاء عمليةٌ ماليةُ الأثر وإن لم تحرّك مالاً: تُخرج دورةً من دورة الحياة
// وتكتب سطراً في سجلّ التدقيق. فما يُختبَر هنا ليس أن الزرّ يعمل، بل أنه لا
// يعمل حيث يجب ألّا يعمل — لغير صاحب القدرة، ولغير المسوّدة، وبلا سبب،
// وبضغطتين. والقواعد النقيّة تُنفَّذ فعلاً؛ والتوصيل يُقرأ من المصدر.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');

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

const rulesSrc = read('src/features/commissions/cancelDraft.ts');
const { canCancelDraft, cancelDraftError, cancelDraftSuccess } =
  evalTs(rulesSrc, ['canCancelDraft', 'cancelDraftError', 'cancelDraftSuccess']);

// المصدر CRLF على القرص؛ يُوحَّد سطره حتى تصف التعابير النمطية ما تراه العين.
const uiSrc = read('src/features/commissions/index.ts').split('\r\n').join('\n');

/** كتلة التوصيل وحدها — حتى لا يمرّ اختبارٌ بسبب نصٍّ في إجراءٍ آخر. */
function slice(from, to) {
  const a = uiSrc.indexOf(from);
  const b = uiSrc.indexOf(to, a);
  assert.ok(a >= 0, `لم يوجد: ${from}`);
  assert.ok(b > a, `لم يوجد: ${to}`);
  return uiSrc.slice(a, b);
}

const panelRow = slice("if (canCancelDraft(", 'if (!rows.length)');
const handler = slice("const cancelDraft = box.querySelector", 'function cancelDraftConfirm');
const confirmCard = slice('function cancelDraftConfirm', '\nexport const routes');
const successPath = slice('const done = cancelDraftSuccess', '} catch (error) {');
const failurePath = slice("console.error('cancel_empty_commission_cycle'", 'function cancelDraftConfirm');

/* ---------------------------------------------------------------------------
   1 · من يملك القدرة يرى الإجراء
   ------------------------------------------------------------------------ */

test('a user holding commission.manage_cycle sees the action on a draft', () => {
  assert.equal(canCancelDraft('DRAFT', true), true);
  // والزرّ الذي تراه هذه الحالة موجودٌ فعلاً في اللوحة.
  assert.match(panelRow, /id="wfCancelDraft"/);
  assert.match(panelRow, /إلغاء المسودة/);
});

/* ---------------------------------------------------------------------------
   2 · من لا يملكها لا يراه ولا ينفّذه
   ------------------------------------------------------------------------ */

test('a user without the capability neither sees nor reaches the action', () => {
  for (const status of ['DRAFT', 'UNDER_REVIEW', 'FINALIZED', 'PAID', 'CLOSED']) {
    assert.equal(canCancelDraft(status, false), false, status);
  }
  // الإخفاء يمرّ عبر القدرة نفسها التي تشترطها الدالّة على الخادم.
  assert.match(panelRow, /can\('commission\.manage_cycle'\)/);
  // ولا مدخل ثانٍ: زرّ واحد، ومستمعٌ واحد معلّق عليه.
  assert.equal(uiSrc.split('wfCancelDraft').length - 1, 2);
  // فإن غاب الزرّ غاب النداء — المستمع معلّق على العنصر لا على المستند.
  assert.match(handler, /cancelDraft\?\.addEventListener\('click'/);
});

/* ---------------------------------------------------------------------------
   3 · للمسوّدة وحدها، لا لأي حالة مالية أخرى
   ------------------------------------------------------------------------ */

test('the action is offered for DRAFT only, never for a financial state', () => {
  assert.equal(canCancelDraft('DRAFT', true), true);
  for (const status of ['UNDER_REVIEW', 'FINALIZED', 'PAID', 'CLOSED', 'CANCELLED', '']) {
    assert.equal(canCancelDraft(status, true), false, status);
  }
});

test('a non-draft refusal from the server names the state without leaking SQLSTATE', () => {
  const m = cancelDraftError('Only a DRAFT cycle can be cancelled; this one is FINALIZED');
  assert.match(m.title, /ليست مسوّدة/);
  assert.match(m.detail, /FINALIZED/);
  assert.doesNotMatch(m.title + m.detail, /42501|P0002|SQLSTATE/);
});

/* ---------------------------------------------------------------------------
   4 · السبب إلزامي
   ------------------------------------------------------------------------ */

test('the reason is mandatory and blocks the request before it is sent', () => {
  const need = cancelDraftError('needs a reason');
  assert.match(need.title, /السبب إلزامي/);

  // الفحص يسبق عرض التأكيد، والتأكيد يسبق النداء.
  const guard = handler.indexOf('if (!why)');
  const card = handler.indexOf('cancelDraftConfirm');
  const call = handler.indexOf("rpc<Record<string, unknown>>('cancel_empty");
  assert.ok(guard > -1 && guard < card && card < call);
  // ولا سبب افتراضي: القيمة تُقرأ من الحقل وتُقصّ، ولا تُستبدل عند الفراغ.
  assert.match(handler, /const why = reason\?\.value\.trim\(\) \|\| '';/);
  assert.doesNotMatch(handler, /p_reason: '[^']/);
  assert.match(handler, /p_reason: why,/);
});

/* ---------------------------------------------------------------------------
   5 · لا إرسال مزدوج
   ------------------------------------------------------------------------ */

test('a second click cannot send a second request', () => {
  // حارسٌ يخرج قبل أي عمل، ثم تعطيلٌ للزرّين معاً.
  const guard = handler.indexOf('if (go.disabled) return;');
  const disable = handler.indexOf('go.disabled = true;');
  const call = handler.indexOf("await rpc");
  assert.ok(guard > -1, 'لا حارس للضغط المزدوج');
  assert.ok(guard < disable && disable < call, 'التعطيل يجب أن يسبق النداء');
  assert.match(handler, /cancelDraft\.disabled = true;/);
  // ولا يُعاد التمكين في مسار النجاح — الشاشة تنتقل بدل أن تُتيح ضغطةً ثانية.
  assert.doesNotMatch(successPath, /disabled = false/);
});

/* ---------------------------------------------------------------------------
   6 · لا نداء إلا الدالّة المعتمدة
   ------------------------------------------------------------------------ */

test('the only server call in the cancellation path is cancel_empty_commission_cycle', () => {
  // الوسيط النوعي قد يحوي `>` بنفسه (`rpc<Record<string, unknown>>`)، فيُقفز
  // إلى القوس بدل محاولة موازنة الأقواس الزاويّة بتعبير نمطي.
  const called = [...handler.matchAll(/\brpc[^(]*\('([a-z0-9_]+)'/g)].map((m) => m[1]);
  assert.deepEqual(called, ['cancel_empty_commission_cycle']);
  // ولا استدعاءات أخرى للخادم من هذا المسار.
  assert.doesNotMatch(handler, /\bselect\(|\bedge\(|\bfetch\(/);
  // والدالّة تُنادى من مكان واحد في التطبيق كلّه.
  const sites = [...uiSrc.matchAll(/\brpc[^(]*\('cancel_empty_commission_cycle'/g)];
  assert.equal(sites.length, 1);
});

/* ---------------------------------------------------------------------------
   7 · معرّف طلبٍ جديد لكل تنفيذ
   ------------------------------------------------------------------------ */

test('every execution carries a freshly generated request id', () => {
  assert.match(handler, /p_request_id: crypto\.randomUUID\(\),/);
  // التوليد داخل مُعالِج الضغط، لا في أعلى الوحدة: قيمةٌ ثابتة تعني أن
  // إعادة المحاولة بعد خطأ شبكةٍ ستُقرأ إعادةَ تشغيل، فتصمت عن فشلٍ حقيقي.
  const listener = handler.indexOf("go?.addEventListener('click'");
  const uuid = handler.indexOf('crypto.randomUUID()');
  assert.ok(listener > -1 && uuid > listener);
  assert.doesNotMatch(handler, /const .*[Rr]equestId = crypto\.randomUUID/);
});

/* ---------------------------------------------------------------------------
   8 · النجاح يحدّث الشاشة بلا إعادة تحميل
   ------------------------------------------------------------------------ */

test('success refreshes the screen without reloading the page', () => {
  assert.doesNotMatch(handler, /location\.reload/);
  assert.match(successPath, /window\.location\.hash = href\('\/commissions\/cycles'\)/);
  assert.match(successPath, /if \(!view\.live\) return;|view\.live/);

  const first = cancelDraftSuccess(false);
  assert.match(first.title, /تم إلغاء المسودة وحفظ العملية في سجل التدقيق/);
  // وإعادة الطلب تُقال كما هي: نُفِّذ مرّة، لا مرّتين.
  const again = cancelDraftSuccess(true);
  assert.match(again.title, /ملغاة أصلاً/);
  assert.match(again.detail, /مرّةً واحدة/);
  assert.notEqual(first.title, again.title);
});

/* ---------------------------------------------------------------------------
   9 · الخطأ لا يغيّر الحالة المحلّية كذباً
   ------------------------------------------------------------------------ */

test('a failed cancellation leaves the screen telling the truth', () => {
  // لا انتقال، ولا تحديث، ولا ادّعاء أن الدورة صارت ملغاة.
  assert.doesNotMatch(failurePath, /location\.hash|babil:refresh|CANCELLED/);
  assert.doesNotMatch(failurePath, /cycle\.status\s*=[^=]/);
  // بل رسالة خطأ، وإتاحة المحاولة من جديد.
  assert.match(failurePath, /insight\('danger'/);
  assert.match(failurePath, /cancelDraft\.disabled = false;/);
  // والنصّ الخام للمهندس وحده.
  assert.match(failurePath, /console\.error\(/);
});

test('every server refusal maps to an operational reason, never raw Postgres', () => {
  const cases = [
    ['Only a DRAFT cycle can be cancelled; this one is PAID', /ليست مسوّدة/],
    ['This draft has a calculated result and is not empty', /ليست فارغة/],
    ['The cycle carries business rows and cannot be cancelled '
      + '(entitlements 12, exceptions 0, snapshots 3, batches 0, corrections 0)', /بيانات عمل/],
    ['Capability commission.manage_cycle is required', /لا صلاحية/],
    ['Cancelling a cycle needs a reason', /السبب إلزامي/],
    ['request_id is required', /تعذّر إرسال الطلب/],
    ['Commission cycle was not found', /غير موجودة/],
    ['', /لم يتم إلغاء المسودة/],
  ];
  for (const [raw, expected] of cases) {
    const m = cancelDraftError(raw);
    assert.match(m.title, expected, raw);
    assert.ok(m.detail.length > 0, raw);
    // لا رموز، ولا نصّ إنجليزي خام مسرَّب إلى العنوان.
    assert.doesNotMatch(m.title, /[A-Za-z]{4,}/, raw);
  }
});

test('the dependent counts are named, and the zeros are left out', () => {
  const m = cancelDraftError('The cycle carries business rows and cannot be cancelled '
    + '(entitlements 12, exceptions 0, snapshots 3, batches 0, corrections 0)');
  assert.match(m.detail, /استحقاقات: 12/);
  assert.match(m.detail, /لقطات: 3/);
  assert.doesNotMatch(m.detail, /استثناءات|دفعات صرف|تصحيحات/);
});

/* ---------------------------------------------------------------------------
   10 · لا كتابة مباشرة على جدول الدورات
   ------------------------------------------------------------------------ */

test('the client has no table-write channel at all', () => {
  // كل كتابة تمرّ بدالّة يحرسها الخادم. لا PATCH ولا DELETE في العميل أصلاً،
  // فلا سبيل إلى تعديل صفّ `commission_cycles` أو حذفه من الواجهة.
  const api = read('src/services/api.ts');
  const methods = [...api.matchAll(/method: '([A-Z]+)'/g)].map((m) => m[1]);
  assert.deepEqual([...new Set(methods)], ['POST']);
  assert.doesNotMatch(api, /'PATCH'|'DELETE'|'PUT'/);
  assert.doesNotMatch(handler, /commission_cycles/);
});

/* ---------------------------------------------------------------------------
   التأكيد يعرض ما يُلغى
   ------------------------------------------------------------------------ */

test('the confirmation states the cycle, the period, the status and the warning', () => {
  assert.match(confirmCard, /تأكيد إلغاء المسودة/);
  assert.match(confirmCard, /esc\(cycle\.name\)/);
  assert.match(confirmCard, /esc\(cycle\.period_start\)/);
  assert.match(confirmCard, /esc\(cycle\.period_end\)/);
  assert.match(confirmCard, /الحالة الحالية: مسودة/);
  assert.match(confirmCard, /الإلغاء يحفظ الدورة في السجل ولا يحذف تاريخ إنشائها/);
  assert.match(confirmCard, /esc\(why\)/);
  // وللمستخدم مخرج.
  assert.match(confirmCard, /id="wfCancelBack"/);
  // اللون ليس الدليل الوحيد: رمزٌ ونصٌّ صريحان يسبقانه.
  assert.match(confirmCard, /⊘ تأكيد إلغاء المسودة/);
});
