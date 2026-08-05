const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');

const { loadCurrentApp } = require('./load-current-app');

function tiers() {
  return [
    { key: 't1', label: 'T1', min: 0, max: 200, p35: 4000, p45: 5500, p65: 8000 },
    { key: 't2', label: 'T2', min: 201, max: 400, p35: 4750, p45: 6000, p65: 9000 },
    { key: 't3', label: 'T3', min: 401, max: null, p35: 6000, p45: 8000, p65: 11500 },
  ];
}

function centralFixture() {
  return {
    months: [{ id: 'month-1', month_key: '09/2026', tiers: tiers() }],
    rows: [
      {
        id: 'row-1',
        month_id: 'month-1',
        zone: 'old',
        name: 'Agent A',
        p35: 2,
        p45: 1,
        p65: 0,
        custom_tier: 'auto',
        paid: 1000,
        payment_date: '2026-09-10',
        updated_at: '2026-09-10T00:00:00.000Z',
      },
    ],
  };
}

test('central export is validated and converted into the existing view model', () => {
  const { buildCentralPeriods } = loadCurrentApp();
  const { months, rows } = centralFixture();
  const periods = buildCentralPeriods(months, rows);
  const period = periods.get('09/2026');

  assert.equal(period.data.old.length, 1);
  assert.equal(period.data.old[0].customTier, 'auto');
  assert.equal(period.data.old[0].paymentDate, '2026-09-10');
  assert.equal(period.data.old[0].centralId, 'row-1');
  assert.equal(period.tiers[2].max, null);
});

test('central preview rejects invalid financial rows before rendering', () => {
  const { buildCentralPeriods } = loadCurrentApp();
  const { months, rows } = centralFixture();
  rows[0].paid = 999999999;

  assert.throws(() => buildCentralPeriods(months, rows), /يتجاوز المستحق/);
  rows[0].paid = 0;
  rows[0].p35 = -1;
  assert.throws(() => buildCentralPeriods(months, rows), /قيمة مركزية غير صالحة/);
  rows[0].p35 = 0;
  rows[0].p45 = 0;
  rows[0].custom_tier = 'missing';
  assert.throws(() => buildCentralPeriods(months, rows), /تعذر تحديد شريحة/);
});

test('central mode allows only audited payments and preserves a local return path', () => {
  const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');

  assert.match(html, /id="centralPreviewButton"/);
  assert.match(html, /البيانات المركزية المشتركة/);
  assert.match(html, /if\(p==='payment'\)return centralPreview\.active&&roleAllows\(p\)/);
  assert.match(html, /if\(centralPreview\.active\)\{toast\('لا يمكن الحفظ أثناء المعاينة المركزية'\);return\}/);
  assert.match(html, /centralPreview\.localState=clone\(state\)/);
  assert.match(html, /state=clone\(centralPreview\.localState\)/);
  assert.match(html, /function fetchCentralPages\(path,pageSize=500\)/);
  assert.match(html, /\/rest\/v1\/rpc\/record_commission_payment/);
  assert.doesNotMatch(html, /method:\s*['"](?:POST|PATCH|PUT|DELETE)['"][\s\S]{0,200}commission_(?:months|rows)/i);
});

test('central audit rows expose a readable shared payment action', () => {
  const { buildCentralAuditLogs } = loadCurrentApp();
  const logs = buildCentralAuditLogs([{
    id: 1,
    actor_id: 'accountant-1',
    created_at: '2026-09-10T12:00:00.000Z',
    month_key: '09/2026',
    zone: 'old',
    agent: 'Agent A',
    action: 'commission.payment.recorded',
    before_data: { paid: 0, payment_date: null },
    after_data: { paid: 1000, payment_date: '2026-09-10' },
  }], [{ id: 'accountant-1', full_name: 'Accountant' }]);

  assert.equal(logs[0].user, 'Accountant');
  assert.equal(logs[0].action, 'تسجيل صرف مركزي');
  assert.equal(logs[0].newValue, '1000 / 2026-09-10');
});

test('payment is sent to the atomic RPC with concurrency and idempotency values', async () => {
  let request;
  const app = loadCurrentApp({
    fetch: async (url, options) => {
      request = { url, options };
      return {
        ok: true,
        status: 200,
        async text() {
          return JSON.stringify({ row: { id: 'row-1' }, replayed: false });
        },
      };
    },
  });
  app.setSbSession({ access_token: 'access', refresh_token: 'refresh', expires_at: Math.floor(Date.now() / 1000) + 3600 });

  await app.recordCentralPayment(
    { centralId: 'row-1', centralUpdatedAt: '2026-09-10T00:00:00.000Z' },
    1000,
    '2026-09-10',
    'request-1',
  );

  assert.match(request.url, /\/rest\/v1\/rpc\/record_commission_payment$/);
  assert.equal(request.options.headers.Authorization, 'Bearer access');
  assert.deepEqual(JSON.parse(request.options.body), {
    p_row_id: 'row-1',
    p_expected_updated_at: '2026-09-10T00:00:00.000Z',
    p_paid: 1000,
    p_payment_date: '2026-09-10',
    p_request_id: 'request-1',
  });
});
