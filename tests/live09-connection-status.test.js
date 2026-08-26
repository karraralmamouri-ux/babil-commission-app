// LIVE-09: مؤشّر الاتصال يبقى "جاري الاتصال" إلى الأبد.
//
// السبب الحقيقي طبقتان، لا طبقة واحدة:
//  1) workspaceMode لا يغادر 'loading' لمن لا يستعمل مساحة العمل السابقة —
//     مُصلَح بحالة 'idle' جديدة تُفعَّل بعد استقرار الصلاحيات (نجاحاً أو فشلاً).
//  2) الأسبق والأخطر: updateCentralPreviewUI نفسها كانت تُخرَج فوراً لأن
//     شرطها يستلزم وجود #centralPreviewButton — زرٌّ تقاعد فعلاً مع محرّك
//     تجهيز الشهر (راجع central-preview.test.js) ولم يعد في الصفحة إطلاقاً.
//     فالدالّة كانت لا تلمس #centralStatus مهما كانت قيمة workspaceMode —
//     فالإصلاح الأول وحده كان ميتاً حتى يُزال هذا الشرط.
//
// الاختباران التاليان يُنفَّذان فعلاً عبر sandbox يُشغِّل index.html كما هو،
// لا نصّاً يُطابَق بتعبير نمطي.

const test = require('node:test');
const assert = require('node:assert/strict');

const { loadCurrentApp } = require('./load-current-app');

function fetchOk(body) {
  return async () => ({ ok: true, status: 200, text: async () => JSON.stringify(body) });
}

function fetchFails() {
  return async () => { throw new Error('network down'); };
}

// 404 يعني حساباً بلا صف صلاحيات مسجّل — حالة طبيعية، لا عطل شبكي. يجب ألا
// تُعامَل كانقطاع اتصال ولا تُظهر "تعذر التحقّق من الاتصال".
function fetchNotFound() {
  return async () => ({ ok: false, status: 404, text: async () => '{}' });
}

// #centralPreviewButton تقاعد من الصفحة فعلاً؛ محاكاة ذلك تحتاج أن يُعيد
// getElementById بالضبط null لهذا المعرِّف، لا عنصراً وهمياً كسائر المعرّفات.
function elementsWithoutCentralButton() {
  const elements = new Map();
  elements.set('centralPreviewButton', null);
  return elements;
}

test('a successful capabilities fetch clears "جاري الاتصال" even though centralPreviewButton is gone', async () => {
  const app = loadCurrentApp({ fetch: fetchOk([]), elements: elementsWithoutCentralButton() });

  app.setWorkspaceMode('loading');
  app.updateCentralPreviewUI();
  // العنصر يُنشَأ كسولاً عند أوّل getElementById؛ لا يُقرَأ قبل هذا الاستدعاء.
  const status = app.__elements.get('centralStatus');
  assert.match(status.innerHTML, /جاري الاتصال/);

  await app.loadMyCapabilities();

  assert.equal(app.__getWorkspaceMode(), 'idle');
  assert.match(status.innerHTML, /متصل/);
  assert.doesNotMatch(status.innerHTML, /جاري الاتصال/);
});

test('a failed (unreachable) capabilities fetch clears "جاري الاتصال" but must NOT falsely claim "متصل"', async () => {
  // هنا يكمن الفرق الجوهري عن الإصدار الأول من إصلاح LIVE-09: "وصل الفحص"
  // (opsCapabilitiesReady) لا يعني "الشبكة متّصلة". عطلٌ شبكي حقيقي يجب أن
  // يُعرَض بصراحة، لا أن يُطمَس بشارة "متصل" خضراء كاذبة.
  const app = loadCurrentApp({ fetch: fetchFails(), elements: elementsWithoutCentralButton() });

  app.setWorkspaceMode('loading');
  app.updateCentralPreviewUI();
  const status = app.__elements.get('centralStatus');
  assert.match(status.innerHTML, /جاري الاتصال/);

  await app.loadMyCapabilities();

  assert.equal(app.__getWorkspaceMode(), 'offline');
  assert.match(status.innerHTML, /تعذر التحقّق من الاتصال/);
  assert.doesNotMatch(status.innerHTML, /جاري الاتصال/);
  assert.doesNotMatch(status.innerHTML, /(^|[^ت])متصل/, 'لا يجوز أن تظهر "متصل" أثناء عطل شبكي حقيقي');
});

test('a 404 (no capabilities row yet — a normal account state, not a network failure) still resolves to "متصل"', async () => {
  const app = loadCurrentApp({ fetch: fetchNotFound(), elements: elementsWithoutCentralButton() });

  app.setWorkspaceMode('loading');
  await app.loadMyCapabilities();

  assert.equal(app.__getWorkspaceMode(), 'idle');
  const status = app.__elements.get('centralStatus');
  assert.match(status.innerHTML, /متصل/);
});

test('loadMyCapabilities does not clobber an active or in-progress legacy workspace mode', async () => {
  const app = loadCurrentApp({ fetch: fetchOk([]), elements: elementsWithoutCentralButton() });

  for (const mode of ['central', 'preparation', 'unavailable']) {
    app.setWorkspaceMode(mode);
    await app.loadMyCapabilities();
    assert.equal(app.__getWorkspaceMode(), mode, `loadMyCapabilities تجاوز حالة ${mode} الصريحة`);
  }
});

test('updateCentralPreviewUI renders every known workspace mode without a live centralPreviewButton', () => {
  const app = loadCurrentApp({ elements: elementsWithoutCentralButton() });

  app.setWorkspaceMode('central');
  app.updateCentralPreviewUI();
  const status = app.__elements.get('centralStatus');
  assert.match(status.innerHTML, /البيانات المركزية/);

  app.setWorkspaceMode('unavailable');
  app.updateCentralPreviewUI();
  assert.match(status.innerHTML, /تعذر الاتصال بالمركز/);

  app.setWorkspaceMode('idle');
  app.updateCentralPreviewUI();
  assert.match(status.innerHTML, /متصل/);

  app.setWorkspaceMode('offline');
  app.updateCentralPreviewUI();
  assert.match(status.innerHTML, /تعذر التحقّق من الاتصال/);
});

test('centralPreview.active لا يملك حالة الاتصال العامة — workspaceMode وحده يقرّر نصّ الشارة', () => {
  const app = loadCurrentApp({ elements: elementsWithoutCentralButton() });

  app.setWorkspaceMode('idle');
  app.centralPreview.active = true;
  app.updateCentralPreviewUI();
  const status = app.__elements.get('centralStatus');
  assert.match(status.innerHTML, /متصل/, 'centralPreview.active وحده يجب ألا يُخرج الشارة عن حالة workspaceMode الفعلية');

  app.centralPreview.active = false;
  app.setWorkspaceMode('offline');
  app.updateCentralPreviewUI();
  assert.match(status.innerHTML, /تعذر التحقّق من الاتصال/, 'العطل الشبكي يظهر حتى مع centralPreview.active=false');
});
