const test = require('node:test');
const assert = require('node:assert/strict');
const O = require('../assets/js/operations.js');

const caps = O.indexCapabilities([
  { capability_key: 'payment.execute', effective: true, source: 'TEMPLATE' },
  { capability_key: 'payment.correct', effective: true, source: 'GRANT' },
  { capability_key: 'payment.reverse', effective: false, source: 'DENY' },
  { capability_key: 'cycle.close', effective: false, source: 'NONE' },
]);

test('القدرة الغائبة تُعامَل ممنوعة لا مسموحة', () => {
  assert.equal(O.can(caps, 'permission.manage'), false);
  assert.equal(O.can(null, 'payment.execute'), false);
  assert.equal(O.can(caps, 'payment.execute'), true);
});

test('المنع الصريح يظهر ممنوعاً حتى لو ورد في القائمة', () => {
  assert.equal(O.can(caps, 'payment.reverse'), false);
  assert.equal(O.explainSource(caps, 'payment.reverse').source, 'DENY');
  assert.equal(O.explainSource(caps, 'payment.reverse').label, 'ممنوع صراحةً');
});

test('مصدر القدرة يُفسَّر للواجهة الإدارية', () => {
  assert.equal(O.explainSource(caps, 'payment.execute').source, 'TEMPLATE');
  assert.equal(O.explainSource(caps, 'payment.correct').source, 'GRANT');
  assert.equal(O.explainSource(caps, 'unknown.cap').source, 'NONE');
});

test('أول قدرة مفقودة تُسمَّى بدل رسالة عامة', () => {
  assert.equal(O.firstMissing(caps, ['payment.execute', 'payment.reverse']), 'payment.reverse');
  assert.equal(O.firstMissing(caps, ['payment.execute', 'payment.correct']), null);
});

test('أسباب المنع تُترجَم، والمجهول يُعرض كما ورد', () => {
  assert.equal(O.describeBlocker('MISSING_INVOICE'), 'لا فاتورة مدقَّقة');
  assert.equal(O.describeBlocker('DEBT_SERVICE_NEVER_QUALIFIES'), 'خدمة دَين لا تؤهِّل');
  assert.equal(O.describeBlocker('SOMETHING_NEW'), 'SOMETHING_NEW');
  assert.deepEqual(O.describeBlockers(['ON_HOLD', 'ALREADY_PAID']),
    ['عليه تعليق نشط', 'مدفوع سلفاً']);
});

test('كل سبب منع خادمي له ترجمة', () => {
  // الأسباب التي يُصدرها محرّك الأهلية وبوابة التسجيل فعلاً.
  const serverBlockers = [
    'NOT_FOUND','ALREADY_PAID','INVALID_STAGE','NOT_ENROLLED','ENROLLMENT_INACTIVE',
    'STAGE_OUT_OF_SEQUENCE','STAGE_NOT_IN_SCHEME','AMOUNT_DOES_NOT_MATCH_SCHEME',
    'IDENTITY_CONFLICT','UNKNOWN_PARENT','DIRECT_COMPANY_NOT_PAYABLE','MISSING_INVOICE',
    'ON_HOLD','UNRESOLVED_HISTORICAL_STATE','EVENT_NOT_FOUND','EVENT_CANCELED',
    'UNKNOWN_PACKAGE','DEBT_SERVICE_NEVER_QUALIFIES','PACKAGE_NOT_QUALIFYING',
    'SOURCE_INCOMPLETE','UNMATCHED_SUBSCRIBER','IDENTITY_NOT_RESOLVED',
    'DIRECT_COMPANY_NOT_ELIGIBLE','EFFECTIVE_AGENT_UNRESOLVED','PARENT_NEEDS_REVIEW',
    'NOT_CLASSIFIED','SUBSCRIBER_IS_EXISTING','CLASSIFICATION_NEEDS_REVIEW',
    'ALREADY_ENROLLED','EVENT_ALREADY_USED',
  ];
  const missing = serverBlockers.filter((code) => !O.BLOCKER_LABELS[code]);
  assert.deepEqual(missing, [], 'أسباب بلا ترجمة: ' + missing.join(', '));
});

const evals = [
  { entitlement_id: '1', eligible: true, amount: 3000, blockers: [] },
  { entitlement_id: '2', eligible: true, amount: 4000, blockers: [] },
  { entitlement_id: '3', eligible: false, amount: 3000, blockers: ['MISSING_INVOICE'] },
  { entitlement_id: '4', eligible: false, amount: 3000, blockers: ['ON_HOLD'] },
  { entitlement_id: '5', eligible: false, amount: 3000, blockers: ['IDENTITY_CONFLICT'] },
  { entitlement_id: '6', eligible: false, amount: 3000, blockers: ['ALREADY_PAID'] },
  { entitlement_id: '7', eligible: false, amount: 3000, blockers: ['UNKNOWN_PARENT'] },
];

test('الطوابير تُبنى من التقييم الخادمي', () => {
  const queues = O.buildQueues(evals);
  const by = new Map(queues.map((q) => [q.key, q.count]));
  assert.equal(by.get('ready'), 2);
  assert.equal(by.get('missing_invoice'), 1);
  assert.equal(by.get('on_hold'), 1);
  assert.equal(by.get('identity_conflict'), 1);
  assert.equal(by.get('paid'), 1);
  assert.equal(by.get('unknown_parent'), 1);
});

test('البند المحجوب بأسباب عدة يُعدّ مرة واحدة', () => {
  const queues = O.buildQueues([
    { entitlement_id: 'x', eligible: false, amount: 3000,
      blockers: ['MISSING_INVOICE', 'ON_HOLD', 'IDENTITY_CONFLICT'] },
  ]);
  const total = queues.reduce((sum, q) => sum + q.count, 0);
  assert.equal(total, 1, 'البند ظهر في أكثر من طابور');
});

test('سبب بلا طابور يبقى مرئياً في المراجعة', () => {
  const queues = O.buildQueues([
    { entitlement_id: 'y', eligible: false, amount: 3000, blockers: ['SOME_FUTURE_REASON'] },
  ]);
  const review = queues.find((q) => q.key === 'needs_review');
  assert.equal(review.count, 1);
});

test('مجموع الجاهز يحسب المؤهَّل وحده', () => {
  assert.equal(O.readyTotal(evals), 7000);
  assert.equal(O.readyTotal([]), 0);
});

const stages = [
  { code: 'P4', sequence: 4, amount: 4000 },
  { code: 'P1', sequence: 1, amount: 3000 },
  { code: 'P3', sequence: 3, amount: 3000 },
  { code: 'P2', sequence: 2, amount: 3000 },
  { code: 'DONE', sequence: 5, amount: 0 },
];

test('المبلغ يأتي من تعريف المخطط لا من ثابت', () => {
  assert.equal(O.stageAmount(stages, 'P4'), 4000);
  assert.equal(O.stageAmount(stages, 'P1'), 3000);
  assert.equal(O.stageAmount(stages, 'NOPE'), null);
  assert.equal(O.schemeTotal(stages), 13000);
});

test('المراحل تُرتَّب بالتسلسل لا بترتيب الوصول', () => {
  assert.deepEqual(O.orderedStages(stages).map((s) => s.code),
    ['P1', 'P2', 'P3', 'P4', 'DONE']);
});

test('إصدار مختلف الشكل يعمل بلا تغيير كود', () => {
  const v2 = [
    { code: 'S2', sequence: 2, amount: 5000 },
    { code: 'S1', sequence: 1, amount: 5000 },
    { code: 'END', sequence: 3, amount: 0 },
  ];
  assert.deepEqual(O.orderedStages(v2).map((s) => s.code), ['S1', 'S2', 'END']);
  assert.equal(O.schemeTotal(v2), 10000);
  assert.equal(O.stageAmount(v2, 'S1'), 5000);
});

test('المنشور غير قابل للتحرير في الواجهة', () => {
  assert.equal(O.isEditableVersion({ status: 'DRAFT' }), true);
  assert.equal(O.isEditableVersion({ status: 'PUBLISHED' }), false);
  assert.equal(O.isEditableVersion({ status: 'RETIRED' }), false);
  assert.equal(O.isEditableVersion(null), false);
});
