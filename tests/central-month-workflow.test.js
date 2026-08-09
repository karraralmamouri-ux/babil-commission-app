const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadCurrentApp } = require('./load-current-app');

const root = path.join(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
const migration = fs.readFileSync(path.join(root, 'supabase', 'migrations', '20260809190000_add_central_month_workflow.sql'), 'utf8');

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
      { name: 'Main', p35: 100, p45: 0, p65: 0, customTier: 'auto', tierGroupId: 'g1', tierGroupName: 'Main', tierBasisQty: 201, sourceAccount: 'r.main', paid: 0 },
      { name: 'Main sub1', p35: 101, p45: 0, p65: 0, customTier: 'auto', tierGroupId: 'g1', tierGroupName: 'Main', tierBasisQty: 201, sourceAccount: 'r.main.sub1', paid: 0 },
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

test('Excel report contains auditable formulas, comparison, and settings sheets', () => {
  const app = loadCurrentApp();
  app.state.data = { old: [{ name: 'Agent', p35: 2, p45: 1, p65: 0, customTier: 't1', paid: 1000 }], new: [] };
  const workbook = app.buildExcelReportWorkbook();

  assert.deepEqual(JSON.parse(JSON.stringify(workbook.SheetNames)), ['Summary', 'Commissions', 'Comparison', 'Settings']);
  assert.match(workbook.Sheets.Commissions.I2.f, /VLOOKUP/);
  assert.equal(workbook.Sheets.Commissions.K2.f, 'MAX(0,I2-J2)');
  assert.equal(workbook.Sheets.Summary.B5.f, 'SUM(Commissions!I2:I2)');
});
