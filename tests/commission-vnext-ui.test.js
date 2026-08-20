const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const html = fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8');

test('the commission workspace and its module are wired into the page', () => {
  assert.ok(html.includes('id="commissionVNextSection"'), 'commission section missing');
  assert.ok(html.includes('./assets/js/commission-vnext.js'), 'module not loaded');
  assert.ok(html.includes('initCommissionVNext()'), 'workspace never initialised');
});

test('every commission panel has a matching tab', () => {
  const tabs = [...html.matchAll(/data-cx="([a-z]+)"/g)].map((m) => m[1]);
  const panels = [...html.matchAll(/id="cx-([a-z]+)"/g)].map((m) => m[1]);
  assert.ok(tabs.length >= 5, `expected at least 5 tabs, found ${tabs.length}`);
  tabs.forEach((t) => assert.ok(panels.includes(t), `panel missing for tab ${t}`));
  panels.forEach((p) => assert.ok(tabs.includes(p), `tab missing for panel ${p}`));
});

test('the inline application script still parses', () => {
  const blocks = [...html.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)]
    .map((m) => m[1]);
  assert.equal(blocks.length, 1);
  assert.doesNotThrow(() => new vm.Script(blocks[0], { filename: 'index.html' }));
});

test('the commission block never computes a tier or an amount in the browser', () => {
  const block = html.slice(html.indexOf('/* ---- العمولة vNext'),
    html.indexOf('function switchTab(z)'));
  assert.ok(block.length > 500, 'commission block not found');
  // لا أسعار شرائح ولا حدود: كلها من الخادم.
  assert.ok(!/\b(4000|4750|5500|6000|8000|9000|11500|200|400)\b/.test(block),
    'the commission block hardcodes a tier bound or rate');
  // ولا اشتقاق لأساس الشريحة من عدد الأحداث.
  assert.ok(!/unique[A-Za-z]*\s*=\s*[^;]*qualifying/i.test(block),
    'the page derives the tier basis from the event count');
});

const cycleScreen = fs.readFileSync(
  path.join(ROOT, 'src/features/commissions/index.ts'), 'utf8');

test('finalization and reopen go through the audited server RPCs', () => {
  // هذه الانتقالات كانت تجري من الشاشة السابقة وانتقلت إلى شاشة الدورة.
  // الاختبار يتبعها إلى حيث صارت بدل أن يُحذف: الحكم الذي يحرسه لم يتغيّر.
  assert.ok(cycleScreen.includes('calculate_commission_cycle'), 'calculation RPC missing');
  assert.ok(cycleScreen.includes('reopen_commission_cycle'), 'reopen RPC missing');
  assert.ok(cycleScreen.includes('resolve_commission_exception'), 'exception RPC missing');
  assert.ok(cycleScreen.includes('close_commission_cycle'), 'close RPC missing');

  // لا كتابة مباشرة على جداول العمولة — لا من هنا ولا من هناك.
  assert.ok(!/commission_cycle_snapshots\?[^"']*method:\s*"(POST|PATCH|DELETE)"/.test(html),
    'the page writes snapshots directly');
  assert.doesNotMatch(cycleScreen, /commission_cycle_snapshots\?[^`'"]*(POST|PATCH|DELETE)/);
});

test('the reopen and exception paths demand a written reason', () => {
  // السبب يُشترط قبل النداء، ويشترطه الخادم أيضاً. الشرطان مقصودان:
  // الواجهة تمنع الرحلة الضائعة، والخادم يمنع الالتفاف عليها.
  const workflow = cycleScreen.slice(cycleScreen.indexOf('function wireWorkflow'));
  assert.ok(workflow.includes("'إعادة الفتح', true"), 'reopen does not demand a reason');
  assert.ok(workflow.includes("'الإقفال', true"), 'close does not demand a reason');
  assert.match(cycleScreen, /السبب إلزامي/);

  const resolve = cycleScreen.slice(cycleScreen.indexOf('function wireResolve'));
  assert.ok(resolve.includes('السبب إلزامي'), 'exception resolution does not demand a reason');
});

test('the two metrics are labelled distinctly wherever they are shown', () => {
  const C = require('../assets/js/commission-vnext.js');
  // مقياسان مختلفان اسماً ومفتاحاً — خلطهما هو الخطأ الذي أُنشئ المحرّك لإزالته.
  assert.notEqual(C.METRICS.tierBasis.key, C.METRICS.billable.key);
  assert.notEqual(C.METRICS.tierBasis.label, C.METRICS.billable.label);
  assert.ok(html.includes('METRICS.tierBasis.label'), 'tier basis label not used in the page');
  assert.ok(html.includes('METRICS.billable.label'), 'billable label not used in the page');
});

test('the legacy commission path is marked compatibility-only and accurately', () => {
  assert.ok(html.includes('LEGACY / COMPATIBILITY ONLY'),
    'the legacy calculation is not marked');
  // الوسم يذكر المخالفة الحقيقية: أساس الشريحة، لا إزالة التكرار.
  assert.ok(html.includes('p35+p45+p65'),
    'the marker does not name the actual violation');
  assert.ok(html.includes('tier_basis_qty هنا LEGACY UNVERIFIED CLIENT INPUT'),
    'tier_basis_qty is no longer marked');
});

test('seenIds still deduplicates on the event id, which is the correct level', () => {
  // هذا ليس عيباً يُصلَح: عمود id في الملف الخام هو معرّف الحدث، وقياسه
  // أثبت تميّزه التام. الاختبار يمنع «إصلاحاً» يحوّله إلى مستوى المشترك.
  const line = html.split('\n').find((l) => l.includes('seenIds.has(id)'));
  assert.ok(line, 'seenIds check disappeared');
  assert.ok(/id\s*=\s*rawText\(rawField\(row,\s*'id'\)\)/.test(html),
    'the dedup key is no longer the raw event id');
  assert.ok(!/seenIds\.has\(\s*(username|subscriber)/i.test(html),
    'deduplication moved to the subscriber level, which would discard real events');
});
