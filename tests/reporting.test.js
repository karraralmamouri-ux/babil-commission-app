const test = require('node:test');
const assert = require('node:assert/strict');
const R = require('../assets/js/reporting.js');

test('حالة واحدة بمفردة واحدة في كل الشاشات', () => {
  assert.equal(R.statusLabel('FINALIZED'), 'معتمدة');
  assert.equal(R.statusLabel('PARTIALLY_PAID'), 'مدفوعة جزئياً');
  assert.equal(R.statusLabel('BLOCKED'), 'محجوبة');
  assert.equal(R.statusLabel(null), '—');
  assert.equal(R.statusLabel('SOMETHING_NEW'), 'SOMETHING_NEW');
});

test('كل حالة في مسار الدورة لها مفردة', () => {
  const missing = R.CYCLE_FLOW.filter((s) => !R.STATUS_LABELS[s]);
  assert.deepEqual(missing, [], 'حالات بلا مفردة: ' + missing.join(', '));
});

test('موضع الحالة في المسار يُقرأ تقدماً', () => {
  assert.equal(R.flowPosition('DRAFT').index, 0);
  assert.equal(R.flowPosition('CLOSED').index, R.CYCLE_FLOW.length - 1);
  assert.ok(R.flowPosition('PAID').index > R.flowPosition('FINALIZED').index);
  assert.equal(R.flowPosition('NOT_A_STATUS'), null);
});

const summary = {
  global: { total_obligations: 25000, total_paid: 12000, total_remaining: 13000,
    unresolved_cases: 4, current_cycle: 'أيلول', current_cycle_status: 'FINALIZED' },
  commission: { totals: { gross: 12000, net_paid: 12000, remaining: 0,
    unique_activated_subscribers: 2, qualifying_events: 3 } },
  installation: { due: 13000, paid: 0, ready: 5, held: 2 },
};

test('البطاقات تقرأ ما حسبه الخادم ولا تُعيد حسابه', () => {
  const cards = R.summaryCards(summary);
  const by = new Map(cards.map((c) => [c.key, c.value]));
  assert.equal(by.get('obligations'), 25000);
  assert.equal(by.get('remaining'), 13000);
  assert.equal(by.get('unresolved'), 4);
  assert.equal(by.get('subscribers'), 2);
  assert.equal(by.get('events'), 3);
  assert.equal(by.get('inst_held'), 2);
});

test('كل بطاقة تنزل إلى مصدرها', () => {
  R.summaryCards(summary).forEach((card) => {
    assert.ok(card.drill, `البطاقة ${card.key} بلا وجهة نزول`);
  });
});

test('ردّ فارغ لا يكسر الشاشة', () => {
  assert.deepEqual(R.summaryCards(null), []);
  const cards = R.summaryCards({});
  assert.equal(cards.length, 8);
  assert.ok(cards.every((c) => c.value === 0));
});

const detail = [
  { gross: 7000, net_paid: 7000, remaining: 0 },
  { gross: 5000, net_paid: 5000, remaining: 0 },
];

test('المصالحة تقبل ما يتطابق', () => {
  const r = R.reconcile({ gross: 12000, net_paid: 12000, remaining: 0 }, detail);
  assert.equal(r.ok, true);
  assert.deepEqual(r.diffs, []);
});

test('المصالحة تمسك تعارضاً بين الملخّص والتفصيل', () => {
  const r = R.reconcile({ gross: 99999, net_paid: 12000, remaining: 0 }, detail);
  assert.equal(r.ok, false);
  assert.equal(r.diffs.length, 1);
  assert.equal(r.diffs[0].field, 'gross');
  assert.equal(r.diffs[0].summary, 99999);
  assert.equal(r.diffs[0].detail, 12000);
});

test('تفصيل فارغ مع ملخّص غير صفري تعارض لا صمت', () => {
  const r = R.reconcile({ gross: 5000, net_paid: 0, remaining: 5000 }, []);
  assert.equal(r.ok, false);
});

test('CSV يهرب الفاصلة والاقتباس والسطر الجديد', () => {
  assert.equal(R.csvField('عادي'), 'عادي');
  assert.equal(R.csvField('a,b'), '"a,b"');
  assert.equal(R.csvField('say "hi"'), '"say ""hi"""');
  assert.equal(R.csvField('line\nbreak'), '"line\nbreak"');
  assert.equal(R.csvField(null), '');
  assert.equal(R.csvField(0), '0');
});

test('CSV يبدأ بعلامة ترتيب البايتات ليفتح صحيحاً بالعربية', () => {
  const csv = R.toCsv([{ a: 1 }], [{ key: 'a', label: 'أ' }]);
  assert.equal(csv.charCodeAt(0), 0xfeff);
});

test('أعمدة التصدير مُملاة صراحةً لا مأخوذة من شكل الردّ', () => {
  const rows = [{ gross: 100, unexpected_new_column: 'x', zone: 'old' }];
  const csv = R.toCsv(rows, R.COMMISSION_EXPORT_COLUMNS);
  assert.ok(!csv.includes('unexpected_new_column'),
    'عمود جديد في الردّ تسرّب إلى التصدير');
  assert.ok(csv.includes('الإجمالي'));
  assert.ok(csv.includes('100'));
});

test('تصدير العمولة يحمل الحقول المطلوبة', () => {
  const keys = R.COMMISSION_EXPORT_COLUMNS.map((c) => c.key);
  ['cycle_name','scope_label','tier_code','unique_activated_subscribers',
   'qualifying_event_count','p35_count','p45_count','p65_count','gross','net_paid',
   'remaining','scheme_version_id'].forEach((k) => {
    assert.ok(keys.includes(k), `عمود مفقود من التصدير: ${k}`);
  });
});

test('تصدير الاستثناءات يحمل السبب والحجب', () => {
  const keys = R.EXCEPTION_EXPORT_COLUMNS.map((c) => c.key);
  assert.ok(keys.includes('reason_code'));
  assert.ok(keys.includes('blocking'));
  assert.ok(keys.includes('domain'));
});

test('الصفحة لا تتجاوز سقف الخادم', () => {
  assert.equal(R.pageParams(1, 100).limit, 100);
  assert.equal(R.pageParams(1, 999999).limit, R.MAX_PAGE);
  assert.equal(R.pageParams(1, 0).limit, 100, 'حجم غير موجب يعني غير محدَّد');
  assert.equal(R.pageParams(3, 50).offset, 100);
  assert.equal(R.pageParams(0, 50).offset, 0);
  assert.equal(R.pageParams(-5, 50).offset, 0);
});

test('معلومات الصفحة تُحسب من العدد الكلي', () => {
  const info = R.pageInfo(250, 2, 100);
  assert.equal(info.total, 250);
  assert.equal(info.pages, 3);
  assert.equal(info.current, 2);
  assert.equal(info.hasPrev, true);
  assert.equal(info.hasNext, true);
});

test('صفحة خارج المدى تُقيَّد إلى آخر صفحة موجودة', () => {
  const info = R.pageInfo(120, 99, 100);
  assert.equal(info.pages, 2);
  assert.equal(info.current, 2);
  assert.equal(info.hasNext, false);
});

test('لا نتائج يعني صفحة واحدة لا صفر', () => {
  const info = R.pageInfo(0, 1, 100);
  assert.equal(info.pages, 1);
  assert.equal(info.current, 1);
  assert.equal(info.hasNext, false);
});

test('الوحدة لا تحسب مالاً', () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const src = fs.readFileSync(path.join(__dirname, '../assets/js/reporting.js'), 'utf8');
  // المصالحة تجمع للمقارنة فقط؛ ولا يوجد اشتقاق لمبلغ مستحق أو شريحة.
  assert.ok(!/\b(4000|4750|5500|6000|8000|9000|11500|13000)\b/.test(src),
    'reporting.js يحمل مبلغاً مالياً ثابتاً');
  assert.ok(!/gross\s*[-*/]\s*/.test(src.replace(/gross - net_paid/g, '')),
    'reporting.js يشتق مبلغاً بدل قراءته');
});
