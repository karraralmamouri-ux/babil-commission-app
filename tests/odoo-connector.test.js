const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const CLIENT = path.join(ROOT, 'supabase/functions/_shared/odoo-client.ts');
const FUNCTION = path.join(ROOT, 'supabase/functions/odoo-lookup/index.ts');
const RULES = path.join(ROOT, 'supabase/functions/_shared/odoo-rules.mjs');
const clientSrc = fs.readFileSync(CLIENT, 'utf8');
const rulesSrc = fs.readFileSync(RULES, 'utf8');
// التعليقات تُجرَّد قبل أي فحص نصّي: شرحٌ يذكر ilike أو create ليس استدعاءً،
// وهي نفس الحالة التي جعلت ماسح المهاجرات يقرأ TRUNCATE من نثر عربي.
function stripComments(src) {
  // مسح بالمواضع لا بتعبير نمطي: الهروب في التعبير النمطي هشّ، وهذا يقرأ
  // كما يقرأ المحلّل — يفتح عند /* ويغلق عند */ ثم يقصّ سطور //.
  let out = '';
  let i = 0;
  while (i < src.length) {
    const open = src.indexOf('/*', i);
    if (open === -1) { out += src.slice(i); break; }
    out += src.slice(i, open);
    const close = src.indexOf('*/', open + 2);
    if (close === -1) break;
    i = close + 2;
  }
  return out.split('\n').map((line) => {
    const at = line.indexOf('//');
    return at === -1 ? line : line.slice(0, at);
  }).join('\n');
}
const clientCode = stripComments(clientSrc);
const rulesCode = stripComments(rulesSrc);
const functionSrc = fs.readFileSync(FUNCTION, 'utf8');

// القواعد النقيّة تعيش في odoo-rules.mjs ويستوردها العميل نفسه، فلا توجد
// نسخة ثانية تتباعد. الاختبارات تستوردها مباشرةً؛ والعميل والدالة الطرفية
// يُفحصان نصّاً لأنهما يحتاجان Deno — وهذا الفحص هو ما يمنع تسرّب دالة كتابة.

let matchInvoice, mapInvoiceState, redact;
test.before(async () => {
  const rules = await import(
    require('node:url').pathToFileURL(
      path.join(ROOT, 'supabase/functions/_shared/odoo-rules.mjs')).href);
  ({ matchInvoice, mapInvoiceState, redact } = rules);
});

// ---------------------------------------------------------------------------
// السرّية
// ---------------------------------------------------------------------------

test('الأسرار لا تظهر في نص خطأ مُعاد', () => {
  const leak = 'error calling authenticate: {"password":"sk-live-abc123","login":"user@x"}';
  const safe = redact(leak);
  assert.ok(!safe.includes('sk-live-abc123'), 'مفتاح ظهر بعد التنقية');
  assert.ok(safe.includes('[REDACTED]'));
});

test('مصفوفة معاملات الاعتماد تُنقّى — وهي أخطر موضع', () => {
  // أودو يُعيد أحياناً الطلب كاملاً: [db, login, password, {}]
  const leak = 'args: ["odoo", "someone@example.com", "sk-live-secret", {}]';
  const safe = redact(leak);
  assert.ok(!safe.includes('sk-live-secret'), 'كلمة السر ظهرت في مصفوفة المعاملات');
});

test('التنقية تشمل صيغاً مختلفة للمفاتيح', () => {
  ['api_key=abc123', '"apikey": "abc123"', "token: 'abc123'", '"secret":"abc123"']
    .forEach((sample) => {
      assert.ok(!redact(sample).includes('abc123'), 'لم يُنقَّ: ' + sample);
    });
});

test('التنقية تحدّ الطول فلا يتضخّم سجلّ بخطأ ضخم', () => {
  assert.ok(redact('x'.repeat(5000)).length <= 1001);
});

test('لا سرّ في أي ملف مُودَع', () => {
  [clientSrc, functionSrc].forEach((src) => {
    assert.ok(!/sk-[A-Za-z0-9_-]{16,}/.test(src), 'مفتاح يشبه سرّاً في المصدر');
    // السرّ يُقرأ من البيئة فقط.
    assert.ok(!/ODOO_API_KEY\s*=\s*["'][^"']+["']/.test(src), 'مفتاح مكتوب حرفياً');
  });
  assert.ok(functionSrc.includes("Deno.env.get('ODOO_API_KEY')"),
    'المفتاح لا يُقرأ من البيئة');
});

// ---------------------------------------------------------------------------
// منع الكتابة
// ---------------------------------------------------------------------------

test('لا طريقة كتابة في قائمة الطرق المسموحة', () => {
  // القائمة تعيش في وحدة القواعد ويستوردها العميل، فتُقرأ من مصدرها الواحد.
  const list = rulesCode.match(/ODOO_READ_METHODS = \[([\s\S]*?)\]/);
  assert.ok(list, 'قائمة الطرق غير موجودة');
  ['create', 'write', 'unlink', 'action_post', 'button_', 'copy']
    .forEach((m) => assert.ok(!list[1].includes(m), `طريقة كتابة في القائمة: ${m}`));
});

test('العميل لا يستدعي أي طريقة كتابة في أودو', () => {
  // النداءات تمرّ كلها بـexecuteRead، وهي تفحص القائمة البيضاء.
  ['"create"', "'create'", '"write"', "'write'", '"unlink"', "'unlink'",
   'action_post', 'action_invoice_open', 'js_assign_outstanding_line']
    .forEach((m) => {
      assert.ok(!clientCode.includes(m), `العميل يذكر طريقة كتابة: ${m}`);
    });
});

test('executeRead يرفض ما ليس قراءة', () => {
  assert.ok(/ODOO_READ_METHODS as readonly string\[\]\)\.includes\(method\)/.test(clientSrc)
    || /includes\(method\)/.test(clientSrc), 'لا فحص للقائمة البيضاء');
  assert.ok(clientSrc.includes('ODOO_WRITE_BLOCKED'), 'لا خطأ مخصّص لمنع الكتابة');
});

test('الدالة الطرفية لا تعرض فعلاً يكتب', () => {
  const actions = [...functionSrc.matchAll(/action === '([a-z-]+)'/g)].map((m) => m[1]);
  assert.deepEqual(actions.sort(),
    ['fields', 'find-invoices', 'find-partner', 'verify-invoice', 'version']);
});

// ---------------------------------------------------------------------------
// الصلاحية والحدود
// ---------------------------------------------------------------------------

test('كل طلب يتحقق من مستخدم بابل ثم من قدرته', () => {
  assert.ok(functionSrc.includes('supabase.auth.getUser(token)'), 'الهوية غير مُتحقَّقة');
  assert.ok(functionSrc.includes("p_capability: 'odoo.read'"), 'القدرة غير مفحوصة');
  assert.ok(functionSrc.includes('allowed !== true'), 'الفحص لا يمنع فعلياً');
  // الترتيب مهم: الهوية ثم القدرة ثم أودو.
  assert.ok(functionSrc.indexOf('getUser(token)') < functionSrc.indexOf("'odoo.read'"));
  assert.ok(functionSrc.indexOf("'odoo.read'") < functionSrc.indexOf('authenticate(config)'));
});

test('النماذج المسموح استكشافها محصورة', () => {
  assert.ok(functionSrc.includes("['res.partner', 'account.move'].includes(model)"),
    'أي نموذج يمكن استكشافه');
});

test('الحقول المُعادة محصورة ولا تشمل هوية حسّاسة', () => {
  const partnerFields = functionSrc.match(/PARTNER_SAFE_FIELDS = \[([\s\S]*?)\]/);
  assert.ok(partnerFields, 'قائمة حقول الشريك غير موجودة');
  ['vat', 'phone', 'mobile', 'email', 'national'].forEach((f) => {
    assert.ok(!partnerFields[1].includes(`'${f}'`), `حقل هوية مُعاد: ${f}`);
  });
});

// ---------------------------------------------------------------------------
// المطابقة
// ---------------------------------------------------------------------------

const invoices = [
  { id: 11, name: 'INV/2026/0011', ref: 'REF-A', payment_reference: 'PR-1',
    invoice_origin: 'SO-1', state: 'posted', payment_state: 'not_paid',
    amount_total: 13000, amount_residual: 13000, move_type: 'out_invoice' },
  { id: 12, name: 'INV/2026/0012', ref: 'REF-B', payment_reference: 'PR-2',
    invoice_origin: 'SO-2', state: 'posted', payment_state: 'paid',
    amount_total: 3000, amount_residual: 0, move_type: 'out_invoice' },
];

test('المعرّف الصريح أقوى دليل', () => {
  const m = matchInvoice(invoices, { explicitOdooInvoiceId: 12 });
  assert.equal(m.tier, 'EXPLICIT_ID');
  assert.equal(m.invoice.id, 12);
});

test('المرجع التام يُطابق', () => {
  assert.equal(matchInvoice(invoices, { reference: 'REF-A' }).tier, 'EXACT_REFERENCE');
  assert.equal(matchInvoice(invoices, { reference: 'INV/2026/0012' }).invoice.id, 12);
  assert.equal(matchInvoice(invoices, { reference: 'PR-1' }).invoice.id, 11);
});

test('المصدر التام يُطابق حين لا مرجع', () => {
  const m = matchInvoice(invoices, { origin: 'SO-2' });
  assert.equal(m.tier, 'PARTNER_AND_ORIGIN');
  assert.equal(m.invoice.id, 12);
});

test('تعدد المطابقات مراجعة لا ترجيح', () => {
  const dupes = [
    { id: 1, ref: 'SAME', state: 'posted' },
    { id: 2, ref: 'SAME', state: 'posted' },
  ];
  const m = matchInvoice(dupes, { reference: 'SAME' });
  assert.equal(m.tier, 'REVIEW');
  assert.equal(m.invoice, null);
  assert.equal(m.candidates, 2);
  assert.equal(m.reason, 'AMBIGUOUS_REFERENCE');
});

test('لا فاتورة يعني مراجعة لا فراغ صامت', () => {
  const m = matchInvoice([], { reference: 'X' });
  assert.equal(m.tier, 'REVIEW');
  assert.equal(m.reason, 'NO_INVOICE_FOUND');
});

test('مرشّح وحيد بلا مرجع لا يُعتمَد تلقائياً', () => {
  const m = matchInvoice([invoices[0]], {});
  assert.equal(m.tier, 'REVIEW');
  assert.equal(m.invoice, null);
  assert.equal(m.reason, 'SINGLE_CANDIDATE_WITHOUT_REFERENCE');
});

test('لا مطابقة بالمبلغ أو التاريخ وحدهما', () => {
  const m = matchInvoice(invoices, {});
  assert.equal(m.tier, 'REVIEW');
  // مبلغان متساويان في يوم واحد شائعان؛ ترجيح أحدهما إسنادُ مالٍ بلا دليل.
  // يُقارَن السبب صراحةً: تعبيرٌ نمطي عن date التقط DATE داخل CANDIDATES.
  assert.equal(m.reason, 'MULTIPLE_CANDIDATES');
  assert.equal(m.invoice, null);
});

// ---------------------------------------------------------------------------
// تحويل الحالة
// ---------------------------------------------------------------------------

test('الفاتورة المُرحَّلة تُصبح FOUND لا VERIFIED', () => {
  const r = mapInvoiceState(invoices[0]);
  // الاعتماد فعل بشري؛ أفضل ما يُنتجه التحويل FOUND.
  assert.equal(r.babilStatus, 'FOUND');
  assert.notEqual(r.babilStatus, 'VERIFIED');
});

test('المسوّدة والملغاة تحتاجان مراجعة', () => {
  assert.equal(mapInvoiceState({ state: 'draft' }).babilStatus, 'NEEDS_REVIEW');
  assert.equal(mapInvoiceState({ state: 'draft' }).reason, 'ODOO_INVOICE_DRAFT');
  assert.equal(mapInvoiceState({ state: 'cancel' }).babilStatus, 'NEEDS_REVIEW');
  assert.equal(mapInvoiceState({ state: 'cancel' }).reason, 'ODOO_INVOICE_CANCELLED');
});

test('حالة غير معروفة تُراجَع ولا تُفترض سليمة', () => {
  const r = mapInvoiceState({ state: 'some_future_state' });
  assert.equal(r.babilStatus, 'NEEDS_REVIEW');
  assert.ok(r.reason.includes('some_future_state'));
});

test('غياب الفاتورة MISSING', () => {
  assert.equal(mapInvoiceState(null).babilStatus, 'MISSING');
});

test('حقائق أودو تُحفظ منفصلة ولا تُختزل', () => {
  const r = mapInvoiceState(invoices[1]);
  assert.equal(r.odoo.odoo_state, 'posted');
  assert.equal(r.odoo.odoo_payment_state, 'paid');
  assert.equal(r.odoo.amount_total, 3000);
  assert.equal(r.odoo.amount_residual, 0);
  // لا اختزال إلى صواب/خطأ.
  assert.ok(!('approved' in r.odoo));
});

test('حالة الدفع الخام تُحفظ ولا تُترجم إلى قيم مفترضة', () => {
  // قيم أودو 17 الحقيقية تُحفظ كما وردت؛ لا خريطة مُسبقة من إصدار آخر.
  ['not_paid', 'in_payment', 'paid', 'partial', 'reversed', 'blocked', 'invoicing_legacy']
    .forEach((ps) => {
      const r = mapInvoiceState({ state: 'posted', payment_state: ps });
      assert.equal(r.odoo.odoo_payment_state, ps);
    });
});

// ---------------------------------------------------------------------------
// الانقطاع
// ---------------------------------------------------------------------------

test('انقطاع أودو له رمز خاص ولا يُنتج نجاحاً', () => {
  assert.ok(clientSrc.includes('ODOO_UNAVAILABLE'));
  assert.ok(functionSrc.includes("error.code === 'ODOO_UNAVAILABLE' ? 503"),
    'الانقطاع لا يُعاد بحالة صحيحة');
  // لا مسار يحوّل انقطاعاً إلى اعتماد.
  assert.ok(!/ODOO_UNAVAILABLE[\s\S]{0,200}VERIFIED/.test(functionSrc));
});

test('المهلة مضبوطة فلا يتعلّق الطلب', () => {
  assert.ok(clientSrc.includes('AbortController'));
  assert.ok(clientSrc.includes('timeoutMs'));
});

test('غياب التهيئة يُعلَن ولا يُعامَل عطلاً', () => {
  assert.ok(clientSrc.includes('ODOO_NOT_CONFIGURED'));
  assert.ok(functionSrc.includes("error: 'ODOO_NOT_CONFIGURED'"));
});

test('حقول مفتاح الشريك تُضبَط ولا تُخمَّن', () => {
  // أسماء الحقول المخصّصة تختلف بين تركيب وآخر؛ تخمينها بحثٌ يفشل صامتاً.
  assert.ok(functionSrc.includes('ODOO_PARTNER_KEY_FIELDS'),
    'حقول المفتاح غير قابلة للضبط');
});

test('البحث عن الشريك حتمي لا تقريبي', () => {
  assert.ok(!/ilike/i.test(clientCode), 'بحث تقريبي في العميل');
  assert.ok(clientCode.includes("[field, '=', clean]"), 'المطابقة ليست تامة');
});

test('فواتير العميل محصورة بأنواع البيع', () => {
  assert.ok(clientSrc.includes("['out_invoice', 'out_refund']"),
    'نوع الحركة غير مقيَّد — قد تُقرأ قيود محاسبية ليست فواتير');
});
