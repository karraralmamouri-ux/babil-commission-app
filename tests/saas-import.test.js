const test = require('node:test');
const assert = require('node:assert/strict');
const S = require('../assets/js/saas-import.js');

// أشكال الرؤوس مأخوذة حرفياً من الملفات الحقيقية. القيم مُختلَقة بالكامل:
// لا اسم مشترك ولا رقم هوية ولا كلمة سر حقيقية في أي تجربة هنا.

const EVENT_HEADERS = {
  id: '1', username: 'u1', created_at: '2026-07-01T00:00:00Z',
  activations_count: 1, parent: 'r.fixture.agent', profile_name: 'P-35000',
};

test('ct_password يُسقَط ولا يظهر في أي مخرج', () => {
  const rows = [{ ...EVENT_HEADERS, ct_password: 'SECRET-VALUE', lastname: 'FDT:11' }];
  const parsed = S.parseActivationSheet(rows, { sheetName: 'Worksheet' });
  assert.equal(parsed.secretsDropped, 1, 'العمود السرّي يُعَدّ ولا يُسمّى');
  const serialized = JSON.stringify(parsed);
  assert.ok(!serialized.includes('SECRET-VALUE'), 'قيمة السر ظهرت في المخرج');
  assert.ok(!serialized.includes('ct_password'), 'اسم عمود السر ظهر في المخرج');
  assert.equal(S.canonicalField('ct_password'), null);
  assert.equal(S.canonicalField('CT_Password'), null);
});

test('كلمة السر لا تصير حقلاً قانونياً بأي إملاء', () => {
  ['ct_password', 'ctpassword', 'password', 'ct_pass', 'CT_PASS'].forEach((name) => {
    assert.equal(S.canonicalField(name), null, name);
  });
});

test('الرؤوس التالفة المرصودة في ملف أيار تُقرأ صراحةً', () => {
  assert.equal(S.canonicalField('irstname'), 'firstname');
  assert.equal(S.canonicalField('lastnam'), 'lastname');
  assert.equal(S.canonicalField('proile_name'), 'profile_name');
  assert.equal(S.canonicalField('manager_irstname'), 'manager_firstname');
});

test('لا مطابقة تقريبية: رأس مجهول يُهمَل ولا يُخمَّن', () => {
  assert.equal(S.canonicalField('profil'), null);
  assert.equal(S.canonicalField('user_nam'), null);
  assert.equal(S.canonicalField('random_column'), null);
});

test('عقد الشيت يفصل الأحداث عن المستخدمين عن الجداول المحورية', () => {
  assert.equal(S.classifySheet(['id', 'username', 'created_at', 'activations_count', 'parent']),
    'ACTIVATION_EVENTS');
  // ملف المستخدمين الحقيقي: لا activations_count ولا parent باسم parent
  assert.equal(S.classifySheet(['id', 'username', 'profile_name', 'parent_name', 'enabled']),
    'USERS_SNAPSHOT');
  // الجداول المحورية الحقيقية
  assert.equal(S.classifySheet(['Row Labels', 'Count of id']), 'REJECTED');
  assert.equal(S.classifySheet(['Count of proile_name', 'Column Labels', '__EMPTY']), 'REJECTED');
  assert.equal(S.classifySheet(['Count of price', 'Column Labels', '__EMPTY']), 'REJECTED');
});

test('إزالة التكرار على مستوى الحدث لا المشترك', () => {
  const rows = [
    { ...EVENT_HEADERS, id: '1', username: 'u1' },
    { ...EVENT_HEADERS, id: '2', username: 'u1' }, // نفس المشترك، حدث آخر
    { ...EVENT_HEADERS, id: '3', username: 'u1' },
  ];
  const out = S.parseWorkbook([{ name: 'Worksheet', rows }]);
  assert.equal(out.events.length, 3, 'أحداث مشترك واحد لا تُدمج');
  assert.equal(out.duplicateCount, 0);
});

test('الحدث نفسه في شيتين يُحتسب مرة واحدة', () => {
  const shared = { ...EVENT_HEADERS, id: '900' };
  const out = S.parseWorkbook([
    { name: 'Sheet1', rows: [shared] },
    { name: 'Worksheet', rows: [{ ...EVENT_HEADERS, id: '901' }, shared] },
  ]);
  assert.equal(out.events.length, 2);
  assert.equal(out.duplicateCount, 1);
  assert.deepEqual(out.sheetResults.map((r) => r.imported), [1, 1]);
});

test('كل شيت يستوفي العقد يُقرأ، والمحوري يُرفض بسبب مُعلن', () => {
  const out = S.parseWorkbook([
    { name: 'Sheet1', rows: [{ ...EVENT_HEADERS, id: 'a' }] },
    { name: 'Sheet2', rows: [{ ...EVENT_HEADERS, id: 'b' }] },
    { name: 'OLD ZONE', rows: [{ 'Count of proile_name': 1, 'Column Labels': 'x' }] },
    { name: 'Worksheet', rows: [{ ...EVENT_HEADERS, id: 'c' }] },
  ]);
  assert.equal(out.events.length, 3, 'الصفوف المفردة في Sheet1/Sheet2 لا تُفقَد');
  const rejected = out.sheetResults.find((r) => r.sheet === 'OLD ZONE');
  assert.equal(rejected.kind, 'REJECTED');
  assert.equal(rejected.reason, 'CONTRACT_NOT_SATISFIED');
});

test('صف بلا معرّف حدث يُرفض ولا يُلفَّق له مفتاح', () => {
  const rows = [{ ...EVENT_HEADERS, id: null }, { ...EVENT_HEADERS, id: '', username: 'u2' }];
  const parsed = S.parseActivationSheet(rows, { sheetName: 'W' });
  assert.equal(parsed.events.length, 0);
  assert.equal(parsed.rejected.length, 2);
  assert.ok(parsed.rejected.every((r) => r.reason === 'MISSING_EVENT_ID'));
});

test('الطوبولوجيا: الأجزاء الثلاثة، والجزء الواحد، والشكل المجهول', () => {
  assert.deepEqual(S.parseTopology('FDT:11 FAT:3 PORT:3'),
    { topology_raw: 'FDT:11 FAT:3 PORT:3', fdt_code: '11', fat_code: '3', port_code: '3' });
  // شكل تموز الحقيقي: كابينة وحدها
  assert.deepEqual(S.parseTopology('FDT:97'),
    { topology_raw: 'FDT:97', fdt_code: '97', fat_code: null, port_code: null });
  // نص لا يُفهَم يبقى خاماً بلا تخمين
  assert.deepEqual(S.parseTopology('بلا طوبولوجيا'),
    { topology_raw: 'بلا طوبولوجيا', fdt_code: null, fat_code: null, port_code: null });
  assert.equal(S.parseTopology(null).fdt_code, null);
});

test('الطوبولوجيا المبثوثة في أعمدة __EMPTY تُجمَع', () => {
  const rows = [{ ...EVENT_HEADERS, lastname: 'FDT:11', __EMPTY: 'FAT:3', __EMPTY_1: 'PORT:7' }];
  const parsed = S.parseActivationSheet(rows, { sheetName: 'W' });
  assert.equal(parsed.events[0].fdt_code, '11');
  assert.equal(parsed.events[0].fat_code, '3');
  assert.equal(parsed.events[0].port_code, '7');
});

test('حدود التغطية تُرصد، والاكتمال يبقى UNKNOWN', () => {
  const out = S.parseWorkbook([{ name: 'W', rows: [
    { ...EVENT_HEADERS, id: '1', created_at: '2026-07-01T00:00:00Z' },
    { ...EVENT_HEADERS, id: '2', created_at: '2026-07-31T00:00:00Z' },
  ] }]);
  assert.equal(out.observedMinCreatedAt, '2026-07-01T00:00:00.000Z');
  assert.equal(out.observedMaxCreatedAt, '2026-07-31T00:00:00.000Z');
  assert.equal(out.completenessStatus, 'UNKNOWN', 'الحدود المرصودة لا تُثبت الاكتمال');
});

// --- المطابقة ---------------------------------------------------------------

const registry = {
  bySaasId: new Map([['S-1', 'sub-1']]),
  byUsername: new Map([['u-known', ['sub-2']], ['u-dupe', ['sub-3', 'sub-4']]]),
};

test('المطابقة بالمعرّف تسبق الاسم', () => {
  const m = S.matchSubscriber({ saas_user_id: 'S-1', username_key: 'u-known' }, registry);
  assert.equal(m.match_method, 'SAAS_USER_ID');
  assert.equal(m.subscriber_id, 'sub-1');
});

test('اسم مستخدم مطابق تماماً يُقبل', () => {
  const m = S.matchSubscriber({ saas_user_id: null, username_key: 'u-known' }, registry);
  assert.equal(m.match_method, 'EXACT_USERNAME');
  assert.equal(m.identity_status, 'MATCHED');
});

test('اسم يقود إلى مشتركَين تعارض، لا ترجيح', () => {
  const m = S.matchSubscriber({ saas_user_id: null, username_key: 'u-dupe' }, registry);
  assert.equal(m.identity_status, 'CONFLICT');
  assert.equal(m.subscriber_id, null);
  assert.equal(m.match_method, null);
});

test('غير المعروف يبقى UNMATCHED ولا يُنشأ صامتاً', () => {
  const m = S.matchSubscriber({ saas_user_id: null, username_key: 'nobody' }, registry);
  assert.equal(m.identity_status, 'UNMATCHED');
  assert.equal(m.subscriber_id, null);
});

// --- الجِدّة ----------------------------------------------------------------

const CATS = new Map([
  ['P-35000', 'PAID_PACKAGE'], ['P-45000', 'PAID_PACKAGE'], ['P-65000', 'PAID_PACKAGE'],
  ['Loan-3', 'DEBT_SERVICE'], ['Diamond', 'UNKNOWN'],
]);
const ev = (o) => Object.assign({ profile_name: 'P-35000', canceled: false, activations_count: 1 }, o);

test('الموجود في السجل قديم مهما قال الملف', () => {
  const c = S.classifyNewness({
    registryPreexisting: true, sourceCompleteness: 'COMPLETE',
    events: [ev({ activations_count: 1 })], packageCategory: CATS,
  });
  assert.equal(c.classification, 'EXISTING');
  assert.equal(c.reason_code, 'REGISTRY_PREEXISTING');
});

test('عدّاد العمر أكبر من المرصود ⇒ قديم قطعاً', () => {
  const c = S.classifyNewness({
    registryPreexisting: false, sourceCompleteness: 'UNKNOWN',
    events: [ev({ activations_count: 12 })], packageCategory: CATS,
  });
  assert.equal(c.classification, 'EXISTING');
  assert.equal(c.reason_code, 'LIFETIME_COUNT_EXCEEDS_OBSERVED');
});

test('الحارس: تساوي العدّاد مع مصدر مجهول الاكتمال لا يُنتج NEW', () => {
  const c = S.classifyNewness({
    registryPreexisting: false, sourceCompleteness: 'UNKNOWN',
    events: [ev({ activations_count: 1 })], packageCategory: CATS,
  });
  assert.equal(c.classification, 'NEEDS_REVIEW');
  assert.equal(c.reason_code, 'UNKNOWN_SOURCE_COMPLETENESS');
});

test('مصدر ناقص لا يُنتج NEW', () => {
  const c = S.classifyNewness({
    registryPreexisting: false, sourceCompleteness: 'PARTIAL',
    events: [ev({ activations_count: 1 })], packageCategory: CATS,
  });
  assert.equal(c.classification, 'NEEDS_REVIEW');
  assert.equal(c.reason_code, 'PARTIAL_SOURCE');
});

test('NEW لا تُقال إلا بمصدر مكتمل مُثبت', () => {
  const c = S.classifyNewness({
    registryPreexisting: false, sourceCompleteness: 'COMPLETE',
    events: [ev({ activations_count: 1 })], packageCategory: CATS,
  });
  assert.equal(c.classification, 'NEW');
  assert.equal(c.reason_code, 'COMPLETE_LIFETIME_HISTORY_OBSERVED');
});

test('Loan-3 ليس تفعيلاً مدفوعاً ولا يُنتج NEW ولو اكتمل المصدر', () => {
  const c = S.classifyNewness({
    registryPreexisting: false, sourceCompleteness: 'COMPLETE',
    events: [ev({ profile_name: 'Loan-3', activations_count: 1 })], packageCategory: CATS,
  });
  assert.notEqual(c.classification, 'NEW');
  assert.equal(c.reason_code, 'NO_QUALIFYING_PAID_EVENT');
  assert.equal(c.qualifying_paid_event_count, 0);
  assert.equal(c.evidence.debt_service_events, 1);
});

test('Diamond مجهولة الدلالة لا تُؤهِّل تلقائياً', () => {
  const c = S.classifyNewness({
    registryPreexisting: false, sourceCompleteness: 'COMPLETE',
    events: [ev({ profile_name: 'Diamond', activations_count: 1 })], packageCategory: CATS,
  });
  assert.notEqual(c.classification, 'NEW');
  assert.equal(c.qualifying_paid_event_count, 0);
  assert.equal(c.evidence.unknown_package_events, 1);
});

test('باقة غير مسجَّلة إطلاقاً تُعامَل معاملة المجهول', () => {
  const c = S.classifyNewness({
    registryPreexisting: false, sourceCompleteness: 'COMPLETE',
    events: [ev({ profile_name: 'P-99999', activations_count: 1 })], packageCategory: CATS,
  });
  assert.notEqual(c.classification, 'NEW');
});

test('الأحداث الملغاة وحدها لا تُنتج تصنيفاً موجباً', () => {
  const c = S.classifyNewness({
    registryPreexisting: false, sourceCompleteness: 'COMPLETE',
    events: [ev({ canceled: true, activations_count: 1 })], packageCategory: CATS,
  });
  assert.equal(c.classification, 'NEEDS_REVIEW');
  assert.equal(c.reason_code, 'CANCELED_ONLY_HISTORY');
});

test('تعارض الهوية يمنع التصنيف', () => {
  const c = S.classifyNewness({
    registryPreexisting: false, sourceCompleteness: 'COMPLETE', identityStatus: 'CONFLICT',
    events: [ev({ activations_count: 1 })], packageCategory: CATS,
  });
  assert.equal(c.classification, 'NEEDS_REVIEW');
  assert.equal(c.reason_code, 'IDENTITY_CONFLICT');
});

test('كل تصنيف يحمل دليله المعدود', () => {
  const c = S.classifyNewness({
    registryPreexisting: false, sourceCompleteness: 'UNKNOWN',
    events: [ev({ activations_count: 3 }), ev({ profile_name: 'Loan-3' }), ev({ canceled: true })],
    packageCategory: CATS,
  });
  assert.equal(c.observed_event_count, 3);
  assert.equal(c.lifetime_activations_count, 3);
  assert.equal(c.qualifying_paid_event_count, 1);
  assert.equal(c.evidence.debt_service_events, 1);
  assert.equal(c.evidence.canceled_events, 1);
});

// --- انحدارات مكتشفة من مصادر حقيقية ----------------------------------------

test('الوقت المضغوط بلا نقطتين يُقرأ — صيغة مرصودة في تصديرين حقيقيين', () => {
  // "2026-04-30 235650" ترفضها Date، وكانت تُنتج تاريخاً فارغاً لكل حدث في
  // ملفَي نيسان والغرامات (100% من 56,718 حدثاً).
  const rows = [{ ...EVENT_HEADERS, created_at: '2026-04-30 235650' }];
  const parsed = S.parseActivationSheet(rows, { sheetName: 'W' });
  assert.equal(parsed.events[0].event_created_at, '2026-04-30T20:56:50.000Z');
  assert.equal(parsed.unparsedDates, 0);
});

test('الصيغة المعتادة لم تتأثر بإضافة المضغوطة', () => {
  const rows = [{ ...EVENT_HEADERS, created_at: '2026-02-28 23:58:35' }];
  assert.equal(S.parseActivationSheet(rows, {}).events[0].event_created_at,
    '2026-02-28T20:58:35.000Z');
});

test('تاريخ لا يُفهَم يُعَدّ ولا يُبتلع', () => {
  // الفراغ يعني «لم يُصدَّر»؛ وعدم الفهم يعني صيغة مجهولة — والثاني يستوجب وقفة.
  const rows = [
    { ...EVENT_HEADERS, id: 'a', created_at: 'ليس تاريخاً' },
    { ...EVENT_HEADERS, id: 'b', created_at: null },
    { ...EVENT_HEADERS, id: 'c', created_at: '2026-04-30 235650' },
  ];
  const parsed = S.parseActivationSheet(rows, {});
  assert.equal(parsed.unparsedDates, 1, 'المجهول وحده يُعَدّ، لا الفارغ');
  assert.equal(S.unparsedTimestamp('ليس تاريخاً'), true);
  assert.equal(S.unparsedTimestamp(null), false);
  assert.equal(S.unparsedTimestamp('2026-04-30 235650'), false);
});

test('عدّ التواريخ المجهولة يصعد إلى نتيجة المصنّف', () => {
  const out = S.parseWorkbook([{ name: 'W', rows: [
    { ...EVENT_HEADERS, id: 'x', created_at: 'صيغة مجهولة' },
    { ...EVENT_HEADERS, id: 'y', created_at: '2026-07-01T00:00:00Z' },
  ] }]);
  assert.equal(out.unparsedDates, 1);
  // غير صفر يعني: لا تُستورَد قبل الفحص.
  assert.ok(out.unparsedDates > 0);
});

test('رأس lastname المقطوع إلى tnam مرصود في ملف نيسان', () => {
  assert.equal(S.canonicalField('tnam'), 'lastname');
  // والطوبولوجيا تُقرأ منه كما تُقرأ من الاسم السليم.
  const rows = [{ ...EVENT_HEADERS, tnam: 'FDT:41 FAT:2 PORT:9' }];
  const parsed = S.parseActivationSheet(rows, {});
  assert.equal(parsed.events[0].fdt_code, '41');
  assert.equal(parsed.events[0].port_code, '9');
});

test('التوقيت مستقل عن جهاز الاستيراد', () => {
  // المصدر بلا منطقة زمنية. قراءتُه محلياً تجعل النتيجة تابعة لمن استورد،
  // وحدثٌ قرب حدّ الشهر قد يقع في دورة أخرى. المنطقة مثبَّتة على +03:00،
  // وهي المنطقة التي خُزِّنت بها بيانات تموز في الإنتاج فعلاً.
  const at = (raw) => S.parseActivationSheet(
    [{ ...EVENT_HEADERS, created_at: raw }], {}).events[0].event_created_at;

  // أقصى حدث في تموز الحقيقي: مخزَّن في الإنتاج 2026-07-31T20:58:30.000Z
  assert.equal(at('2026-07-31 23:58:30'), '2026-07-31T20:58:30.000Z');
  assert.equal(at('2026-04-30 235650'), '2026-04-30T20:56:50.000Z');

  // ومنطقة صريحة تُحترم كما وردت ولا تُزاح.
  assert.equal(at('2026-07-01T00:00:00Z'), '2026-07-01T00:00:00.000Z');
  assert.equal(at('2026-07-01T00:00:00+03:00'), '2026-06-30T21:00:00.000Z');
});

test('خليّة تاريخ Excel لا تتبع منطقة الجهاز هي الأخرى', () => {
  // الملف يُقرأ بـcellDates:true، فخليّة التاريخ تصل كائنَ Date مبنياً بساعة
  // الحائط في منطقة الجهاز لا بلحظة مطلقة. إخراجه بـtoISOString يُعيد الاعتماد
  // على الجهاز من باب خلفي: الملف نفسه يُنتج لحظتين مختلفتين باختلاف من
  // استورده — وهو ما ثُبِّت فرعُ النص أصلاً لمنعه.
  //
  // التوكيدان أدناه صحيحان في أي منطقة زمنية، لأن مكوّنات الحائط لا تتغيّر
  // بتغيّر المنطقة. لذلك يفشلان حيثما كان السلوك تابعاً للجهاز.
  const at = (value) => S.parseActivationSheet(
    [{ ...EVENT_HEADERS, created_at: value }], {}).events[0].event_created_at;

  // 00:30 من أول تموز: على الحدّ الذي يفصل دورتين، وهو موضع الخطر.
  assert.equal(at(new Date(2026, 6, 1, 0, 30, 0)), '2026-06-30T21:30:00.000Z');

  // النص والكائن يصفان اللحظة ذاتها، فلا يجوز أن يفترقا.
  assert.equal(at(new Date(2026, 6, 31, 23, 58, 30)), at('2026-07-31 23:58:30'));

  // وتاريخ غير صالح يبقى فارغاً لا يصير لحظةً مخترَعة.
  assert.equal(at(new Date(Number.NaN)), null);
});
