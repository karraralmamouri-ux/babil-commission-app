const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const reports = fs.readFileSync(path.join(root, 'src', 'features', 'reports', 'index.ts'), 'utf8');
const audit = fs.readFileSync(path.join(root, 'src', 'features', 'audit', 'index.ts'), 'utf8');

test('تقرير العمولات يستهلك عقد التقرير الخادمي ويبقي الملكية غير المحسومة خارجه', () => {
  assert.match(reports, /pattern: '\/reports\/commissions'/);
  assert.match(reports, /readCycleResult\(id\)/);
  assert.match(reports, /commission_report_product/);
  assert.match(reports, /knownAgentTotal\(result\)/);
  assert.match(reports, /'الملكية غير المحسومة': unresolved\.amount/);
});

test('تفصيل التقرير والجاهز يأتيان من عقد القراءة الخادمي', () => {
  for (const field of ['p35_count','p45_count','p65_count','tier_basis','calculated','approved','ready','paid']) {
    assert.match(reports, new RegExp(field));
  }
  assert.doesNotMatch(reports, /تفصيل FDT \/ Tier .* غير متاح/);
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
