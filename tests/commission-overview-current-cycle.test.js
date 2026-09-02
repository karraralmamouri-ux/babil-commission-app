// نظرة عامة (Overview) لعمولات الوكلاء — الدورة الافتراضية من الخادم، لا
// من `list[0]`.
//
// تدقيق QA ما بعد الإطلاق (2026-09-01): دورة 2026-08 مُلغاة كانت تُفتح
// كدورةٍ حالية/افتراضية في هذه الشاشة تحديداً، بينما ثلاث شاشات أخرى
// (`src/features/home/index.ts`، `src/features/commissions/corrections.ts`،
// `src/features/reports/index.ts`) كانت مُصلَحة بالفعل منذ هجرة
// current_commission_cycle_id (20260929090000). هذه الشاشة وحدها بقيت
// تختار `list[0]` — أحدث period_start بلا شرط حالة — فورثت دورةٌ ملغاة
// مكان تموز الحقيقية. هذا اختبار حراسة ثابت يمنع عودة النمط القديم.
//
// مراجعة Codex لـ PR #95 (Blocker 4): الاختبار السابق هنا كان يُثبِت — عن
// طريق الخطأ — النمط القديم المعطوب نفسه (`list[0] as Cycle` بلا شرط)
// باعتباره الصحيح. أُعيد كتابته هنا ليطابق الإصلاح الفعلي: لا دورة عاملة
// لا تعرض بديلاً صامتاً، بل حالة «لا دورة عاملة» صريحة.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8').split('\r\n').join('\n');

const uiSrc = read('src/features/commissions/index.ts');

function slice(from, to) {
  const a = uiSrc.indexOf(from);
  const b = uiSrc.indexOf(to, a);
  assert.ok(a >= 0, `لم يوجد: ${from}`);
  assert.ok(b > a, `لم يوجد: ${to}`);
  return uiSrc.slice(a, b);
}

const overview = slice('export const overview: Route = {', '\n/**\n * بطاقة توجيهٍ لدورةٍ لا تزال مسوّدة');

test('the overview route asks the server for the operative cycle', () => {
  assert.match(overview, /currentCycleId\(\)/,
    'the route no longer calls currentCycleId()');
});

test('currentCycleId is imported from the same domain module every other fixed screen uses', () => {
  assert.match(uiSrc, /import\s*\{[^}]*currentCycleId[^}]*\}\s*from\s*'\.\.\/\.\.\/domain\/cycle'/s,
    'currentCycleId is not imported from ../../domain/cycle');
});

test('only cancelled/draft-uncalculated cycles exist => no default cycle is auto-selected', () => {
  // لا currentId (كلّ الدورات ملغاة أو مسوّدة بلا حساب) => حالة «لا دورة
  // عاملة حالياً» صريحة تُعرض، ولا انتقاء ضمنيّ لأيّ صفٍّ من القائمة.
  assert.match(overview, /if\s*\(\s*!currentId\s*\)\s*\{/,
    'the route no longer branches explicitly on a missing operative cycle');
  const noCurrentBranch = slice('if (!currentId) {', 'const current = list.find');
  assert.match(noCurrentBranch, /لا دورة عاملة حالياً/,
    'the no-operative-cycle branch no longer shows an explicit empty state');
  assert.doesNotMatch(noCurrentBranch, /list\[0\]/,
    'the no-operative-cycle branch falls back to list[0] — the exact cancelled-cycle-default bug');
});

test('operative + cancelled cycles both exist => the operative one is selected, not the newest row', () => {
  // بعد تجاوز فرع «لا دورة عاملة»، الاختيار الوحيد المتبقّي مرتبط بـ
  // currentId الذي أعاده الخادم — لا بأوّل عنصرٍ في القائمة.
  assert.match(overview, /const current = list\.find\(\(c\) => c\.id === currentId\) as Cycle;/,
    'the selected cycle is no longer looked up by the server-resolved currentId');
});

test('regression guard: a bare "list[0] as Cycle" is never the sole source of the default cycle', () => {
  // القاعدة القديمة كانت سطراً واحداً بلا شرط. لو عادت — بشرطٍ أو بلا شرط —
  // فالعلّة تعود معها: قد تختار دورةً ملغاة لمجرّد أنها الأحدث.
  assert.doesNotMatch(overview, /list\[0\] as Cycle/,
    'list[0] is used as (any part of) the default cycle again — this is the exact bug from the QA fix pack');
});

test('direct navigation to a cancelled cycle in the table below remains allowed', () => {
  // الجدول أسفل الشاشة يعرض `list` كاملةً (لا currentId فقط) في كلا الفرعين
  // (لا دورة عاملة / يوجد دورة عاملة)، فالملغاة تبقى قابلةً للفتح صراحةً.
  assert.match(overview, /table<Cycle>\(cycleColumns\(\), list,/,
    'the cycles table no longer renders the full list — explicit navigation to a cancelled cycle would be lost');
});
