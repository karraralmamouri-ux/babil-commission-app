// LIVE-08: مسار يتطلّب قدرة قد يُعرَض "ممنوع" وهماً قبل وصول الصلاحيات من
// الخادم — لأن can() وعدم امتلاك القدرة يتماثلان: كلاهما false أثناء التحميل.
//
// السلسلة المطلوبة: AUTH UNKNOWN/LOADING → لا "ممنوع" بعد، شاشة تحميل فقط
// → PROFILE/CAPABILITIES READY → route ALLOW/DENY الحقيقي. بلا إضعاف صلاحية:
// من لا يملك القدرة يُمنَع بمجرّد وصول الصلاحيات، لا بعدها بأبد.
//
// الاختبار يُنفِّذ Router الحقيقي من src/app/router.ts عبر ts.transpileModule
// + vm، لا نسخة معاد كتابتها يدوياً — نفس أسلوب overview-draft-actions-card.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');

const root = path.join(__dirname, '..');
const routerSrc = fs.readFileSync(path.join(root, 'src', 'app', 'router.ts'), 'utf8')
  .split('\r\n').join('\n');

function loadRouter() {
  const js = ts.transpileModule(routerSrc, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
  }).outputText;

  let hash = '#/';
  const listeners = { hashchange: [] };
  const window_ = {
    location: { get hash() { return hash; }, set hash(v) { hash = v.startsWith('#') ? v : `#${v}`; } },
    history: { replaceState() {} },
    addEventListener(type, fn) { (listeners[type] ||= []).push(fn); },
    dispatchEvent() {},
    scrollY: 0,
    requestAnimationFrame() {},
    scrollTo() {},
  };

  const sandbox = {
    module: { exports: {} },
    exports: {},
    console,
    require: () => ({}),
    window: window_,
    URLSearchParams,
    AbortController,
    DOMException,
    HashChangeEvent: function HashChangeEvent(type) { this.type = type; },
  };
  sandbox.exports = sandbox.module.exports;
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(js, sandbox);
  return { Router: sandbox.module.exports.Router, setHash: (v) => { hash = v; } };
}

function outlet() {
  let html = '';
  return { get innerHTML() { return html; }, set innerHTML(v) { html = v; }, querySelector() { return null; } };
}

test('لا "ممنوع" أثناء تحميل الصلاحيات — شاشة تحميل فقط، لا حكم بعد', () => {
  const { Router, setHash } = loadRouter();
  const el = outlet();
  const calls = [];
  let ready = false;

  const router = new Router({
    outlet: el,
    routes: [{ pattern: '/reports', capability: 'report.view', title: 'ت', render: (v) => { v.innerHTML = 'REAL'; } }],
    can: () => { throw new Error('can() لا يجب أن يُستدعى قبل وصول الصلاحيات'); },
    capabilitiesReady: () => ready,
    renderCapabilityLoading: () => { calls.push('loading'); },
    renderForbidden: () => { calls.push('forbidden'); },
    renderNotFound: () => { calls.push('notfound'); },
    renderError: () => { calls.push('error'); },
  });

  setHash('#/reports');
  router.start();

  assert.deepEqual(calls, ['loading'], 'يجب أن تُعرَض شاشة التحميل فقط، لا "ممنوع" ولا الشاشة الحقيقية');
  assert.equal(el.innerHTML, '', 'renderCapabilityLoading لا يكتب هنا فعلياً، لكن REAL يجب ألا تُكتب أيضاً');
});

test('بعد وصول الصلاحيات: من يملك القدرة يصل للشاشة الحقيقية لا "ممنوع"', () => {
  const { Router, setHash } = loadRouter();
  const el = outlet();
  const calls = [];
  let ready = false;

  const router = new Router({
    outlet: el,
    routes: [{ pattern: '/reports', capability: 'report.view', title: 'ت', render: (v) => { v.innerHTML = 'REAL'; } }],
    can: (c) => { calls.push(`can:${c}`); return true; },
    capabilitiesReady: () => ready,
    renderCapabilityLoading: () => { calls.push('loading'); },
    renderForbidden: () => { calls.push('forbidden'); },
    renderNotFound: () => { calls.push('notfound'); },
    renderError: () => { calls.push('error'); },
  });

  setHash('#/reports');
  router.start();
  assert.deepEqual(calls, ['loading']);

  ready = true;
  router.refresh();

  assert.deepEqual(calls, ['loading', 'can:report.view']);
  assert.equal(el.innerHTML, 'REAL', 'الشاشة الحقيقية يجب أن تُرسَم بعد أن ثبت الحقّ');
});

test('بعد وصول الصلاحيات: من لا يملك القدرة يُمنَع فعلاً — لا إضعاف صلاحية', () => {
  const { Router, setHash } = loadRouter();
  const el = outlet();
  const calls = [];
  let ready = false;

  const router = new Router({
    outlet: el,
    routes: [{ pattern: '/reports', capability: 'report.view', title: 'ت', render: (v) => { v.innerHTML = 'REAL'; } }],
    can: () => false,
    capabilitiesReady: () => ready,
    renderCapabilityLoading: () => { calls.push('loading'); },
    renderForbidden: () => { calls.push('forbidden'); },
    renderNotFound: () => { calls.push('notfound'); },
    renderError: () => { calls.push('error'); },
  });

  setHash('#/reports');
  router.start();
  assert.deepEqual(calls, ['loading']);

  ready = true;
  router.refresh();

  assert.deepEqual(calls, ['loading', 'forbidden'], 'الحسم النهائي يجب أن يمنع فعلاً بعد وصول الصلاحيات');
  assert.equal(el.innerHTML, '', 'REAL لا يجب أن تُكتَب لمن لا يملك القدرة');
});

test('توافقٌ خلفي: بلا capabilitiesReady/renderCapabilityLoading، الحسم فوري كما قبل LIVE-08', () => {
  const { Router, setHash } = loadRouter();
  const el = outlet();
  const calls = [];

  const router = new Router({
    outlet: el,
    routes: [{ pattern: '/reports', capability: 'report.view', title: 'ت', render: (v) => { v.innerHTML = 'REAL'; } }],
    can: (c) => { calls.push(`can:${c}`); return false; },
    renderForbidden: () => { calls.push('forbidden'); },
    renderNotFound: () => { calls.push('notfound'); },
    renderError: () => { calls.push('error'); },
  });

  setHash('#/reports');
  router.start();

  assert.deepEqual(calls, ['can:report.view', 'forbidden']);
});
