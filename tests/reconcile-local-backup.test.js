const test = require('node:test');
const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');

function checksum(state) {
  return createHash('sha256').update(JSON.stringify(state), 'utf8').digest('hex');
}

function tiers() {
  return [
    { key: 't1', label: 'T1', min: 0, max: 200, p35: 4000, p45: 5500, p65: 8000 },
    { key: 't2', label: 'T2', min: 201, max: 400, p35: 4750, p45: 6000, p65: 9000 },
    { key: 't3', label: 'T3', min: 401, max: null, p35: 6000, p45: 8000, p65: 11500 },
  ];
}

function localDocument(month = '08/2026') {
  const state = {
    month,
    data: {
      old: [{ name: 'Private A', p35: 10, p45: 1, p65: 0, customTier: 'auto', paid: 1000 }],
      new: [{ name: 'FDT-1', p35: 2, p45: 0, p65: 0, customTier: 't1', paid: 0 }],
    },
    tiers: tiers(),
    archive: {},
    auditLog: [],
  };
  return {
    format: 'babil-commission-backup',
    version: 1,
    exportedAt: '2026-08-05T00:00:00.000Z',
    integrity: { algorithm: 'SHA-256', scope: 'state', value: checksum(state) },
    state,
  };
}

function central(month = '08/2026') {
  const months = [{ id: 'month-1', month_key: month, tiers: tiers() }];
  const rows = [
    { month_id: 'month-1', zone: 'old', name: 'Private A', p35: 10, p45: 1, p65: 0, custom_tier: 'auto', paid: 1000, payment_date: null },
    { month_id: 'month-1', zone: 'new', name: 'FDT-1', p35: 2, p45: 0, p65: 0, custom_tier: 't1', paid: 0, payment_date: null },
  ];
  return { months, rows };
}

test('reconciliation confirms an exact same-month match without exposing identities', async () => {
  const { reconcileBackupWithCentralExport } = await import('../scripts/reconcile-local-backup.mjs');
  const document = localDocument();
  const { months, rows } = central();
  const report = reconcileBackupWithCentralExport(document, months, rows);
  const serialized = JSON.stringify(report);

  assert.equal(report.valid, true);
  assert.equal(report.readOnly, true);
  assert.equal(report.sameMonthReconciled, true);
  assert.equal(report.everyLocalContentExistsCentrally, true);
  assert.equal(report.safeToAutoImport, false);
  assert.equal(report.sameMonthComparisons[0].exactMatch, true);
  assert.equal(report.localSummaries[0].agents, 2);
  assert.equal(report.centralSummaries[0].agents, 2);
  assert.equal(serialized.includes('Private A'), false);
  assert.equal(serialized.includes('FDT-1'), false);
});

test('reconciliation detects equivalent content stored under a different month', async () => {
  const { reconcileBackupWithCentralExport } = await import('../scripts/reconcile-local-backup.mjs');
  const document = localDocument('08/2026');
  const { months, rows } = central('09/2026');
  const report = reconcileBackupWithCentralExport(document, months, rows);

  assert.equal(report.valid, true);
  assert.equal(report.sameMonthReconciled, false);
  assert.deepEqual(report.localOnlyMonths, ['08/2026']);
  assert.deepEqual(report.centralOnlyMonths, ['09/2026']);
  assert.equal(report.everyLocalContentExistsCentrally, true);
  assert.deepEqual(report.contentEquivalentAcrossMonths, [
    { localMonth: '08/2026', centralMonths: ['09/2026'] },
  ]);
  assert.equal(report.closestCentralComparisons[0].exactMatch, true);
});

test('reconciliation reports changed rows using counts only', async () => {
  const { reconcileBackupWithCentralExport } = await import('../scripts/reconcile-local-backup.mjs');
  const document = localDocument();
  const { months, rows } = central();
  rows[0].p35 = 11;
  const report = reconcileBackupWithCentralExport(document, months, rows);

  assert.equal(report.valid, true);
  assert.equal(report.sameMonthReconciled, false);
  assert.equal(report.sameMonthComparisons[0].rows.changed, 1);
  assert.equal(report.sameMonthComparisons[0].rows.onlyLocal, 0);
  assert.equal(report.sameMonthComparisons[0].rows.onlyCentral, 0);
  assert.deepEqual(report.sameMonthComparisons[0].fieldDifferences.p35, {
    rows: 1,
    localMinusCentral: -1,
  });
  assert.equal(report.everyLocalContentExistsCentrally, false);
});

test('reconciliation identifies duplicate central periods without exposing rows', async () => {
  const { reconcileBackupWithCentralExport } = await import('../scripts/reconcile-local-backup.mjs');
  const document = localDocument('08/2026');
  const first = central('07/2026');
  const months = [first.months[0], { ...first.months[0], id: 'month-2', month_key: '09/2026' }];
  const rows = [
    ...first.rows,
    ...first.rows.map((row) => ({ ...row, month_id: 'month-2' })),
  ];
  const report = reconcileBackupWithCentralExport(document, months, rows);

  assert.deepEqual(report.duplicateCentralContent, [['07/2026', '09/2026']]);
});

test('reconciliation rejects unsafe values in the central export', async () => {
  const { reconcileBackupWithCentralExport } = await import('../scripts/reconcile-local-backup.mjs');
  const document = localDocument();
  const { months, rows } = central();
  rows[0].paid = -1;
  const report = reconcileBackupWithCentralExport(document, months, rows);

  assert.equal(report.valid, false);
  assert.ok(report.errors.some((error) => error.includes('non-negative')));
});
