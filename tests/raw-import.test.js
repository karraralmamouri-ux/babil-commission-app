const test = require('node:test');
const assert = require('node:assert/strict');
const { loadCurrentApp } = require('./load-current-app');

function config() {
  return {
    profiles: ['P-35000', 'P-45000', 'P-65000'],
    agents: [
      { id: 'main', name: 'Main agent', accounts: ['r.main', 'r.main.sub1'] },
      { id: 'other', name: 'Other agent', accounts: ['r.other'], defaultTier: 't1' },
    ],
    cabinetRanges: [{ id: 'range', from: 94, to: 95, ownerId: 'main' }],
  };
}

test('raw import counts unique ids and pools main and sub parent accounts in old zone', () => {
  const app = loadCurrentApp();
  const result = app.calculateRawImport([
    { id: 1, parent: 'r.main', profile_name: 'p35000', lastname: 'FDT:20 FAT:1 PORT:1' },
    { id: 2, parent: 'r.main.sub1', profile_name: 'P-45000', lastname: 'FDT:21 FAT:1 PORT:1' },
    { id: 2, parent: 'r.main.sub1', profile_name: 'P-45000', lastname: 'FDT:21 FAT:1 PORT:1' },
    { id: 3, parent: 'r.main', profile_name: 'P-25000', lastname: 'FDT:20 FAT:1 PORT:2' },
  ], config());

  assert.equal(result.old.length, 1);
  assert.deepEqual(JSON.parse(JSON.stringify(result.old[0])), { name: 'Main agent', p35: 1, p45: 1, p65: 0, customTier: 'auto', paid: 0 });
  assert.equal(result.stats.duplicateIds, 1);
  assert.equal(result.stats.ignoredProfiles, 1);
});

test('new-zone cabinet ownership overrides parent and calculates each FDT separately', () => {
  const app = loadCurrentApp();
  const result = app.calculateRawImport([
    { id: 10, parent: 'r.unknown', profile_name: 'P-35000', lastname: 'FDT:94 FAT:1 PORT:1' },
    { id: 11, parent: 'r.other', profile_name: 'P-65000', lastname: 'FDT:95 FAT:1 PORT:1' },
  ], config());

  assert.equal(result.old.length, 0);
  assert.deepEqual(JSON.parse(JSON.stringify(result.new.map((row) => [row.name, row.p35, row.p65]))), [
    ['FDT-94', 1, 0],
    ['FDT-95', 0, 1],
  ]);
});

test('applying raw results preserves existing manual tier and payment fields', () => {
  const app = loadCurrentApp();
  app.state.data = {
    old: [{ name: 'Main agent', p35: 9, p45: 0, p65: 0, customTier: 't3', paid: 5000, paymentDate: '2026-07-31' }],
    new: [],
  };
  app.applyRawImportResult({
    old: [{ name: 'Main agent', p35: 1, p45: 1, p65: 0, customTier: 'auto', paid: 0 }],
    new: [],
  });

  assert.equal(app.state.data.old[0].customTier, 't3');
  assert.equal(app.state.data.old[0].paid, 5000);
  assert.equal(app.state.data.old[0].paymentDate, '2026-07-31');
});
