const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const html = fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8');

test('the executive overview and reports are wired in', () => {
  assert.ok(html.includes('id="executiveSection"'), 'overview section missing');
  assert.ok(html.includes('./assets/js/reporting.js'), 'module not loaded');
  assert.ok(html.includes('initReporting()'), 'never initialised');
});

test('every report panel has a matching tab', () => {
  const tabs = [...html.matchAll(/data-rp="([a-z]+)"/g)].map((m) => m[1]);
  const panels = [...html.matchAll(/id="rp-([a-z]+)"/g)].map((m) => m[1]);
  assert.ok(tabs.length >= 6, `expected 6 report tabs, found ${tabs.length}`);
  tabs.forEach((t) => assert.ok(panels.includes(t), `panel missing for ${t}`));
  panels.forEach((p) => assert.ok(tabs.includes(p), `tab missing for ${p}`));
});

test('the six approved reports all have a surface', () => {
  ['report_management_summary', 'report_commission_cycle_detail', 'report_agent_statement',
   'installation_financials', 'report_open_exceptions', 'report_audit_trail']
    .forEach((rpc) => {
      assert.ok(html.includes('/rest/v1/rpc/' + rpc), `report RPC not called: ${rpc}`);
    });
});

test('the inline application script still parses', () => {
  const blocks = [...html.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)]
    .map((m) => m[1]);
  assert.equal(blocks.length, 1);
  assert.doesNotThrow(() => new vm.Script(blocks[0], { filename: 'index.html' }));
});

test('report totals are never recomputed in the page', () => {
  const block = html.slice(html.indexOf('/* ---- التقارير والدفع'),
    html.indexOf('function switchTab(z)'));
  assert.ok(block.length > 500, 'reporting block not found');
  // لا مبالغ ثابتة ولا اشتقاق: الأرقام تُقرأ من ردّ الخادم.
  assert.ok(!/\b(4000|4750|5500|6000|8000|9000|11500|13000)\b/.test(block),
    'the reporting block hardcodes an amount');
  assert.ok(!/reduce\(\([^)]*\)\s*=>\s*[a-z]+\s*\+/.test(block),
    'the reporting block sums financial rows itself');
});

test('payout posting goes through the server RPC and confirms first', () => {
  assert.ok(html.includes('/rest/v1/rpc/post_commission_batch'), 'post RPC missing');
  assert.ok(html.includes('/rest/v1/rpc/revalidate_commission_batch'), 'revalidate RPC missing');
  const post = html.slice(html.indexOf('async function postPayout'),
    html.indexOf('function initReporting'));
  assert.ok(post.includes('confirm('), 'posting money without confirmation');
  assert.ok(post.includes('createRequestId()'), 'posting without an idempotency key');
});

test('export buttons are hidden without the export capability', () => {
  assert.ok(html.includes('"rpExportCycle","report.export"')
    || html.includes("hide(\"rpExportCycle\",\"report.export\")"),
    'cycle export is not capability-gated');
  assert.ok(html.includes('rpExportExceptions'), 'exception export missing');
  assert.ok(html.includes('audit.view'), 'audit tab is not capability-gated');
});

test('the payout tab is gated on the payment capability, not merely shown', () => {
  assert.ok(html.includes('commission.prepare_payment'),
    'payout surface is not capability-gated');
});

test('exports use the declared column list, not the raw response shape', () => {
  assert.ok(html.includes('Reporting.COMMISSION_EXPORT_COLUMNS'),
    'cycle export does not use the declared columns');
  assert.ok(html.includes('Reporting.EXCEPTION_EXPORT_COLUMNS'),
    'exception export does not use the declared columns');
});

test('status vocabulary comes from one place', () => {
  // مفردة واحدة لكل حالة في كل الشاشات: تكرارها نصّاً يجعلها تتباعد.
  assert.ok(html.includes('Reporting.statusLabel'), 'status labels not centralised');
  const block = html.slice(html.indexOf('/* ---- التقارير والدفع'),
    html.indexOf('function switchTab(z)'));
  assert.ok(!/["']معتمدة["']/.test(block), 'a status label is hardcoded in the page');
});

test('the cabinet surface never infers a zone', () => {
  // انتقل السطح من #/legacy إلى شاشة الكابينات، والضمانة تُفحص حيث صارت.
  // الشاشة السابقة تُحوِّل الآن ولا تكتب — سلطة واحدة لا سلطتان.
  const fdts = fs.readFileSync(path.join(ROOT, 'src/features/master/fdts.ts'), 'utf8');
  assert.match(fdts, /register_fdt/);
  assert.match(fdts, /المنطقة إلزامية/);
  // لا قيمة منطقة افتراضية في الشيفرة.
  assert.ok(!/p_zone:s*['"](old|new)['"]/.test(fdts), 'a zone is defaulted instead of chosen');

  // والشاشة السابقة لم تعد تكتب.
  assert.ok(!html.includes('/rest/v1/rpc/register_fdt'),
    'legacy still writes cabinets — two authorities');
});
test('FDT onboarding is gated on the master-data capability', () => {
  assert.ok(html.includes('opsCan("fdt.manage")'), 'onboarding is not capability-gated');
});
