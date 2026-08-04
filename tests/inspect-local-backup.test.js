const test = require('node:test');
const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');

function checksum(state) {
  return createHash('sha256').update(JSON.stringify(state), 'utf8').digest('hex');
}

function fixture() {
  const tiers = [
    { key: 't1', min: 0, max: 200, p35: 4000, p45: 5500, p65: 8000 },
    { key: 't2', min: 201, max: 400, p35: 4750, p45: 6000, p65: 9000 },
    { key: 't3', min: 401, max: null, p35: 6000, p45: 8000, p65: 11500 },
  ];
  const state = {
    month: '08/2026',
    data: {
      old: [{ name: 'A', p35: 1, p45: 0, p65: 0, customTier: 'auto', paid: 1000 }],
      new: [{ name: 'B', p35: 201, p45: 0, p65: 0, customTier: 'auto', paid: 0 }],
    },
    tiers,
    archive: {
      '07/2026': {
        data: { old: [], new: [] },
        tiers,
      },
    },
    auditLog: [{ action: 'test' }],
  };
  return {
    format: 'babil-commission-backup',
    version: 1,
    exportedAt: '2026-08-04T00:00:00.000Z',
    integrity: { algorithm: 'SHA-256', scope: 'state', value: checksum(state) },
    state,
  };
}

test('backup inspection verifies checksum and reconciles financial totals', async () => {
  const { inspectBackupDocument } = await import('../scripts/inspect-local-backup.mjs');
  const report = inspectBackupDocument(fixture());

  assert.equal(report.valid, true);
  assert.equal(report.checksum.matches, true);
  assert.equal(report.auditEvents, 1);
  assert.equal(report.current.agents, 2);
  assert.deepEqual(report.current.zones, { old: 1, new: 1 });
  assert.equal(report.current.quantity.total, 202);
  assert.equal(report.current.due, 4000 + 201 * 4750);
  assert.equal(report.current.paid, 1000);
  assert.equal(report.archived.length, 1);
});

test('backup inspection rejects tampering and unsafe financial values', async () => {
  const { inspectBackupDocument } = await import('../scripts/inspect-local-backup.mjs');
  const document = fixture();
  document.state.data.old[0].paid = 999999;
  document.state.data.old.push({
    name: 'A',
    p35: -1,
    p45: 0,
    p65: 0,
    customTier: 'unknown',
    paid: 0,
  });

  const report = inspectBackupDocument(document);
  assert.equal(report.valid, false);
  assert.equal(report.checksum.matches, false);
  assert.ok(report.errors.some((error) => error.includes('duplicated')));
  assert.ok(report.errors.some((error) => error.includes('cannot') || error.includes('non-negative')));
  assert.ok(report.errors.some((error) => error.includes('exceeds amount due')));
  assert.ok(report.errors.some((error) => error.includes('customTier is invalid')));
});
