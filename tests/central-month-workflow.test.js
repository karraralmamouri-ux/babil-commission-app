const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadCurrentApp } = require('./load-current-app');

const root = path.join(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
const migration = fs.readFileSync(path.join(root, 'supabase', 'migrations', '20260809190000_add_central_month_workflow.sql'), 'utf8');
const breakdownMigration = fs.readFileSync(path.join(root, 'supabase', 'migrations', '20260815113000_add_commission_source_breakdown.sql'), 'utf8');

test('central month workflow stores group identity and shared import settings', () => {
  assert.match(migration, /add column tier_group_id text/);
  assert.match(migration, /add column is_visible boolean not null default false/);
  assert.match(migration, /alter column is_visible set default true/);
  assert.match(migration, /add column source_account text/);
  assert.match(migration, /add column tier_basis_qty integer/);
  assert.match(migration, /create table public\.app_settings/);
  assert.match(migration, /create or replace function public\.publish_commission_month/);
  assert.match(migration, /create or replace function public\.save_import_settings/);
  assert.match(migration, /public\.current_app_role\(\) <> 'admin'/);
  assert.match(migration, /'commission\.month\.published'/);
  assert.match(migration, /Cannot remove a row with recorded payment/);
  assert.match(migration, /Applied tier does not match server calculation/);
  assert.match(migration, /Commission tiers t1, t2, and t3 are required/);
  assert.match(migration, /\(v_tier ->> 'p35'\)::numeric < 0/);
});

test('prepared rows freeze the server-verifiable applied tier and group basis', () => {
  const app = loadCurrentApp();
  app.state.data = {
    old: [
      { name: 'Main', p35: 100, p45: 0, p65: 0, customTier: 'auto', tierGroupId: 'g1', tierGroupName: 'Main', tierBasisQty: 201, sourceAccount: 'r.main', sourceBreakdown: [{ parent: 'r.main', fdt: 20, p35: 100, p45: 0, p65: 0 }], paid: 0 },
      { name: 'Main sub1', p35: 101, p45: 0, p65: 0, customTier: 'auto', tierGroupId: 'g1', tierGroupName: 'Main', tierBasisQty: 201, sourceAccount: 'r.main.sub1', sourceBreakdown: [{ parent: 'r.main.sub1', fdt: 21, p35: 101, p45: 0, p65: 0 }], paid: 0 },
    ],
    new: [],
  };

  const rows = app.rowsForCentralPublish();
  assert.equal(rows.length, 2);
  assert.equal(rows[0].tier_mode, 'auto');
  assert.equal(rows[0].applied_tier, 't2');
  assert.equal(rows[1].tier_basis_qty, 201);
  assert.equal(rows[1].source_account, 'r.main.sub1');
});

test('admin operations, manual month selection, language and Excel report are exposed', () => {
  assert.match(html, /if\(\['users','backup'\]\.includes\(p\)\)return roleAllows\(p\)/);
  assert.match(html, /centralPreview\.active&&!\['payment','users','backup'\]\.includes\(permission\)/);
  assert.match(html, /function publishCurrentMonth\(\)/);
  assert.match(html, /function exportExcelReport\(\)/);
  assert.match(html, /function toggleLanguage\(\)/);
  assert.match(html, /if\(centralPreview\.active\)\{const snapshot=state\.archive\[key\]/);
  assert.match(html, /function prepareSelectedCentralMonth\(\)/);
  assert.match(html, /archive:\{\.\.\.clone\(localArchive\),\.\.\.clone\(centralArchive\)\}/);
  assert.match(html, /if\(centralPreview\.active\)\{prepareSelectedCentralMonth\(\);return\}/);
  assert.match(html, /const defaultData=\{old:\[\],new:\[\]\}/);
  assert.match(html, /commission_months\?is_visible=eq\.true&status=eq\.approved/);
  assert.doesNotMatch(html, /\{name:'حيدر طالب',p35:/);
});

test('workspace exposes safe loading, empty, filtering, and mobile navigation states', () => {
  assert.match(html, /id="loadingState"/);
  assert.match(html, /id="emptyState"/);
  assert.match(html, /function renderWorkspaceState\(\)/);
  assert.match(html, /function scheduleFilterRender\(\)/);
  assert.match(html, /id="filterSummary"/);
  assert.match(html, /function toggleMobileMenu\(force\)/);
  assert.match(html, /@media\(max-width:820px\)/);
  assert.match(html, /id="readinessInsights"/);
  assert.match(html, /id="operationalAlerts"/);
});

test('Excel report contains auditable formulas, comparison, and settings sheets', () => {
  const app = loadCurrentApp();
  app.state.data = { old: [{ name: 'Agent', p35: 2, p45: 1, p65: 0, customTier: 't1', paid: 1000 }], new: [{ name: 'FDT-94', owner: 'Saeed', p35: 3, p45: 0, p65: 0, customTier: 't1', paid: 0 }] };
  const workbook = app.buildExcelReportWorkbook();

  assert.deepEqual(JSON.parse(JSON.stringify(workbook.SheetNames)), ['Summary', 'Commissions', 'Agent Hierarchy', 'New Zone Agents', 'Comparison', 'Settings']);
  assert.match(workbook.Sheets.Commissions.I2.f, /VLOOKUP/);
  assert.equal(workbook.Sheets.Commissions.K2.f, 'MAX(0,I2-J2)');
  assert.equal(workbook.Sheets.Summary.B5.f, 'SUM(Commissions!I2:I3)');
  assert.match(workbook.Sheets['New Zone Agents'].H2.f, /SUMIFS\(Commissions!/);
  assert.equal(workbook.Sheets['Agent Hierarchy'].B2.v, 'Agent');
});

test('agent hierarchy keeps the principal above FDTs and each FDT above its parents', () => {
  const app = loadCurrentApp();
  app.state.data = {
    old: [
      { name: 'Saeed Ammar', owner: 'Saeed Ammar', sourceAccount: 'r.saeed.ammar', sourceBreakdown: [{ parent: 'r.saeed.ammar', fdt: 99, p35: 2, p45: 0, p65: 0 }], p35: 2, p45: 0, p65: 0, customTier: 't1', paid: 0 },
      { name: 'Saeed Ammar sub1', owner: 'Saeed Ammar', sourceAccount: 'r.saeed.ammar.sub1', sourceBreakdown: [{ parent: 'r.saeed.ammar.sub1', fdt: 100, p35: 3, p45: 0, p65: 0 }], p35: 3, p45: 0, p65: 0, customTier: 't1', paid: 0 },
    ],
    new: [{ name: 'FDT-94', owner: 'Saeed Ammar', sourceBreakdown: [{ parent: 'r.saeed.ammar.sub1', fdt: 94, p35: 4, p45: 0, p65: 0 }], p35: 4, p45: 0, p65: 0, customTier: 't1', paid: 0 }],
  };

  const hierarchy = app.agentHierarchySummaries();
  assert.equal(hierarchy.length, 1);
  assert.equal(hierarchy[0].owner, 'Saeed Ammar');
  assert.deepEqual(JSON.parse(JSON.stringify(hierarchy[0].parents.map((parent) => parent.name))), ['r.saeed.ammar', 'r.saeed.ammar.sub1']);
  assert.deepEqual(JSON.parse(JSON.stringify(hierarchy[0].parents[1].details.map((detail) => detail.label))), ['FDT-94', 'FDT-100']);
  assert.deepEqual(JSON.parse(JSON.stringify(hierarchy[0].fdts.map((fdt) => fdt.label))), ['FDT-94', 'FDT-99', 'FDT-100']);
  assert.equal(hierarchy[0].fdts[0].parents[0].name, 'r.saeed.ammar.sub1');
  assert.equal(hierarchy[0].qty, 9);
  assert.equal(hierarchy[0].total, hierarchy[0].fdts.reduce((sum, fdt) => sum + fdt.total, 0));
  assert.equal(hierarchy[0].total, hierarchy[0].parents.reduce((sum, parent) => sum + parent.total, 0));
});

test('source parent and FDT allocation is stored centrally and reconciled before publishing', () => {
  assert.match(breakdownMigration, /add column if not exists source_breakdown jsonb/);
  assert.match(breakdownMigration, /jsonb_typeof\(source_breakdown\) = 'array'/);
  assert.match(breakdownMigration, /Source breakdown does not reconcile/);
  assert.match(breakdownMigration, /source_breakdown = excluded\.source_breakdown/);
  assert.match(breakdownMigration, /source_breakdown is required for a non-empty row/);
  assert.match(breakdownMigration, /before insert or update of p35, p45, p65, source_breakdown/);
  assert.match(html, /الكمية مرتبطة بتفاصيل الملف الخام؛ أعد رفع الملف لتعديلها/);
});

test('publishing refuses positive quantities without parent and FDT allocation', () => {
  const app = loadCurrentApp();
  app.state.data = { old: [{ name: 'Manual', p35: 1, p45: 0, p65: 0, customTier: 't1', paid: 0 }], new: [] };
  assert.throws(() => app.rowsForCentralPublish(), /تفاصيل parent وFDT مفقودة/);
});

test('new-zone agent summary totals final cabinet calculations without changing cabinet tiers', () => {
  const app = loadCurrentApp();
  app.state.data = {
    old: [],
    new: [
      { name: 'FDT-94', owner: 'Saeed Ammar', p35: 100, p45: 0, p65: 0, customTier: 'auto', paid: 1000 },
      { name: 'FDT-95', owner: 'Saeed Ammar', p35: 0, p45: 250, p65: 0, customTier: 'auto', paid: 2000 },
      { name: 'FDT-103', owner: 'Ahmed', p35: 0, p45: 0, p65: 10, customTier: 'auto', paid: 0 },
    ],
  };

  const summaries = app.newZoneOwnerSummaries();
  const saeed = summaries.find((item) => item.owner === 'Saeed Ammar');
  assert.deepEqual(JSON.parse(JSON.stringify(saeed.cabinets)), ['FDT-94', 'FDT-95']);
  assert.equal(saeed.qty, 350);
  assert.equal(saeed.total, app.calc(app.state.data.new[0]).total + app.calc(app.state.data.new[1]).total);
  assert.equal(saeed.paid, 3000);
});
