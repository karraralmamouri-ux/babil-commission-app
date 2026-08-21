const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'src', 'features', 'installation', 'invoices.ts'), 'utf8');
const css = fs.readFileSync(path.join(root, 'assets', 'css', 'babil-flow.css'), 'utf8');

test('مراجعة الفاتورة تفتح في درج مركز ولا تهبط أسفل طابور طويل', () => {
  assert.match(source, /class="drawer review-drawer"/);
  assert.match(source, /review-drawer-backdrop/);
  assert.doesNotMatch(source, /id="reviewHost"/);
  assert.match(css, /\.review-drawer \{/);
});

test('قرار الفاتورة يبدأ بلا اختيار ولا يفترض التدقيق', () => {
  assert.match(source, /<option value="" selected disabled>اختر القرار<\/option>/);
  assert.match(source, /if \(!status\.value\)/);
});

test('حفظ المراجعة لا يعيد تحميل الصفحة ويحافظ على موضع الطابور', () => {
  assert.doesNotMatch(source, /window\.location\.reload/);
  assert.match(source, /updateVisibleRow\(view, index, row\)/);
  assert.match(source, /data-review-prev/);
  assert.match(source, /data-review-next/);
});

test('درج المراجعة يعرض أدلة المصدر والعائدية والحجب قبل القرار', () => {
  for (const key of ['invoice_source', 'invoice_reference', 'invoice_date', 'ownership', 'held', 'eligible']) {
    assert.match(source, new RegExp(`['"]${key}['"]`), `${key} غير معروض`);
  }
  assert.match(source, /الأدلة المتاحة/);
});

test('صلاحية القرار تبقى مفصولة بين التدقيق والرفض', () => {
  assert.match(source, /can\('invoice\.verify'\)/);
  assert.match(source, /can\('invoice\.reject'\)/);
  assert.match(source, /review_invoice/);
  assert.match(source, /p_request_id: crypto\.randomUUID\(\)/);
});
