// رحلة كاملة: مسوّدةٌ لم تُحسب بعد، من نظرة عامة إلى زرّ الإلغاء الحقيقي.
//
// PR #85 وضع بطاقة توجيهٍ في Overview تشير إلى تبويب المراجعة والاعتماد.
// لكن `renderCycle` كانت تعود مبكراً بحالة «لا نتيجة محسوبة» متى كانت
// الدورة DRAFT بلا `calculated_at` — وهذه بالضبط حالة المسوّدة العرضية،
// فمبدّل التبويبات لا يُنفَّذ إطلاقاً و`workflowPanel`/`wireWorkflow` لا
// يُبنيان، وزرّ الإلغاء الذي تُشير إليه البطاقة غير موجود خلف رابطها.
//
// هذا الملف يختبر الرحلة من طرفها إلى طرفها كنصٍّ منفَّذ ومقروء معاً:
// DRAFT + calculated_at=null + القدرة → Overview بلا أرقامٍ مصطنعة →
// بطاقة ظاهرة → رابطٌ صالح → صفحة الدورة تُبنى وتبويباتها حيّة →
// تبويب المراجعة يصل إلى workflowPanel → الزرّ الحقيقي يظهر → ولا RPC
// إلغاءٍ يُنادى قبل ضغطة المستخدم.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');
const norm = (p) => read(p).split('\r\n').join('\n');

const src = norm('src/features/commissions/index.ts');

function slice(from, to) {
  const a = src.indexOf(from);
  const b = src.indexOf(to, a);
  assert.ok(a >= 0, `لم يوجد: ${from}`);
  assert.ok(b > a, `لم يوجد: ${to}`);
  return src.slice(a, b);
}

const renderCycle = slice('async function renderCycle(view: View', '\nasync function renderCycleTab');
const renderCycleTab = slice('async function renderCycleTab(view: View', '\nconst num = ');
const reviewBranch = slice("if (tab === 'review') {", "if (tab === 'payout') {");

function evalTs(source, names) {
  const js = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
  }).outputText;
  const sandbox = { module: { exports: {} }, exports: {}, console, require: () => ({}) };
  sandbox.exports = sandbox.module.exports;
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(js, sandbox);
  const out = {};
  names.forEach((n) => { out[n] = sandbox.module.exports[n]; });
  return out;
}

const { canCancelDraft } = evalTs(read('src/features/commissions/cancelDraft.ts'), ['canCancelDraft']);

/* ---------------------------------------------------------------------------
   ١ · Overview: بلا أرقامٍ مصطنعة، والبطاقة ظاهرة (من PR #85، غير مُعاد بناؤه)
   ------------------------------------------------------------------------ */

test('step 1 — Overview shows no synthetic totals and a visible cancel path for a capable DRAFT viewer', () => {
  const overviewSrc = slice('export const overview: Route = {', '\n/**\n * بطاقة توجيهٍ لدورةٍ لا تزال مسوّدة');
  assert.match(overviewSrc, /canCancelDraft\(current\.status, can\('commission\.manage_cycle'\)\)/);
  assert.match(overviewSrc, /empty\('لا نتيجة محسوبة لهذه الدورة بعد'/);
  assert.match(overviewSrc, /\+ draftCard/);
  assert.equal(canCancelDraft('DRAFT', true), true);
});

test('step 2 — the card link is exactly the review tab URL renderCycle actually serves', () => {
  const cardFn = slice('function draftActionsCard', '\n/**\n * المصالحة المرئية');
  assert.match(cardFn, /href\(`\/commissions\/cycles\/\$\{cycle\.id\}\/review`\)/);
  // ونفس النمط الذي يبنيه cycleTab نفسه لروابط تبويباته.
  assert.match(renderCycle, /href\(`\/commissions\/cycles\/\$\{id\}\/\$\{t\.key\}`\)/);
});

/* ---------------------------------------------------------------------------
   ٣ · renderCycle: لا عودة مبكرة تقطع الرندر قبل التبويبات
   ------------------------------------------------------------------------ */

test('step 3 — renderCycle no longer returns before building the tabs when result is null', () => {
  // العطل السابق: عودةٌ مبكرة بعد فحص `!result` مباشرة، قبل بناء `tabs`
  // أو `view.write` الذي يحمل صندوق التبويبات.
  const afterCatch = renderCycle.slice(renderCycle.indexOf('if (!view.live) return;'));
  const earlyReturn = /if \(!result\) \{[\s\S]{0,400}return;\s*\}/;
  assert.doesNotMatch(afterCatch, earlyReturn);

  // والتبويبات وصندوقها يُبنيان دائماً — لا داخل شرطٍ يتطلّب `result`.
  // (أوّل ظهورٍ لـ`view.write(pageHeader(cycle.name,` هو مسار الخطأ في
  // catch — نتجاوزه إلى نداء الرسم الفعلي بعد بناء التبويبات.)
  const tabsBuild = renderCycle.indexOf('const tabs = CYCLE_TABS.map');
  const writeCall = renderCycle.indexOf("view.write(pageHeader(cycle.name,", tabsBuild);
  const rpcCall = renderCycle.indexOf('await renderCycleTab(view, cycle, result, tab, m)');
  assert.ok(tabsBuild > -1 && writeCall > tabsBuild && rpcCall > writeCall);
  // ونداء renderCycleTab غير مشروط بوجود result — نفس مساره في الحالتين.
  const between = renderCycle.slice(writeCall, rpcCall);
  assert.doesNotMatch(between, /if \(result\)|if \(!result\)/);
});

test('step 4 — a null result renders an honest notice, never a synthetic zero total', () => {
  const summary = slice('const summary = result', '\n  view.write(pageHeader(cycle.name,');
  assert.match(summary, /\? kpiRow\(/);
  assert.match(summary, /: insight\('warn', 'لم تُحسب هذه الدورة بعد'/);
  // الفرع الفارغ لا يبني kpiRow ولا money(...) على الإطلاق.
  const nullBranch = summary.slice(summary.indexOf(': insight'));
  assert.doesNotMatch(nullBranch, /kpiRow\(|money\(/);
});

test('renderCycleTab now accepts a null result explicitly, typed not cast', () => {
  assert.match(src, /async function renderCycleTab\(view: View, cycle: Cycle, result: CycleResult \| null, tab: string, m: RouteMatch\)/);
});

/* ---------------------------------------------------------------------------
   ٥ · تبويبات مالية أخرى: لا صفرٌ مصطنع لدورةٍ غير محسوبة
   ------------------------------------------------------------------------ */

test('the in-cycle overview tab (zone breakdown) shows a no-result state, not an empty table read as zero', () => {
  const zoneBranch = slice('// overview — نفس عقد النتيجة', 'result.zones as unknown as Array<Record<string, unknown>>)}</div>`\n    : empty(\'لا تفصيل متاح\'));\n}');
  assert.match(zoneBranch, /if \(!result\) \{/);
  assert.match(zoneBranch, /empty\('لم تُحسب هذه الدورة بعد'/);
  const guardIdx = zoneBranch.indexOf('if (!result)');
  const useIdx = zoneBranch.indexOf('result.zones.length');
  assert.ok(guardIdx > -1 && guardIdx < useIdx, 'الحارس يجب أن يسبق أوّل استعمال لـresult');
});

test('scopes, events, exceptions, payout and audit tabs never read from `result` — they already query the server directly', () => {
  // نهاية الفرع الأخير (audit) هي بداية التعليق الذي يفتح الفرع الافتراضي
  // (overview) — وهو الفرع الوحيد الذي يعتمد على result عمداً، فيُستبعد صراحةً.
  const defaultBranchStart = renderCycleTab.indexOf('// overview — نفس عقد النتيجة');
  for (const tabName of ["'scopes'", "'events'", "'exceptions'", "'payout'", "'audit'"]) {
    const start = renderCycleTab.indexOf(`if (tab === ${tabName}) {`);
    assert.ok(start > -1, tabName);
    let end = renderCycleTab.indexOf('\n  if (tab ===', start + 1);
    if (end === -1 || end > defaultBranchStart) end = defaultBranchStart;
    const block = renderCycleTab.slice(start, end);
    assert.doesNotMatch(block, /\bresult\./, `${tabName} يجب ألّا يعتمد على result`);
  }
});

/* ---------------------------------------------------------------------------
   ٦ · تبويب المراجعة: workflowPanel وwireWorkflow يصلان فعلاً
   ------------------------------------------------------------------------ */

test('step 5 — the review tab reaches workflowPanel and wires wireWorkflow, independent of result', () => {
  assert.match(reviewBranch, /\+ workflowPanel\(cycle, open\.length\)/);
  assert.match(reviewBranch, /wireWorkflow\(view, cycle, open\.length\);/);
  // ومصدر الحجب RPC مستقلّ عن `result` — لا يقرأ منه شيئاً.
  assert.doesNotMatch(reviewBranch, /\bresult\./);
});

test('step 6 — the real cancel button renders in workflowPanel for a capable DRAFT viewer', () => {
  const panelRow = slice("if (canCancelDraft(", 'if (!rows.length)');
  assert.match(panelRow, /canCancelDraft\(cycle\.status, can\('commission\.manage_cycle'\)\)/);
  assert.match(panelRow, /id="wfCancelDraft"/);
  assert.equal(canCancelDraft('DRAFT', true), true);
});

test('a DRAFT viewer without commission.manage_cycle never sees the cancel button', () => {
  assert.equal(canCancelDraft('DRAFT', false), false);
});

test('UNDER_REVIEW (or any status with a computed result) keeps the original financial header untouched', () => {
  const trueBranch = slice('const summary = result\n    ? kpiRow([', ': insight(');
  // نفس السطور المالية الأربعة والصندوق التشغيلي، حرفياً كما قبل الإصلاح.
  assert.match(trueBranch, /عمولة محسوبة/);
  assert.match(trueBranch, /money\(result\.totals\.approved\)/);
  assert.match(trueBranch, /money\(result\.totals\.paid\)/);
  assert.match(trueBranch, /class="box cycle-operational-result"/);
});

/* ---------------------------------------------------------------------------
   ٧ · لا RPC إلغاءٍ قبل ضغطة المستخدم، ولا تكرار منطق
   ------------------------------------------------------------------------ */

test('step 7 — no cancellation RPC fires as part of rendering the review tab', () => {
  assert.doesNotMatch(reviewBranch, /cancel_empty_commission_cycle/);
  // النداء الوحيد لهذه الدالّة في كامل الملف هو داخل مُعالِج الضغط.
  const sites = [...src.matchAll(/\brpc[^(]*\('cancel_empty_commission_cycle'/g)];
  assert.equal(sites.length, 1);
  const around = src.slice(sites[0].index - 800, sites[0].index);
  assert.match(around, /addEventListener\('click'/);
});

test('no RPC, confirmation, error-mapping or capability rule is duplicated by this fix', () => {
  assert.doesNotMatch(renderCycle, /cancel_empty_commission_cycle|cancelDraftError|cancelDraftSuccess/);
  assert.doesNotMatch(renderCycleTab, /cancelDraftError|cancelDraftSuccess/);
  // renderCycleTab يستدعي cancel_empty_commission_cycle مرّةً واحدة فقط،
  // من داخل wireWorkflow المستدعاة من قِبَله — لا مسارٍ ثانٍ يُعيد بناءها.
  const rpcMentions = (renderCycleTab.match(/cancel_empty_commission_cycle/g) || []).length;
  assert.equal(rpcMentions, 0, 'renderCycleTab نفسها لا تذكر الدالّة — الذكر الوحيد داخل wireWorkflow');
});

/* ---------------------------------------------------------------------------
   ٨ · حدث الصلاحيات ما زال يُحدِّث الظهور
   ------------------------------------------------------------------------ */

test('the capabilities event still exists end to end: dispatched after load, and listened to for a repaint', () => {
  const html = norm('index.html');
  const fn = html.slice(html.indexOf('async function loadMyCapabilities'));
  const body = fn.slice(0, fn.indexOf('catch(error)'));
  const applyAt = body.indexOf('applyCapabilityVisibility()');
  const dispatchAt = body.indexOf('dispatchEvent(new CustomEvent("babil:capabilities"))');
  assert.ok(applyAt > -1 && dispatchAt > applyAt);

  const mainSrc = norm('src/main.ts');
  const listener = mainSrc.slice(mainSrc.indexOf("addEventListener('babil:capabilities'"));
  const listenerBody = listener.slice(0, listener.indexOf('});') + 3);
  assert.match(listenerBody, /renderNav\(/);
  assert.match(listenerBody, /router\.refresh\(\)/);
});
