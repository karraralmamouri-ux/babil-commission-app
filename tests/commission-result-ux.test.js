const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const source = fs.readFileSync(path.join(__dirname, '..', 'src', 'features', 'commissions', 'index.ts'), 'utf8');

test('شاشة الدورة تقرأ عقد النتيجة الموحّد مرة ولا تعود لعقد الجدول القديم', () => {
  assert.doesNotMatch(source, /report_commission_cycle_detail/);
  const body = source.slice(source.indexOf('async function renderCycle('), source.indexOf('function scopeTable('));
  assert.equal((body.match(/readCycleResult\(id\)/g) || []).length, 1);
  assert.match(body, /renderCycleTab\(view, cycle, result, tab, m\)/);
});

test('نتيجة الدورة تفصل المال عن الحجم التشغيلي ولا تسمي المحسوب مستحقاً', () => {
  assert.match(source, /عمولة محسوبة/);
  assert.match(source, /معتمد/);
  assert.match(source, /مدفوع/);
  assert.match(source, /النتيجة التشغيلية/);
  assert.match(source, /ليست مستحقاً معتمداً/);
});

test('الأحداث تعطي الأولوية للمشترك والعمولة ووقت بغداد وتخفي المعرّف تقنياً', () => {
  assert.match(source, /label: 'المشترك'/);
  assert.match(source, /label: 'العمولة'/);
  assert.match(source, /dateTime\(r\['event_at'\]\)/);
  assert.match(source, /تفاصيل تقنية/);
  assert.match(source, /scope_type/);
  assert.match(source, /scope_id/);
});

test('الاستثناءات تقود بتسمية عمل بشرية وتبقي الكود في التفاصيل التقنية', () => {
  assert.match(source, /UNKNOWN_FDT: 'كابينة تحتاج تصنيف'/);
  assert.match(source, /UNKNOWN_AGENT: 'الوكيل غير معروف'/);
  assert.match(source, /SOURCE_INCOMPLETE: 'بيانات المصدر غير مكتملة'/);
  assert.match(source, /<code>\$\{esc\(r\['reason_code'\]\)\}<\/code>/);
});

test('ملف الوكيل لا يخترع ملخصاً مالياً من تجميع المتصفح', () => {
  assert.doesNotMatch(source, /cycleRows\.reduce/);
  assert.match(source, /الملخص المالي الموحّد غير متاح من عقد القراءة الحالي/);
  assert.match(source, /\/master\/fdts\/\$\{encodeURIComponent\(f\)\}/);
  assert.match(source, /الأسماء البديلة والتفاصيل التقنية/);
});

test('تبويب تدقيق الدورة لا يعرض تدقيق كل الدورات كأنه مقيّد بالدورة', () => {
  assert.match(source, /عقد التدقيق الحالي يرشّح بنوع الكيان ولا يقبل معرّف الدورة/);
  const auditTab = source.slice(source.indexOf("if (tab === 'audit')"), source.indexOf('// overview'));
  assert.doesNotMatch(auditTab, /list_audit_events/);
});
