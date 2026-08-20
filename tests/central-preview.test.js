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

test('a clean central launch accepts no visible periods', () => {
  const { buildCentralPeriods } = loadCurrentApp();
  const periods = buildCentralPeriods([], []);
  assert.equal(periods.size, 0);
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

test('central workspace is default, allows only audited payments, and preserves admin preparation state', () => {
  const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');

  // كتلة «تجهيز الشهر» غادرت الشريط: كانت تظهر على كل مسار لأنها تقع بعد
  // #appNav داخل <aside> المشترك، وفيها زرّان يقصدان شاشةً مخفيّة. ومحرّك
  // الشهر نفسه متقاعد. فما يبقى فحصه هنا حالتُه لا واجهتُه في الشريط.
  assert.doesNotMatch(html, /id="centralPreviewButton"/);
  assert.match(html, /البيانات المركزية/);
  assert.match(html, /class="sidebar"/);

  // ولا يُبنى إلا عند فتح #/legacy، لا في كل دخول.
  assert.match(html, /async function ensureLegacyWorkspace\(\)/);
  assert.match(html, /await enterCentralPreview\(true\)/);
  assert.doesNotMatch(html, /النسخة المحلية/);
  assert.match(html, /if\(p==='payment'\)return centralPreview\.active&&roleAllows\(p\)/);
  assert.match(html, /if\(centralPreview\.active\)\{toast\('انتقل إلى وضع تجهيز الشهر لإجراء التعديلات'\);return\}/);
  assert.match(html, /centralPreview\.localState=clone\(state\)/);
  assert.match(html, /state=clone\(centralPreview\.localState\)/);
  assert.match(html, /function fetchCentralPages\(path,pageSize=500\)/);
  // محرّك الشهر السابق تقاعد: بياناته تُقرأ ولا تُكتب. الصرف صار يجري من
  // دفعات الصرف — ومحرّكان يكتبان المال نفسه ينتهيان إلى رقمين مختلفين.
  assert.doesNotMatch(html, /\/rest\/v1\/rpc\/record_commission_payment/);
  assert.doesNotMatch(html, /\/rest\/v1\/rpc\/publish_commission_month/);
  assert.doesNotMatch(html, /method:\s*['"](?:POST|PATCH|PUT|DELETE)['"][\s\S]{0,200}commission_(?:months|rows)/i);
});

test('the retired month engine does not run on ordinary routes', () => {
  // العَرَض الذي رآه المستخدم: طرفيّة مُغرَقة بـ«Skipping row for hidden or
  // unavailable month» وهو في /system/users. والسبب أن الدخول كان يُشغّل
  // load(); renderMonths(); renderAll(); enterCentralPreview(true) أياً كان
  // المسار — فيقرأ commission_months وكل commission_rows بلا ترشيح، ثم
  // يُحذّر لكل صفٍّ يخصّ شهراً غير مرئي.
  const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');

  // البناء صار خلف بوّابةٍ واحدة تُنادى من المسار.
  assert.match(html, /async function ensureLegacyWorkspace\(\)/);
  assert.match(html, /window\.ensureLegacyWorkspace\s*=\s*ensureLegacyWorkspace/);

  // ولا يُنادى شيء منه في مسار الدخول أو استعادة الجلسة.
  const loginArea = html.slice(html.indexOf('showApp();'));
  const beforeGate = loginArea.slice(0, loginArea.indexOf('ensureLegacyWorkspace.pending'));
  for (const call of ['load();', 'renderMonths();', 'renderAll();', 'enterCentralPreview(']) {
    assert.ok(!beforeGate.includes(call),
      `${call} ما زال يعمل عند الدخول على كل مسار`);
  }

  // والموجِّه هو من يفتحها، عند #/legacy وحده.
  const main = fs.readFileSync(path.join(__dirname, '..', 'src/main.ts'), 'utf8');
  const legacy = main.slice(main.indexOf("pattern: '/legacy'"), main.indexOf('const ROUTES'));
  assert.match(legacy, /ensureLegacyWorkspace/);
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

test('the retired month engine no longer reaches the network to record a payment', async () => {
  // كان هذا الاختبار يتحقّق من أن الصرف يمرّ بدالّة ذرّية بمعرّف طلبٍ
  // وطابعِ تزامن. الحكم لم يسقط، بل انتقل: الصرف صار من دفعات الصرف،
  // وهنا يبقى التحقّق من أن الطريق القديم لم يعد يصل إلى الشبكة أصلاً.
  let called = false;
  const app = loadCurrentApp({
    fetch: async () => {
      called = true;
      return { ok: true, status: 200, async text() { return '{}'; } };
    },
  });
  app.setSbSession({ access_token: 'access', refresh_token: 'refresh', expires_at: Math.floor(Date.now() / 1000) + 3600 });

  await app.recordCentralPayment(
    { centralId: 'row-1', centralUpdatedAt: '2026-09-10T00:00:00.000Z' },
    1000,
    '2026-09-10',
    'request-1',
  );

  assert.equal(called, false, 'الطريق المتقاعد ما زال يكتب');
});

test('commission payment posting keeps its request id and its reference', () => {
  // وهنا يُتحقَّق من الحكم في موضعه الجديد: الترحيل يحمل معرّف طلبٍ يمنع
  // تكراره، ومرجعاً بنكياً بلا استثناء.
  const finance = fs.readFileSync(
    path.join(__dirname, '..', 'src/features/finance/index.ts'), 'utf8');
  const post = finance.slice(finance.indexOf("rpc<Row>('post_commission_batch'"));

  assert.match(post, /p_request_id: crypto\.randomUUID\(\)/);
  assert.match(post, /p_payment_reference: reference/);
  assert.match(finance, /المرجع إلزامي/);
});
