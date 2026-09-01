// تدقيق الفواتير بالجملة.
//
// نفس بنية تعليق الجملة حرفياً، مع فارقٍ جوهري: التطبيق لا يكتب فاتورة
// بنفسه، بل يستدعي review_invoice نفسها لكل صفٍّ مطابق — فأثر التدقيق
// بالجملة لا يمكن أن ينحرف عن أثر المراجعة اليدوية لأنه المسار نفسه حرفياً.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');

const invoicesUi = read('src/features/installation/invoices.ts');
const bulkSql = read('supabase/migrations/20261019090000_bulk_invoice_audit.sql');

/* ---- المعاينة: التصنيف السداسي، ولا كتابة فيها ---------------------------- */

test('المعاينة تفرز كل صفّ في دلوٍ واحد من ستة، ولا تكتب شيئاً', () => {
  for (const bucket of ['matched', 'unknown', 'duplicate', 'already_used', 'invalid', 'conflict']) {
    assert.ok(bulkSql.includes(`'${bucket}'`), `دلو مفقود: ${bucket}`);
  }
  const preview = bulkSql.slice(bulkSql.indexOf('function public.preview_bulk_invoice_upload'),
                                 bulkSql.indexOf('function public.apply_bulk_invoice_upload'));
  assert.match(preview, /\bstable\b/);
  assert.doesNotMatch(preview.replace(/--.*$/gm, ''), /insert\s+into/i);
});

test('نفس المشترك أكثر من مرّة في الرفعة نفسها = تعارض، لا تقدّم مرحلتين', () => {
  // هذا بالضبط سيناريو INV-007..009 الذي يحتاج قراراً معمارياً/مالياً غير
  // موجود اليوم — الملف يرفضه صراحةً بدل أن يخترع قاعدة تقدّم.
  assert.match(bulkSql, /j\.sub_times > 1 then 'conflict'/);
  assert.match(bulkSql, /INV-007\/008\/009/);
  assert.match(bulkSql, /BUSINESS_DECISIONS_REQUIRED\.md/);
});

/* ---- التطبيق: يعيد الحساب من الخادم، ويستدعي review_invoice فقط ----------- */

test('التطبيق لا يثق بمعاينة العميل: يعيد التصنيف كاملاً من الخادم', () => {
  const apply = bulkSql.slice(bulkSql.indexOf('function public.apply_bulk_invoice_upload'));
  // نفس فروع الـ case حرفياً مكرَّرة داخل الحلقة، لا مجرد قراءة لعمود bucket من العميل.
  assert.match(apply, /when j\.sub_times > 1 then 'conflict'/);
  assert.match(apply, /when not j\.looks_valid then 'invalid'/);
});

test('كل صفّ مطابق يمرّ عبر review_invoice نفسها — لا إدراج مباشر مكرَّر', () => {
  const apply = bulkSql.slice(bulkSql.indexOf('function public.apply_bulk_invoice_upload'));
  assert.match(apply, /perform public\.review_invoice\(/);
  assert.match(apply, /v_row\.subscriber_id, v_row\.current_stage, 'VERIFIED'/);
  // ولا إدراجٍ مباشر في installation_invoices من هذا الملف.
  assert.doesNotMatch(apply.replace(/--.*$/gm, ''), /insert\s+into\s+public\.installation_invoices/i);
});

test('فشل صفٍّ واحد داخل review_invoice لا يُسقط الرفعة كلّها', () => {
  const apply = bulkSql.slice(bulkSql.indexOf('function public.apply_bulk_invoice_upload'));
  assert.match(apply, /exception when others then\s*\n\s*v_skipped := v_skipped \+ 1;/);
});

test('الرفعة مُدقَّقة ومعرَّفة بطلب، وإعادة نفس الطلب هادئة', () => {
  assert.match(bulkSql, /request_id is required/);
  assert.match(bulkSql, /A bulk invoice decision must state its reason/);
  assert.match(bulkSql, /The source file must be named/);
  assert.match(bulkSql, /'installation\.invoice\.bulk_uploaded'/);
  assert.match(bulkSql, /where request_id = p_request_id/);
  assert.match(bulkSql, /'idempotent', true/);
});

test('المعاينة والتطبيق يحتاجان صلاحيتين مختلفتين', () => {
  const preview = bulkSql.slice(bulkSql.indexOf('function public.preview_bulk_invoice_upload'),
                                 bulkSql.indexOf('function public.apply_bulk_invoice_upload'));
  assert.match(preview, /require_capability\('invoice\.view'\)/);
  const apply = bulkSql.slice(bulkSql.indexOf('function public.apply_bulk_invoice_upload'));
  assert.match(apply, /require_capability\('invoice\.verify'\)/);
});

/* ---- الشاشة ---------------------------------------------------------------- */

test('قارئ الصفوف يُسقط سطر العنوان ويقبل ثلاثة أعمدة', () => {
  const src = invoicesUi.slice(invoicesUi.indexOf('function parseInvoiceRows'));
  const compiled = ts.transpileModule(
    src.slice(0, src.indexOf('function wireBulkInvoiceAudit')), { compilerOptions: { target: 'ES2022' } });
  const ctx = { module: { exports: {} } };
  vm.createContext(ctx);
  vm.runInContext(compiled.outputText + '\nmodule.exports = { parseInvoiceRows };', ctx);
  const raw = ctx.module.exports.parseInvoiceRows;
  // النتائج من سياق vm منفصل: تُنسَخ إلى كائنات هذا السياق قبل المقارنة، فلا
  // يفشل التطابق البنيوي لمجرّد اختلاف الواقع (realm).
  const parseInvoiceRows = (t) => JSON.parse(JSON.stringify(raw(t)));

  assert.deepEqual(
    parseInvoiceRows('subscriber_id,invoice_number,invoice_date\na-1,INV-1,2026-09-01'),
    [{ subscriber_id: 'a-1', invoice_number: 'INV-1', invoice_date: '2026-09-01' }]);
  assert.deepEqual(
    parseInvoiceRows('a-1,INV-1,2026-09-01\na-2,INV-2,2026-09-02'),
    [{ subscriber_id: 'a-1', invoice_number: 'INV-1', invoice_date: '2026-09-01' },
     { subscriber_id: 'a-2', invoice_number: 'INV-2', invoice_date: '2026-09-02' }]);
  // عمودٌ أوّل عربيّ العنوان يُسقَط أيضاً.
  assert.deepEqual(
    parseInvoiceRows('المشترك,رقم,تاريخ\nb-1,INV-3,2026-09-03'),
    [{ subscriber_id: 'b-1', invoice_number: 'INV-3', invoice_date: '2026-09-03' }]);
  // سطرٌ بلا معرّف مشترك يُسقَط.
  assert.deepEqual(parseInvoiceRows('a-1,INV-1,2026-09-01\n,INV-2,2026-09-02'),
    [{ subscriber_id: 'a-1', invoice_number: 'INV-1', invoice_date: '2026-09-01' }]);
});

test('لا يُطبَّق تدقيق قبل معاينة، ولا بلا سبب', () => {
  assert.match(invoicesUi, /if \(!previewed\.length\)/);
  assert.match(invoicesUi, /السبب إلزامي/);
  assert.match(invoicesUi, /p_request_id: crypto\.randomUUID\(\)/);
  // والزرّ لا يُفتح إلا إذا كان هناك ما سيُدقَّق فعلاً.
  assert.match(invoicesUi, /apply\.disabled = Number\(counts\['matched'\] \|\| 0\) === 0/);
});

test('الشاشة تستدعي المعاينة والتطبيق بالاسمين الصحيحين', () => {
  assert.match(invoicesUi, /rpc<Row>\('preview_bulk_invoice_upload', \{ p_rows: list \}\)/);
  assert.match(invoicesUi, /rpc<Row>\('apply_bulk_invoice_upload', \{/);
  assert.match(invoicesUi, /p_filename: filename \|\| 'لصق يدوي'/);
});

test('المسار مسجَّل ولا يتكرّر نمطه', () => {
  const inst = read('src/features/installation/index.ts');
  assert.match(inst, /routes as invoiceRoutes/);
  assert.match(inst, /\.\.\.invoiceRoutes,/);
  assert.match(invoicesUi, /export const routes: Route\[\] = \[invoiceReview, bulkInvoiceAudit\];/);

  const patterns = [...invoicesUi.matchAll(/pattern: '([^']+)'/g)].map((m) => m[1]);
  assert.equal(new Set(patterns).size, patterns.length, `نمط مكرّر: ${patterns.join(', ')}`);
  assert.ok(patterns.includes('/installation/invoices/bulk'));
});
