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

test('the overview route asks the server for the operative cycle, not the newest row', () => {
  assert.match(overview, /currentCycleId\(\)/,
    'the route no longer calls currentCycleId()');
  assert.match(overview, /const current = \(currentId && list\.find\(\(c\) => c\.id === currentId\)\) \|\| \(list\[0\] as Cycle\);/,
    'the default-cycle selection no longer prefers the server-resolved operative cycle');
});

test('currentCycleId is imported from the same domain module every other fixed screen uses', () => {
  assert.match(uiSrc, /import\s*\{[^}]*currentCycleId[^}]*\}\s*from\s*'\.\.\/\.\.\/domain\/cycle'/s,
    'currentCycleId is not imported from ../../domain/cycle');
});

test('regression guard: a bare "list[0] as Cycle" is never the sole source of the default cycle', () => {
  // القاعدة القديمة كانت سطراً واحداً بلا شرط. لو عادت وحدها — بلا
  // currentId — فالعلّة تعود معها.
  assert.doesNotMatch(overview, /const current = list\[0\] as Cycle;/,
    'the unconditional list[0] default has returned — this is the exact bug from the QA fix pack');
});

test('the full cycles list — including cancelled ones — still reaches the page for explicit navigation', () => {
  // الجدول أسفل الشاشة يعرض `list` كاملةً (لا currentId فقط)، فالملغاة
  // تبقى قابلةً للفتح صراحةً من هناك.
  assert.match(overview, /table<Cycle>\(cycleColumns\(\), list,/,
    'the cycles table no longer renders the full list — explicit navigation to a cancelled cycle would be lost');
});
