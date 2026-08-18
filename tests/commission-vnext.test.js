const test = require('node:test');
const assert = require('node:assert/strict');
const C = require('../assets/js/commission-vnext.js');

// المطلوب في §20: مشتركان، ثلاثة أحداث مؤهِّلة.
const oldScope = {
  cycle_id: 'c1', scope_type: 'AGENT', scope_id: 'ag-1', scope_label: 'وكيل',
  zone: 'old', unique_activated_subscribers: 2, qualifying_event_count: 3,
  tier_code: 't1', package_breakdown: { 'P-35000': 2, 'P-45000': 1 },
  gross_commission: 13500, finalized_at: null,
};
const newScope = {
  cycle_id: 'c1', scope_type: 'FDT', scope_id: '900', scope_label: 'FDT-900',
  zone: 'new', unique_activated_subscribers: 2, qualifying_event_count: 3,
  tier_code: 't1', package_breakdown: { 'P-35000': 2, 'P-65000': 1 },
  gross_commission: 16000, finalized_at: '2026-08-31T00:00:00Z',
};

test('المقياسان منفصلان اسماً ومعنى', () => {
  assert.equal(C.METRICS.tierBasis.key, 'unique_activated_subscribers');
  assert.equal(C.METRICS.billable.key, 'qualifying_event_count');
  assert.notEqual(C.METRICS.tierBasis.key, C.METRICS.billable.key);
});

test('اللقطة تُقرأ كما وصلت ولا يُشتق مقياس من الآخر', () => {
  const s = C.readSnapshot(oldScope);
  assert.equal(s.uniqueActivatedSubscribers, 2);
  assert.equal(s.qualifyingEvents, 3);
  assert.notEqual(s.uniqueActivatedSubscribers, s.qualifyingEvents);
  assert.equal(s.tier, 't1');
  assert.equal(s.gross, 13500);
});

test('المتوقَّع والنهائي يظهران مختلفين', () => {
  assert.equal(C.snapshotMode(C.readSnapshot(oldScope)).key, 'projected');
  assert.equal(C.snapshotMode(C.readSnapshot(newScope)).key, 'final');
  assert.equal(C.snapshotMode(null).key, 'none');
});

test('النطاق يوصف بمنطقته ونوعه', () => {
  assert.equal(C.describeScope(C.readSnapshot(oldScope)), 'المنطقة القديمة · وكيل');
  assert.equal(C.describeScope(C.readSnapshot(newScope)), 'المنطقة الجديدة · كابينة');
});

test('إجماليات الدورة تفصل المقياسين وتفصل المنطقتين', () => {
  const sum = C.summarizeCycle([oldScope, newScope]);
  assert.equal(sum.scopes, 2);
  assert.equal(sum.subscribersByScope, 4);
  assert.equal(sum.qualifyingEvents, 6);
  assert.equal(sum.gross, 29500);
  assert.equal(sum.finalizedScopes, 1);
  assert.equal(sum.byZone.length, 2);
  const old = sum.byZone.find((z) => z.zone === 'old');
  assert.equal(old.subscribers, 2);
  assert.equal(old.events, 3);
});

test('المنطقة بلا نطاقات لا تُعرض صفراً مضلِّلاً', () => {
  const sum = C.summarizeCycle([oldScope]);
  assert.equal(sum.byZone.length, 1);
  assert.equal(sum.byZone[0].zone, 'old');
});

test('تفصيل الباقات يُقرأ مرتَّباً', () => {
  assert.deepEqual(C.packageRows(C.readSnapshot(oldScope)),
    [{ code: 'P-35000', count: 2 }, { code: 'P-45000', count: 1 }]);
  assert.deepEqual(C.packageRows(null), []);
});

const exceptions = [
  { reason_code: 'UNKNOWN_PACKAGE', status: 'OPEN', blocks_finalization: true },
  { reason_code: 'UNKNOWN_PACKAGE', status: 'OPEN', blocks_finalization: true },
  { reason_code: 'ATTRIBUTION_REVIEW', status: 'OPEN', blocks_finalization: false },
  { reason_code: 'SOURCE_INCOMPLETE', status: 'RESOLVED', blocks_finalization: true },
];

test('الاستثناءات تُجمَع، والحاجب يتقدّم', () => {
  const g = C.groupExceptions(exceptions);
  assert.equal(g.open, 3);
  assert.equal(g.blocking, 2);
  assert.equal(g.canFinalize, false);
  assert.equal(g.reasons[0].code, 'UNKNOWN_PACKAGE');
  assert.equal(g.reasons[0].label, 'باقة غير معروفة');
});

test('المحسوم لا يُحتسب مفتوحاً', () => {
  const g = C.groupExceptions(exceptions);
  assert.ok(!g.reasons.some((r) => r.code === 'SOURCE_INCOMPLETE'),
    'استثناء محسوم ظهر ضمن المفتوح');
});

test('بلا حاجب يجوز الاعتماد', () => {
  const g = C.groupExceptions([
    { reason_code: 'ATTRIBUTION_REVIEW', status: 'OPEN', blocks_finalization: false },
  ]);
  assert.equal(g.canFinalize, true);
  assert.equal(g.blocking, 0);
});

test('كل سبب استثناء خادمي له ترجمة', () => {
  const server = ['UNKNOWN_AGENT','UNKNOWN_FDT','UNKNOWN_PACKAGE','IDENTITY_CONFLICT',
    'SOURCE_INCOMPLETE','EVENT_CONFLICT','ATTRIBUTION_REVIEW','MISSING_PERIOD'];
  const missing = server.filter((code) => !C.EXCEPTION_LABELS[code]);
  assert.deepEqual(missing, [], 'أسباب بلا ترجمة: ' + missing.join(', '));
});

test('السبب المجهول يُعرض كما ورد بدل أن يُبتلع', () => {
  assert.equal(C.describeException('SOMETHING_NEW'), 'SOMETHING_NEW');
});

test('كل سبب خادمي يحمل جهةً وإجراءً، لا سبباً مجرَّداً', () => {
  // «كابينة غير معروفة» تصف حالة ولا تُملي فعلاً. الطابور يصير عملاً حين
  // يحمل الصف من يملك حسمه وما يفعله.
  const server = ['UNKNOWN_AGENT','UNKNOWN_FDT','UNKNOWN_PACKAGE','IDENTITY_CONFLICT',
    'SOURCE_INCOMPLETE','EVENT_CONFLICT','ATTRIBUTION_REVIEW','MISSING_PERIOD'];
  server.forEach((code) => {
    const play = C.exceptionPlaybook(code);
    assert.ok(play.owner && play.owner !== '—', `${code} بلا جهة مسؤولة`);
    assert.ok(play.action && play.action.length > 8, `${code} بلا إجراء مطلوب`);
  });
});

test('لا استثناء يُحيل إلى المطوّر بينما له مسار إداري', () => {
  // هذا هو المعيار الحقيقي: وجود شاشة يُحسم فيها الاستثناء بيد المستخدم.
  const withAdminPath = ['UNKNOWN_FDT', 'UNKNOWN_AGENT', 'UNKNOWN_PACKAGE', 'SOURCE_INCOMPLETE'];
  withAdminPath.forEach((code) => {
    assert.ok(C.exceptionPlaybook(code).target,
      `${code} بلا شاشة يُحسم فيها — يبقى تدخّلاً هندسياً`);
  });

  const forbidden = /مطوّر|المطور|developer|engineer|راجع الفريق التقني/i;
  Object.entries(C.EXCEPTION_PLAYBOOK).forEach(([code, play]) => {
    assert.ok(!forbidden.test(play.action), `${code} يطلب تدخّلاً هندسياً`);
    assert.ok(!forbidden.test(play.owner), `${code} يُحمّل المسؤولية للهندسة`);
  });
});

test('الكابينة المجهولة تقود إلى شاشة تصنيف الكابينات بعينها', () => {
  assert.equal(C.exceptionPlaybook('UNKNOWN_FDT').target, 'fdtOnboarding');
});

test('التجميع يعدّ المشتركين لا الأحداث وحدها', () => {
  // سببٌ بألف حدث على مئة مشترك هو مئة قرار بشري لا ألفاً. عرضه ألفاً يجعل
  // الطابور يبدو مستحيلاً وهو ليس كذلك.
  const g = C.groupExceptions([
    { reason_code: 'UNKNOWN_FDT', status: 'OPEN', blocks_finalization: true, subscriber_key: 's1' },
    { reason_code: 'UNKNOWN_FDT', status: 'OPEN', blocks_finalization: true, subscriber_key: 's1' },
    { reason_code: 'UNKNOWN_FDT', status: 'OPEN', blocks_finalization: true, subscriber_key: 's2' },
  ]);
  assert.equal(g.reasons[0].open, 3);
  assert.equal(g.reasons[0].subscribers, 2);
});

test('السبب المجهول لا يُخترَع له مالك', () => {
  const play = C.exceptionPlaybook('SOMETHING_NEW');
  assert.equal(play.owner, '—');
  assert.equal(play.target, null);
});

// التهيئة — بقيم V1 الحقيقية.
const tiers = [
  { sequence: 2, code: 't2', min_subscribers: 201, max_subscribers: 400 },
  { sequence: 1, code: 't1', min_subscribers: 0, max_subscribers: 200 },
  { sequence: 3, code: 't3', min_subscribers: 401, max_subscribers: null },
];

test('الشرائح تُرتَّب بالتسلسل', () => {
  assert.deepEqual(C.orderedTiers(tiers).map((t) => t.code), ['t1', 't2', 't3']);
});

test('الشريحة العليا تُوصَف مفتوحة لا بحد مخترع', () => {
  assert.equal(C.describeTierBand(tiers.find((t) => t.code === 't1')), '0–200');
  assert.equal(C.describeTierBand(tiers.find((t) => t.code === 't3')), '401 فأكثر');
});

test('الشريحة تُختار من عدد المشتركين', () => {
  assert.equal(C.tierForSubscribers(tiers, 0).code, 't1');
  assert.equal(C.tierForSubscribers(tiers, 200).code, 't1');
  assert.equal(C.tierForSubscribers(tiers, 201).code, 't2');
  assert.equal(C.tierForSubscribers(tiers, 400).code, 't2');
  assert.equal(C.tierForSubscribers(tiers, 401).code, 't3');
  assert.equal(C.tierForSubscribers(tiers, 99999).code, 't3');
  assert.equal(C.tierForSubscribers(tiers, 'x'), null);
});

test('المنشور غير قابل للتحرير في الواجهة', () => {
  assert.equal(C.isEditableVersion({ status: 'DRAFT' }), true);
  assert.equal(C.isEditableVersion({ status: 'PUBLISHED' }), false);
  assert.equal(C.isEditableVersion({ status: 'RETIRED' }), false);
  assert.equal(C.isEditableVersion(null), false);
});

test('الوحدة لا تحسب مالاً ولا تحمل مبلغاً ثابتاً', () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const src = fs.readFileSync(
    path.join(__dirname, '../assets/js/commission-vnext.js'), 'utf8');
  // لا أسعار شرائح ولا حدود مبذورة: كلها من الخادم.
  assert.ok(!/\b(4000|4750|5500|6000|8000|9000|11500)\b/.test(src),
    'commission-vnext.js يحمل سعر شريحة ثابتاً');
  // لا اشتقاق لأحد المقياسين من الآخر.
  assert.ok(!/unique[A-Za-z]*\s*=\s*[^;]*qualifying/i.test(src),
    'الوحدة تشتق أساس الشريحة من عدد الأحداث');
});
