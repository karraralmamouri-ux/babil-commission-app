// خلل "KPI من صفحة مُجزَّأة" — المسجَّل صراحةً في مراجعة PR-B3.
//
// كانت استبعادات/إضافات فعّالة في شاشة /commissions/corrections تُحتسَب من
// page.rows — صفحة الخمسين الحالية فقط — بينما تُعرَض كإجماليٍ عامّ على كل
// الدورة. فتغيير حجم الصفحة أو الإزاحة (offset) كان يُغيّر الرقم المعروض
// رغم أن المجموعة الفعلية لم تتغيّر. الإصلاح: page_activation_corrections
// (في 20261014090000_activation_corrections_scope_and_kpi.sql) يُعيد
// active_exclusions/active_additions كإجماليين خادميين على كامل المجموعة
// المُرشَّحة، والواجهة تقرأ منهما مباشرةً لا من page.rows.filter(...).
//
// الاختبار الأول يُثبت بنيوياً أن المصدر لم يعد يحسب من page.rows إطلاقاً.
// والثاني يُنفِّذ التعبير الحقيقي المُستخرَج من المصدر (لا نسخة معاد كتابتها)
// على صفحتين مختلفتي الحجم والإزاحة لنفس المجموعة، ويُثبت تطابق الناتج.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require('typescript');

const root = path.join(__dirname, '..');
const src = fs.readFileSync(path.join(root, 'src', 'features', 'commissions', 'corrections.ts'), 'utf8')
  .split('\r\n').join('\n');

test('لا احتساب من page.rows: استبعادات/إضافات فعّالة لم تعد صدفةً محليّة', () => {
  assert.doesNotMatch(src, /page\.rows\.filter/,
    'رجوعٌ إلى احتساب KPI من صفحة مُجزَّأة بدل إجماليٍ خادميّ');
  assert.match(src, /const excluded = num\(raw, 'active_exclusions'\);/);
  assert.match(src, /const added = num\(raw, 'active_additions'\);/);
});

test('حجم الصفحة والإزاحة لا يُغيّران الإجمالي المعروض — نفس المجموعة، صفحتان مختلفتان', () => {
  const numMatch = src.match(/const num = \([^)]*\) => [^;]+;/);
  assert.ok(numMatch, 'تعريف num() لم يوجد بالشكل المتوقَّع');

  const excludedLine = src.match(/const excluded = num\(raw, 'active_exclusions'\);/)[0];
  const addedLine = src.match(/const added = num\(raw, 'active_additions'\);/)[0];

  const js = ts.transpileModule(`
    ${numMatch[0]}
    ${excludedLine}
    ${addedLine}
    module.exports = { excluded, added };
  `, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;

  const run = (raw) => {
    const sandboxModule = { exports: {} };
    // eslint-disable-next-line no-new-func
    new Function('module', 'exports', 'raw', js)(sandboxModule, sandboxModule.exports, raw);
    return sandboxModule.exports;
  };

  // نفس المجموعة الفعلية (12 استبعاداً فعّالاً، 3 إضافات فعّالة) — لكن
  // صفحتان مختلفتان تماماً: limit=50/offset=0 مقابل limit=1/offset=40.
  const fullPageOfFilteredSet = {
    rows: new Array(50).fill({ status: 'ACTIVE', correction_type: 'EXCLUDE' }),
    total: 200, limit: 50, offset: 0,
    active_exclusions: 12, active_additions: 3,
  };
  const tinyOffsetPage = {
    rows: [{ status: 'ACTIVE', correction_type: 'ADD' }],
    total: 200, limit: 1, offset: 40,
    active_exclusions: 12, active_additions: 3,
  };

  const a = run(fullPageOfFilteredSet);
  const b = run(tinyOffsetPage);
  assert.deepEqual(a, { excluded: 12, added: 3 });
  assert.deepEqual(b, { excluded: 12, added: 3 });
  assert.deepEqual(a, b, 'الإجمالي يجب ألا يتغيّر بتغيّر حجم الصفحة أو الإزاحة');
});
