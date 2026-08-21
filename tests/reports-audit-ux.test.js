const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const reports = fs.readFileSync(path.join(root, 'src', 'features', 'reports', 'index.ts'), 'utf8');
const audit = fs.readFileSync(path.join(root, 'src', 'features', 'audit', 'index.ts'), 'utf8');

test('تقرير العمولات يستهلك عقد الدورة ويصدر بند الملكية غير المحسومة', () => {
  assert.match(reports, /pattern: '\/reports\/commissions'/);
  assert.match(reports, /readCycleResult\(id\)/);
  assert.match(reports, /allocation: 'UNRESOLVED'/);
  assert.match(reports, /knownAgentTotal\(result\)/);
  assert.match(reports, /'الملكية غير المحسومة': unresolved\.amount/);
});

test('التقرير لا يخترع تفاصيل غير موجودة في عقد القراءة', () => {
  assert.match(reports, /تفصيل FDT \/ Tier \/ P35 \/ P45 \/ P65 والجاهز للصرف غير متاح/);
  assert.match(reports, /يحتاج عقد تقرير خادمي موحّداً واختبارات قاعدة بيانات خضراء/);
});

test('حركة الدفتر تعرض اتجاه الخادم ولا تعيد حساب المبلغ في المتصفح', () => {
  assert.doesNotMatch(reports, /num\(r, 'amount'\) \* \(num\(r, 'direction'\)/);
  assert.match(reports, /num\(r, 'direction'\) < 0 \? 'قيد عكسي'/);
});

test('الأرشيف يفصل المقفل عن الدورة القديمة غير المكتملة', () => {
  assert.match(reports, /status'\) === 'CLOSED'/);
  assert.match(reports, /دورات تاريخها قديم لكنها غير مكتملة/);
  assert.match(reports, /دورات مقفلة تاريخياً/);
  assert.match(reports, /قِدم التاريخ لا يعني اكتمال الدورة/);
});

test('التدقيق يبدأ بمن ومتى والكيان وقبل وبعد ويطوي التقنية', () => {
  for (const label of ['من؟', 'متى؟', 'أي كيان؟', 'قبل', 'بعد', 'لماذا؟']) {
    assert.match(audit, new RegExp(`label: '${label.replace('؟', '؟')}'`));
  }
  assert.match(audit, /بتوقيت بغداد/);
  assert.match(audit, /تفاصيل تقنية/);
  assert.match(audit, /request_id/);
  assert.match(audit, /entity_id/);
});

test('تعذر facets في التدقيق لا يظهر كمرشحات فارغة سليمة', () => {
  assert.doesNotMatch(audit, /audit_facets[^\n]*\.catch/);
  assert.doesNotMatch(audit, /\.catch\(\(\) => null\)/);
});
