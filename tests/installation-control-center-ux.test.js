const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'src', 'features', 'installation', 'index.ts'), 'utf8');
const work = fs.readFileSync(path.join(root, 'src', 'features', 'work', 'index.ts'), 'utf8');

test('مركز التنصيب يقرأ المرشّح والجاهز من عقود الخادم ولا يخلطهما', () => {
  assert.match(source, /installation_cycle_pipeline/);
  assert.match(source, /installation_payout_candidates/);
  assert.match(source, /label: 'مرشّح للصرف'/);
  assert.match(source, /label: 'جاهز للصرف'/);
  assert.doesNotMatch(source, /label: 'مستحق حالي'/);
});

test('المراحل P1 إلى P4 تعرض العدد والمبلغ الخادمي وDONE مستقلة', () => {
  assert.match(source, /\['P1', 'P2', 'P3', 'P4'\]/);
  assert.match(source, /by_stage/);
  assert.match(source, /num\(byStage\[stage\].*'amount'\)/s);
  assert.match(source, /chip\('DONE', 'success'\)/);
});

test('الحالات التاريخية غير المحسومة تبقى ظاهرة وتقود إلى قرارها', () => {
  assert.match(source, /historical_unresolved_subscribers/);
  assert.match(source, /تحتاج حسم تاريخي/);
  assert.match(source, /href\('\/work\/historical'\)/);
  assert.match(source, /لا تُصنّف دون دليل/);
});

test('فشل مركز العمل لا يتحول إلى دورة فارغة صامتة', () => {
  assert.doesNotMatch(work, /commission_cycles[^\n]*\.catch/);
  assert.doesNotMatch(work, /\.catch\(\(\) => null\)/);
});
