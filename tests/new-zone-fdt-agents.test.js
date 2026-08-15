const test = require('node:test');
const assert = require('node:assert/strict');
const { loadCurrentApp } = require('./load-current-app');

// Arrays created inside the vm sandbox have a foreign prototype; copy them into
// this realm before structural comparison.
const own = (value) => Array.from(value);

// Tier rates used by every fixture below. The cabinet owns the tier; agent
// shares are priced with the cabinet's tier and never re-tiered per agent.
const TIERS = [
  { key: 't1', label: 'T1', min: 0, max: null, p35: 1000, p45: 2000, p65: 3000 },
];

function cabinet(name, breakdown) {
  const totals = breakdown.reduce(
    (sum, item) => ({
      p35: sum.p35 + (item.p35 || 0),
      p45: sum.p45 + (item.p45 || 0),
      p65: sum.p65 + (item.p65 || 0),
    }),
    { p35: 0, p45: 0, p65: 0 },
  );

  return {
    name,
    ...totals,
    customTier: 'auto',
    paid: 0,
    owner: 'Cabinet owner',
    sourceBreakdown: breakdown,
  };
}

function withNewZone(app, rows) {
  app.state.tiers = TIERS;
  app.state.data = { old: [], new: rows };
  return app.newZoneFdtBreakdown();
}

test('raw import resolves each source account to its configured agent', () => {
  const app = loadCurrentApp();
  const result = app.calculateRawImport(
    [
      { id: 1, parent: 'r.main', profile_name: 'P-35000', lastname: 'FDT:94 FAT:1 PORT:1' },
      { id: 2, parent: 'r.main.sub1', profile_name: 'P-45000', lastname: 'FDT:94 FAT:1 PORT:2' },
      { id: 3, parent: 'r.other', profile_name: 'P-65000', lastname: 'FDT:94 FAT:1 PORT:3' },
    ],
    {
      profiles: ['P-35000', 'P-45000', 'P-65000'],
      agents: [
        { id: 'main', name: 'Main agent', accounts: ['r.main', 'r.main.sub1'] },
        { id: 'other', name: 'Other agent', accounts: ['r.other'] },
      ],
      cabinetRanges: [{ id: 'range', from: 94, to: 95, ownerId: 'main' }],
    },
  );

  assert.equal(result.new.length, 1);
  const breakdown = result.new[0].sourceBreakdown;
  const byAccount = new Map(breakdown.map((item) => [item.parent, item]));

  // The contributing agent is recorded, not just the raw parent account.
  assert.equal(byAccount.get('r.main').agentId, 'main');
  assert.equal(byAccount.get('r.main').agentName, 'Main agent');
  assert.equal(byAccount.get('r.main.sub1').agentId, 'main');
  assert.equal(byAccount.get('r.other').agentId, 'other');
  assert.equal(byAccount.get('r.other').agentName, 'Other agent');
  // The source account is never lost.
  assert.deepEqual(own([...byAccount.keys()]).sort(), ['r.main', 'r.main.sub1', 'r.other']);
});

test('cabinet details group sub-accounts under one agent and reconcile exactly', () => {
  const app = loadCurrentApp();
  const breakdown = withNewZone(app, [
    cabinet('FDT-108', [
      { parent: 'r.a', agentId: 'a', agentName: 'Agent A', fdt: 108, p35: 10, p45: 5, p65: 0 },
      { parent: 'r.a.sub1', agentId: 'a', agentName: 'Agent A', fdt: 108, p35: 2, p45: 0, p65: 1 },
      { parent: 'r.b', agentId: 'b', agentName: 'Agent B', fdt: 108, p35: 3, p45: 4, p65: 2 },
    ]),
  ]);

  assert.equal(breakdown.cabinets.length, 1);
  const fdt = breakdown.cabinets[0];

  // Cabinet totals from the fixture.
  assert.deepEqual(
    { p35: fdt.p35, p45: fdt.p45, p65: fdt.p65, qty: fdt.qty },
    { p35: 15, p45: 9, p65: 3, qty: 27 },
  );

  // Two agents, not three accounts.
  assert.equal(fdt.agents.length, 2);
  const agentA = fdt.agents.find((agent) => agent.agentId === 'a');
  const agentB = fdt.agents.find((agent) => agent.agentId === 'b');

  assert.deepEqual(
    { p35: agentA.p35, p45: agentA.p45, p65: agentA.p65, qty: agentA.qty },
    { p35: 12, p45: 5, p65: 1, qty: 18 },
  );
  assert.deepEqual(
    { p35: agentB.p35, p45: agentB.p45, p65: agentB.p65, qty: agentB.qty },
    { p35: 3, p45: 4, p65: 2, qty: 9 },
  );

  // Sub-accounts stay visible underneath the agent.
  assert.deepEqual(own(agentA.accounts.map((item) => item.account)), ['r.a', 'r.a.sub1']);

  // Agent share uses the cabinet tier, and the shares add up to the cabinet total.
  assert.equal(agentA.total, 12 * 1000 + 5 * 2000 + 1 * 3000);
  assert.equal(agentB.total, 3 * 1000 + 4 * 2000 + 2 * 3000);
  assert.equal(agentA.total + agentB.total, fdt.total);
  assert.equal(fdt.reconciled, true);
  assert.equal(breakdown.reconciled, true);
});

test('an unresolved source account is reported instead of being shown as an agent name', () => {
  const app = loadCurrentApp();
  const breakdown = withNewZone(app, [
    cabinet('FDT-200', [
      { parent: 'r.unknown', agentId: '', agentName: '', fdt: 200, p35: 4, p45: 0, p65: 0 },
    ]),
  ]);

  const [fdt] = breakdown.cabinets;
  assert.equal(fdt.agents.length, 1);
  assert.equal(fdt.agents[0].resolved, false);
  // Falls back to the account label rather than inventing an agent.
  assert.equal(fdt.agents[0].agentName, 'r.unknown');
  assert.match(fdt.issues.join(' '), /غير مربوط بوكيل/);
  // Money still reconciles even when the mapping is incomplete.
  assert.equal(fdt.reconciled, true);
});

test('the same agent in two cabinets is never merged inside cabinet details', () => {
  const app = loadCurrentApp();
  const breakdown = withNewZone(app, [
    cabinet('FDT-108', [
      { parent: 'r.a', agentId: 'a', agentName: 'Agent A', fdt: 108, p35: 10, p45: 0, p65: 0 },
    ]),
    cabinet('FDT-110', [
      { parent: 'r.a', agentId: 'a', agentName: 'Agent A', fdt: 110, p35: 4, p45: 0, p65: 0 },
    ]),
  ]);

  assert.deepEqual(own(breakdown.cabinets.map((item) => item.name)), ['FDT-108', 'FDT-110']);
  assert.equal(breakdown.cabinets[0].agents[0].qty, 10);
  assert.equal(breakdown.cabinets[1].agents[0].qty, 4);
  assert.equal(breakdown.cabinets[0].agents[0].total, 10 * 1000);
  assert.equal(breakdown.cabinets[1].agents[0].total, 4 * 1000);

  // Only the secondary agent-centric view combines them.
  const totals = app.newZoneAgentTotals(breakdown);
  assert.equal(totals.length, 1);
  assert.equal(totals[0].qty, 14);
  assert.equal(totals[0].total, 14 * 1000);
  assert.deepEqual(own(totals[0].cabinets.map((item) => item.name)), ['FDT-108', 'FDT-110']);
});

test('a legacy cabinet without source detail refuses to invent an agent split', () => {
  const app = loadCurrentApp();
  app.state.tiers = TIERS;
  app.state.data = {
    old: [],
    new: [{ name: 'FDT-300', p35: 6, p45: 0, p65: 0, customTier: 'auto', paid: 0, owner: 'x' }],
  };

  const [fdt] = app.newZoneFdtBreakdown().cabinets;
  assert.equal(fdt.detailed, false);
  assert.equal(fdt.agents.length, 0);
  assert.equal(fdt.reconciled, false);
  assert.match(fdt.issues.join(' '), /أعد استيراد الملف الخام/);
});

test('quantities that do not reconcile surface as a validation error', () => {
  const app = loadCurrentApp();
  const rows = [
    cabinet('FDT-400', [
      { parent: 'r.a', agentId: 'a', agentName: 'Agent A', fdt: 400, p35: 5, p45: 0, p65: 0 },
    ]),
  ];
  // Corrupt the cabinet total so the agent rows no longer add up.
  rows[0].p35 = 9;

  const breakdown = withNewZone(app, rows);
  const [fdt] = breakdown.cabinets;
  assert.equal(fdt.reconciled, false);
  assert.match(fdt.issues.join(' '), /لا يساوي كمية الكابينة/);
  assert.equal(breakdown.reconciled, false);
});

test('one source account mapped to two agents is reported as a conflict', () => {
  const app = loadCurrentApp();
  const breakdown = withNewZone(app, [
    cabinet('FDT-500', [
      { parent: 'r.shared', agentId: 'a', agentName: 'Agent A', fdt: 500, p35: 2, p45: 0, p65: 0 },
    ]),
    cabinet('FDT-501', [
      { parent: 'r.shared', agentId: 'b', agentName: 'Agent B', fdt: 501, p35: 3, p45: 0, p65: 0 },
    ]),
  ]);

  assert.equal(breakdown.conflicts.length, 1);
  assert.equal(breakdown.conflicts[0].account, 'r.shared');
  assert.deepEqual(own(breakdown.conflicts[0].agentIds).sort(), ['a', 'b']);
  assert.equal(breakdown.reconciled, false);
});

test('the CSV export carries agent identity, source account, and cabinet reconciliation', () => {
  const app = loadCurrentApp();
  const breakdown = withNewZone(app, [
    cabinet('FDT-108', [
      { parent: 'r.a', agentId: 'a', agentName: 'Agent A', fdt: 108, p35: 10, p45: 0, p65: 0 },
      { parent: 'r.a.sub1', agentId: 'a', agentName: 'Agent A', fdt: 108, p35: 2, p45: 0, p65: 0 },
      { parent: 'r.b', agentId: 'b', agentName: 'Agent B', fdt: 108, p35: 3, p45: 0, p65: 0 },
    ]),
  ]);

  const rows = own(app.newZoneFdtAgentExportRows(breakdown));
  // One row per source account, so the audit trace survives export.
  assert.equal(rows.length, 3);
  assert.deepEqual(
    own(rows.map((row) => row.SourceAccount)).sort(),
    ['r.a', 'r.a.sub1', 'r.b'],
  );

  const first = rows.find((row) => row.SourceAccount === 'r.a');
  assert.equal(first.FDT, 'FDT-108');
  assert.equal(first.AgentName, 'Agent A');
  assert.equal(first.AgentID, 'a');
  assert.equal(first.Reconciled, 'YES');
  // Agent-level and cabinet-level context travel with every source row.
  assert.equal(first.AgentQuantity, 12);
  assert.equal(first.CabinetQuantity, 15);

  // Source shares still add up to the cabinet commission.
  const exported = rows.reduce((sum, row) => sum + row.CommissionShare, 0);
  assert.equal(exported, breakdown.cabinets[0].total);
});

test('the Excel report splits the new zone into cabinet, agent, and source sheets', () => {
  const app = loadCurrentApp();
  withNewZone(app, [
    cabinet('FDT-108', [
      { parent: 'r.a', agentId: 'a', agentName: 'Agent A', fdt: 108, p35: 10, p45: 0, p65: 0 },
      { parent: 'r.b', agentId: 'b', agentName: 'Agent B', fdt: 108, p35: 5, p45: 0, p65: 0 },
    ]),
  ]);

  const workbook = app.buildExcelReportWorkbook();
  assert.ok(own(workbook.SheetNames).includes('NEW FDT Summary'));
  assert.ok(own(workbook.SheetNames).includes('NEW FDT Agents'));
  assert.ok(own(workbook.SheetNames).includes('NEW FDT Sources'));

  assert.equal(workbook.Sheets['NEW FDT Summary'].A2.v, 'FDT-108');
  assert.equal(workbook.Sheets['NEW FDT Summary'].B2.v, 2);
  // Agents sheet shows the real agent name, never the raw parent account.
  assert.equal(workbook.Sheets['NEW FDT Agents'].B2.v, 'Agent A');
  assert.equal(workbook.Sheets['NEW FDT Agents'].C2.v, 'a');
  // Sources sheet keeps the parent account underneath its agent.
  assert.equal(workbook.Sheets['NEW FDT Sources'].D2.v, 'r.a');
});

test('the new-zone panel renders cabinet first, then its participating agents', () => {
  const app = loadCurrentApp();
  withNewZone(app, [
    cabinet('FDT-108', [
      { parent: 'r.saeed', agentId: 'saeed', agentName: 'Saeed Ammar', fdt: 108, p35: 20, p45: 5, p65: 5 },
      { parent: 'r.saeed.sub1', agentId: 'saeed', agentName: 'Saeed Ammar', fdt: 108, p35: 3, p45: 0, p65: 0 },
      { parent: 'r.ahmed', agentId: 'ahmed', agentName: 'Ahmed Abdulabbas', fdt: 108, p35: 10, p45: 10, p65: 5 },
    ]),
  ]);

  app.renderAgentHierarchy();
  const html = app.__elements.get('panel-hierarchy').innerHTML;

  // The cabinet is the entry point.
  assert.ok(html.indexOf('FDT-108') >= 0);
  // Real agent names are shown, and they appear after the cabinet heading.
  assert.ok(html.indexOf('Saeed Ammar') > html.indexOf('FDT-108'));
  assert.ok(html.indexOf('Ahmed Abdulabbas') > html.indexOf('FDT-108'));
  // Source accounts remain available underneath the agent.
  assert.ok(html.indexOf('r.saeed.sub1') > html.indexOf('Saeed Ammar'));
  // Both export actions are wired to the cabinet-first data.
  assert.ok(html.includes('exportNewZoneFdtAgents()'));
  assert.ok(html.includes('exportNewZoneAgentTotals()'));
  // No reconciliation warning for a clean cabinet.
  assert.ok(!html.includes('تعذر التحقق من تطابق'));
});

test('a reconciliation failure is surfaced in the panel instead of being hidden', () => {
  const app = loadCurrentApp();
  const rows = [
    cabinet('FDT-400', [
      { parent: 'r.a', agentId: 'a', agentName: 'Agent A', fdt: 400, p35: 5, p45: 0, p65: 0 },
    ]),
  ];
  rows[0].p35 = 9;
  withNewZone(app, rows);

  app.renderAgentHierarchy();
  const html = app.__elements.get('panel-hierarchy').innerHTML;
  assert.ok(html.includes('تعذر التحقق من تطابق'));
  assert.ok(html.includes('يحتاج مراجعة'));
});

test('an unmapped account is a mapping warning, not a reconciliation failure', () => {
  const app = loadCurrentApp();
  withNewZone(app, [
    cabinet('FDT-200', [
      { parent: 'r.unmapped', agentId: '', agentName: '', fdt: 200, p35: 6, p45: 0, p65: 0 },
    ]),
  ]);

  app.renderAgentHierarchy();
  const html = app.__elements.get('panel-hierarchy').innerHTML;

  // The figures do reconcile, so the danger notice must not appear.
  assert.ok(!html.includes('تعذر التحقق من تطابق'));
  assert.ok(!html.includes('لا تعتبر مطابقة'));
  // It is reported as an incomplete-mapping warning instead.
  assert.ok(html.includes('ربط الوكلاء غير مكتمل'));
  assert.ok(html.includes('صحيحة ومطابقة'));
});

test('a real reconciliation failure still raises the danger notice', () => {
  const app = loadCurrentApp();
  const rows = [
    cabinet('FDT-400', [
      { parent: 'r.a', agentId: 'a', agentName: 'Agent A', fdt: 400, p35: 5, p45: 0, p65: 0 },
    ]),
  ];
  rows[0].p35 = 9; // cabinet no longer matches its agents
  withNewZone(app, rows);

  app.renderAgentHierarchy();
  const html = app.__elements.get('panel-hierarchy').innerHTML;
  assert.ok(html.includes('تعذر التحقق من تطابق'));
  assert.ok(html.includes('لا تعتبر مطابقة'));
});
