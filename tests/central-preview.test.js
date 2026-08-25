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

test('central workspace is default, is read-only, and preserves admin preparation state', () => {
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
  assert.match(html, /function hasPermission\(p\)\{if\(\['users','backup'\]\.includes\(p\)\)return roleAllows\(p\)/);
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

test('the retired month engine keeps no payment write path at all', () => {
  // كان الصرف هنا يمرّ بدالّة ذرّية بمعرّف طلبٍ وطابعِ تزامن، ثم تقاعد المحرّك
  // فصارت `recordCentralPayment` تُظهر رسالةً وتنتهي. لكن الواجهة بقيت فوقها
  // كاملة: نموذجٌ بمبلغٍ وتاريخٍ وزرّ «حفظ الصرف مركزياً» ينتهي دائماً إلى
  // «تعذر حفظ الصرف مركزياً» — أي فشلٌ يُقرأ عطلاً عابراً لا تقاعداً.
  //
  // فلم يعد المقياس «هل يصل إلى الشبكة؟» بل «هل بقي طريقٌ يُسلَك أصلاً؟».
  const legacy = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');

  for (const gone of ['recordCentralPayment', 'applyCentralPaymentResult',
                      'editPayment', 'savePayment', 'paymentRequestId', 'createRequestId']) {
    assert.doesNotMatch(legacy, new RegExp(`function\\s+${gone}\\s*\\(`),
      `${gone} ما زالت معرَّفة في الشاشة المتقاعدة`);
  }
  assert.doesNotMatch(legacy, /const pendingPaymentRequests/);

  // ولا عقد كتابةٍ ماليّ يُنادى من هنا: ما بقي من commission_rows قراءةٌ فقط.
  assert.doesNotMatch(legacy, /record_commission_payment/);
  const queries = [...legacy.matchAll(/commission_rows\?[^'"`\s]*/g)];
  assert.ok(queries.length > 0, 'اختفت استعلامات commission_rows — تغيّر ما يقيسه الاختبار');
  for (const [query] of queries) {
    assert.match(query, /^commission_rows\?select=/,
      'استعلام commission_rows لم يعد قراءةً خالصة');
  }
});

test('the retired screen shows a route to the paying screen, not a button that cannot pay', () => {
  // وأدقّ ما في العطل أنّ `canPay()` وحدها كانت تشترط الوضع المركزي بدل نفيه:
  // فالزرّ يُفعَّل في الحالة التي لا كتابة فيها، ويُعطَّل حيث لا ضرر منه.
  const elements = new Map([
    ['searchInput', { value: '' }],
    ['zoneFilter', { value: 'all' }],
    ['statusFilter', { value: 'all' }],
    ['panel-old', { innerHTML: '' }],
  ]);
  const app = loadCurrentApp({ elements });
  app.__setAuthProfile({ role: 'admin', is_active: true });
  app.state.tiers = tiers();
  app.state.data.old = [{
    name: 'Agent A', p35: 2, p45: 1, p65: 0, customTier: 'auto',
    paid: 0, paymentDate: '', centralId: 'row-1',
  }];

  app.renderZone('old');
  const html = elements.get('panel-old').innerHTML;

  assert.match(html, /Agent A/, 'الصفّ نفسه لم يُعرض');
  assert.doesNotMatch(html, /editPayment|savePayment/, 'ما زال في الصفّ إجراء صرف');
  assert.doesNotMatch(html, /حفظ الصرف/);
  assert.ok(html.includes('href="#/finance/payment-batches"'),
    'لا طريق من الشاشة المتقاعدة إلى الشاشة التي تصرف فعلاً');

  // والعرض التاريخي باقٍ: المستحق والمدفوع والمتبقي تُقرأ كما كانت.
  assert.match(html, /المتبقي/);
});

test('the central mode no longer claims payment as the one thing it allows', () => {
  // القاعدة القديمة كانت تستثني الصرف من التعطيل في الوضع المركزي، فتَعِد
  // بما لا يقع. سقط الاستثناء مع الطريق الذي كان يبرّره.
  const legacy = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
  assert.doesNotMatch(legacy, /payment'\)\s*return centralPreview\.active/);
  assert.doesNotMatch(legacy, /يتاح الصرف فقط/);
  assert.doesNotMatch(legacy, /function canPay\s*\(/);
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
