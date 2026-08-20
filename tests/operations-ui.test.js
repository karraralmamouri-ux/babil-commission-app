const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const html = fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8');

// `.` لا يطابق \r في جافاسكربت، وindex.html يحمل نهايات أسطر مختلطة.
// كل بحث هنا يتعامل مع النص كما هو بلا تطبيع.

test('the operations workspace and its modules are wired into the page', () => {
  assert.ok(html.includes('id="operationsSection"'), 'operations section missing');
  assert.ok(html.includes('./assets/js/operations.js'), 'operations module not loaded');
  assert.ok(html.includes('./assets/js/saas-import.js'), 'saas import module not loaded');
  assert.ok(html.includes('initOperationsWorkspace()'), 'workspace never initialised');
});

test('every operations panel has a matching tab', () => {
  const tabs = [...html.matchAll(/data-ops="([a-z]+)"/g)].map((m) => m[1]);
  const panels = [...html.matchAll(/id="ops-([a-z]+)"/g)].map((m) => m[1]);
  assert.ok(tabs.length >= 6, `expected at least 6 tabs, found ${tabs.length}`);
  tabs.forEach((tab) => assert.ok(panels.includes(tab), `panel missing for tab ${tab}`));
  panels.forEach((panel) => assert.ok(tabs.includes(panel), `tab missing for panel ${panel}`));
});

test('the inline application script still parses after insertion', () => {
  const blocks = [...html.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)]
    .map((m) => m[1]);
  assert.equal(blocks.length, 1, 'expected exactly one inline script block');
  assert.doesNotThrow(() => new vm.Script(blocks[0], { filename: 'index.html' }));
});

test('sensitive workspaces are hidden behind a capability, not shown to everyone', () => {
  // إخفاء الواجهة ليس إنفاذاً — الإنفاذ في الخادم — لكن عرض ما لا يُستطاع
  // استعماله يُنتج أخطاءً بلا فائدة.
  ['saas.import', 'scheme.manage', 'agent.manage', 'permission.manage', 'payment.correct']
    .forEach((cap) => {
      assert.ok(html.includes(`"${cap}"`), `capability ${cap} is never checked in the page`);
    });
  assert.ok(html.includes('applyCapabilityVisibility'), 'visibility is never applied');
});

test('permission changes go through the audited RPC, never a direct table write', () => {
  // Permission editing moved to the users screen; the rule moved with it.
  const users = require('node:fs').readFileSync(
    require('node:path').join(__dirname, '..', 'src/features/system/users.ts'), 'utf8');

  assert.ok(users.includes('set_user_permission'), 'permission RPC not called');
  assert.ok(users.includes('update_user_profile'), 'profile RPC not called');
  // Neither screen writes the override table or the profile table directly.
  const direct = /(user_permission_overrides|profiles)\?[^`'"]*(POST|PATCH|DELETE)/;
  assert.ok(!direct.test(html), 'the legacy page writes permissions directly');
  assert.ok(!direct.test(users), 'the users screen writes permissions directly');
  // And the legacy page no longer calls the RPC either — one authority only.
  assert.ok(!html.includes('/rest/v1/rpc/set_user_permission'),
    'two screens still change permissions');
});

test('eligibility is read from the server, never recomputed in the page', () => {
  assert.ok(html.includes('/rest/v1/rpc/installation_entitlement_eligibility'),
    'eligibility RPC not called');
  // لا جدول مبالغ مراحل مُثبت داخل كتلة العمليات: المبالغ من المخطط.
  const block = html.slice(html.indexOf('/* ---- العمليات المالية'),
    html.indexOf('function switchTab(z)'));
  assert.ok(!/\b(3000|4000|13000)\b/.test(block),
    'the operations block hardcodes a stage amount instead of reading the scheme');
});

test('the import preview reports dropped secrets and never echoes the column', () => {
  const block = html.slice(html.indexOf('async function previewSaasImport'),
    html.indexOf('async function loadImportBatches'));
  assert.ok(block.includes('secretsDropped'), 'dropped-secret count is not surfaced');
  assert.ok(!block.includes('ct_password'), 'the page names the secret column');
});

test('the operations module never decides money on its own', () => {
  const src = fs.readFileSync(path.join(ROOT, 'assets/js/operations.js'), 'utf8');
  // لا مبالغ ثابتة ولا قواعد أهلية: الوحدة تعرض ما قرّره الخادم.
  assert.ok(!/\b(3000|4000|13000)\b/.test(src), 'operations.js hardcodes an amount');
  assert.ok(!/eligible\s*=\s*(true|false)/.test(src), 'operations.js decides eligibility');
});
