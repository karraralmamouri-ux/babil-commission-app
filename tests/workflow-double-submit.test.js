// إجراءات الدورة: الضغطة الثانية بعد النجاح.
//
// كل إجراء هنا يكتب على الخادم ويترك سطراً في سجلّ التدقيق. وبعد النجاح تبقى
// اللوحة معروضةً حتى التحديث — ثانيةً وثلث — فإن بقي الزرّ حيّاً في هذه المدّة
// كانت الضغطة الثانية طلباً ثانياً كاملاً، لا إعادةً لطلبٍ واحد: المعرّف
// يُولَّد عند الضغط، فيراه الخادم نيّةً جديدة.
//
// ولا يحرس الخادمُ كلَّ باب: `recalculate_cycle_after_master_change` تستقبل
// `p_request_id` وتختمه على سطر التدقيق، ولا تبحث عنه قبل التنفيذ كما تفعل
// `cancel_empty_commission_cycle`. وحارس حالتها يمنع المعتمدة والمدفوعة
// وحدها، فالمسوّدة والدورة قيد المراجعة — وهي محلّ إعادة الحساب أصلاً —
// تُحسب مرّتين فعلاً.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');

const src = read('src/features/commissions/index.ts').split('\r\n').join('\n');

function slice(from, to) {
  const a = src.indexOf(from);
  const b = src.indexOf(to, a);
  assert.ok(a >= 0, `لم يوجد: ${from}`);
  assert.ok(b > a, `لم يوجد: ${to}`);
  return src.slice(a, b);
}

/** كتلة `try` من نداء الخادم إلى `catch`، وكتلة `catch` بعدها. */
function paths(from, to) {
  const block = slice(from, to);
  const cut = block.indexOf('} catch (error) {');
  assert.ok(cut > 0, `لا catch في: ${from}`);
  return { success: block.slice(0, cut), failure: block.slice(cut) };
}

const run = paths('const run = async (', 'const recalc = box.querySelector');
const recalc = paths('const recalc = box.querySelector', 'const exportBtn = box.querySelector');
const exportBtn = paths('const exportBtn = box.querySelector', 'const finalize = box.querySelector');

/* ---------------------------------------------------------------------------
   النجاح لا يترك الزرّ حيّاً
   ------------------------------------------------------------------------ */

test('a successful cycle action does not re-arm its own button', () => {
  // `finally` تُعيد التمكين في المسارين معاً، فتفتح النافذة التي تُغلق هنا.
  assert.doesNotMatch(run.success, /finally/);
  assert.doesNotMatch(run.success, /disabled = false/);
  assert.doesNotMatch(run.failure, /finally/);
});

test('a successful recalculation does not re-arm its own button', () => {
  // ولا حارس إعادةٍ على الخادم يلتقط الطلب الثاني: يُعاد الحساب فعلاً،
  // فتُحذف اللقطات غير المعتمدة والاستثناءات المفتوحة وتُبنى من جديد.
  // و`finally` تقع بعد `catch` نصّاً، فلا يكفي فحص نصف النجاح وحده.
  assert.doesNotMatch(recalc.success, /recalc\.disabled = false/);
  assert.doesNotMatch(recalc.failure, /finally/);
});

test('the second audit row would misreport the delta, which is why the window is closed', () => {
  // النداء الثاني يقرأ `gross_before` بعد أن غيّره الأوّل، فيسجّل «لا تغيير»
  // عن عمليةٍ غيّرت. وقارئ السجلّ يرى الأحدث أوّلاً — فيصدّق الأحدث.
  const sql = read('supabase/migrations/20260826090000_add_fdt_onboarding_workflow.sql');
  const fn = sql.slice(sql.indexOf('function public.recalculate_cycle_after_master_change'));
  const body = fn.slice(0, fn.indexOf('$$;'));
  assert.match(body, /p_request_id/);
  // المعرّف يُختم على السطر ولا يُبحث عنه قبل التنفيذ.
  assert.doesNotMatch(body, /where[\s\S]{0,120}request_id = p_request_id/);
  // وحارس الحالة يترك المسوّدة وقيد المراجعة مفتوحتين لإعادة الحساب.
  assert.match(body, /status in \('FINALIZED', 'PARTIALLY_PAID', 'PAID', 'CLOSED'\)/);
});

test('a successful export cools down instead of staying live', () => {
  // التصدير يُعاد بنيّة صادقة أحياناً، فلا يُقفل — لكنه يكتب سطر تدقيق،
  // فلا يُترك حيّاً في اللحظة التي تلتقط فيها الضغطة المزدوجة.
  assert.doesNotMatch(exportBtn.success, /finally/);
  assert.match(exportBtn.success, /window\.setTimeout\(\(\) => \{ if \(view\.live\) exportBtn\.disabled = false; \}/);
});

/* ---------------------------------------------------------------------------
   الفشل يُعيد المحاولة
   ------------------------------------------------------------------------ */

test('a failed action re-arms its button so the user can retry', () => {
  // لم يقع شيء على الخادم، فقفلُ الزرّ يحبس المستخدم بلا سبب.
  assert.match(run.failure, /button\.disabled = false;/);
  assert.match(recalc.failure, /recalc\.disabled = false;/);
  assert.match(exportBtn.failure, /exportBtn\.disabled = false;/);
});

test('re-arming happens only after the view is confirmed alive', () => {
  for (const [name, p] of [['run', run], ['recalc', recalc], ['export', exportBtn]]) {
    const live = p.failure.indexOf('if (!view.live) return;');
    const rearm = p.failure.indexOf('disabled = false');
    assert.ok(live > -1 && live < rearm, `${name}: التمكين يسبق فحص حياة العرض`);
  }
});

/* ---------------------------------------------------------------------------
   الثابت العام
   ------------------------------------------------------------------------ */

test('no cycle action re-arms its button in a finally block', () => {
  // `finally` لا تُفرّق بين نجاحٍ وفشل، وهذه التفرقة هي كل المسألة.
  const panel = slice('function wireWorkflow(', 'function cancelDraftConfirm');
  assert.doesNotMatch(panel, /\}\s*finally\s*\{/);
});
