// LIVE-03: قرارٌ يُحسَم (classify_parent) لا يُعيد كتابة المال بصمت — لكن
// الدورة المتأثّرة يجب أن تُعلِن نفسها بحاجة لإعادة حساب، لا أن تبقى صامتة
// حتى يتذكّر أحدٌ يدوياً. الخادم (commission_cycle_result، في
// 20261012090000_recalculation_lifecycle.sql) كان يحمل العلم needs_recalculation
// منذ البداية؛ الفجوة كانت أن لا شاشة تعرضه. هذا الاختبار يُنفِّذ تعبير
// الشارة الحقيقي من overview() في src/features/commissions/index.ts — لا
// نسخة معاد كتابتها — على حالتين: علمٌ مرفوع وعلمٌ غير مرفوع.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require('typescript');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8').split('\r\n').join('\n');

const overviewSrc = read('src/features/commissions/index.ts');
const uiSrc = read('src/components/ui.ts');

function slice(src, from, to, label) {
  const a = src.indexOf(from);
  assert.ok(a >= 0, `لم يوجد: ${label || from}`);
  const b = src.indexOf(to, a);
  assert.ok(b > a, `لم يوجد نهاية: ${label || from}`);
  return src.slice(a, b + to.length);
}

const escFn = slice(uiSrc, 'export function esc(value: unknown): string {', '\n}', 'esc()');
const insightFn = slice(overviewSrc,
  "function insight(tone: 'good' | 'warn' | 'danger', title: string, detail = ''): string {",
  '\n}', 'insight()');

const badgeExpr = slice(overviewSrc,
  '(result.cycle.needs_recalculation', "? insight('warn'", 'شارة needs_recalculation (البداية)');
const badgeExprFull = overviewSrc.slice(
  overviewSrc.indexOf('(result.cycle.needs_recalculation'),
  overviewSrc.indexOf(": '')", overviewSrc.indexOf('(result.cycle.needs_recalculation')) + ": '')".length);

test('الشارة موصولة فعلاً بالعلم الخادمي، لا بحالة الدورة المشتقّة محلياً', () => {
  assert.match(badgeExpr, /result\.cycle\.needs_recalculation/);
  assert.match(badgeExprFull, /recalculation_reason/);
  assert.match(badgeExprFull, /أعد الحساب/, 'يجب أن تُشير الشارة إلى الفعل الصريح المتاح');
});

function run(result) {
  const js = ts.transpileModule(`
    ${escFn}
    ${insightFn}
    module.exports.render = (result) => ${badgeExprFull};
  `, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  const sandboxModule = { exports: {} };
  // eslint-disable-next-line no-new-func
  new Function('module', 'exports', js)(sandboxModule, sandboxModule.exports);
  return sandboxModule.exports.render(result);
}

test('علمٌ مرفوع مع سبب → شارة تحذيرية تحمل السبب وتوجّه إلى «أعد الحساب»', () => {
  const html = run({ cycle: {
    needs_recalculation: true,
    recalculation_reason: 'الأب "فلان" أُعيد تصنيفه من NEEDS_REVIEW إلى RESELLER',
  } });
  assert.match(html, /بحاجة لإعادة حساب/);
  assert.match(html, /أُعيد تصنيفه من NEEDS_REVIEW إلى RESELLER/);
  assert.match(html, /أعد الحساب/);
});

test('علمٌ مرفوع بلا سبب مسجَّل → نصٌّ افتراضي معقول، لا فراغ', () => {
  const html = run({ cycle: { needs_recalculation: true, recalculation_reason: null } });
  assert.match(html, /تغيّرت بيانات أساس منذ آخر حساب/);
});

test('علمٌ غير مرفوع → لا شارة إطلاقاً', () => {
  const html = run({ cycle: { needs_recalculation: false, recalculation_reason: null } });
  assert.equal(html, '');
});
