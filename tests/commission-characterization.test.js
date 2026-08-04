const assert = require('node:assert/strict');
const test = require('node:test');

const { loadCurrentApp } = require('./load-current-app');

function row(overrides = {}) {
  return {
    name: 'Test Agent',
    p35: 0,
    p45: 0,
    p65: 0,
    customTier: 'auto',
    paid: 0,
    ...overrides,
  };
}

test('automatic tier selection preserves the current boundary rules', () => {
  const app = loadCurrentApp();

  assert.equal(app.tierFor(0, 'auto'), null);
  assert.equal(app.tierFor(1, 'auto').key, 't1');
  assert.equal(app.tierFor(200, 'auto').key, 't1');
  assert.equal(app.tierFor(201, 'auto').key, 't2');
  assert.equal(app.tierFor(400, 'auto').key, 't2');
  assert.equal(app.tierFor(401, 'auto').key, 't3');
});

test('commission total uses the selected tier rate for each product', () => {
  const app = loadCurrentApp();
  const result = app.calc(row({ p35: 2, p45: 1, p65: 1 }));

  assert.equal(result.qty, 4);
  assert.equal(result.t.key, 't1');
  assert.equal(result.total, 21_500);
  assert.equal(result.paid, 0);
  assert.equal(result.remaining, 21_500);
});

test('manual tier selection overrides the automatic quantity tier', () => {
  const app = loadCurrentApp();
  const result = app.calc(row({ p35: 1, customTier: 't3' }));

  assert.equal(result.t.key, 't3');
  assert.equal(result.total, 6_000);
});

test('paid amount is clamped to the range from zero to amount due', () => {
  const app = loadCurrentApp();

  assert.equal(app.calc(row({ p35: 1, paid: -100 })).paid, 0);
  assert.equal(app.calc(row({ p35: 1, paid: 9_000 })).paid, 4_000);
});

test('payment status follows pending, partial, and paid boundaries', () => {
  const app = loadCurrentApp();

  assert.equal(app.status(row({ p35: 1, paid: 0 })), 'pending');
  assert.equal(app.status(row({ p35: 1, paid: 1_000 })), 'partial');
  assert.equal(app.status(row({ p35: 1, paid: 4_000 })), 'paid');
});

test('month key formats calendar months using MM/YYYY', () => {
  const app = loadCurrentApp();

  assert.equal(app.monthKey(new Date(2026, 0, 1)), '01/2026');
  assert.equal(app.monthKey(new Date(2026, 11, 1)), '12/2026');
});

test('CSV parser preserves quoted commas and escaped quotes', () => {
  const app = loadCurrentApp();
  const csv = 'Name,Zone,P35\n"Agent, One",OLD,"1"\n"Agent ""Two""",NEW,2';

  assert.deepEqual(JSON.parse(JSON.stringify(app.parseCSV(csv))), [
    { Name: 'Agent, One', Zone: 'OLD', P35: '1' },
    { Name: 'Agent "Two"', Zone: 'NEW', P35: '2' },
  ]);
});

test('import normalization supports Arabic headings and numeric separators', () => {
  const app = loadCurrentApp();
  const normalized = app.normalizeImport({
    'اسم الوكيل': 'وكيل اختبار',
    'المنطقة': 'جديد',
    P35: '1,200',
    P45: '4',
    P65: '1',
    'المدفوع': '25,000',
  });

  assert.deepEqual(JSON.parse(JSON.stringify(normalized)), {
    name: 'وكيل اختبار',
    p35: 1200,
    p45: 4,
    p65: 1,
    paid: 25000,
    paymentDate: '',
    customTier: 'auto',
    zone: 'new',
  });
});

test.todo('previous-period lookup works across December and January');
test.todo('new-month creation advances from the open period instead of the device date');
