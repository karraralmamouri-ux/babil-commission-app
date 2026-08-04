const test = require('node:test');
const assert = require('node:assert/strict');

const { loadCurrentApp } = require('./load-current-app');

test('backup permission is restricted to the admin role', () => {
  const { ROLE_PERMISSIONS } = loadCurrentApp();

  assert.equal(ROLE_PERMISSIONS.admin.backup, true);
  assert.equal(ROLE_PERMISSIONS.accountant.backup, false);
  assert.equal(ROLE_PERMISSIONS.monitor.backup, false);
  assert.equal(ROLE_PERMISSIONS.viewer.backup, false);
});

test('backup state snapshot is a deep copy of operational data', () => {
  const { backupStateSnapshot } = loadCurrentApp();
  const source = {
    month: '08/2026',
    data: { old: [{ name: 'وكيل' }], new: [] },
    tiers: [{ min: 1, rate: 2 }],
    archive: { '07/2026': { old: [], new: [] } },
    auditLog: [{ action: 'تعديل' }],
    session: { access_token: 'must-not-be-exported' },
  };

  const snapshot = backupStateSnapshot(source);
  source.data.old[0].name = 'تم التغيير';

  assert.equal(snapshot.data.old[0].name, 'وكيل');
  assert.equal(Object.hasOwn(snapshot, 'session'), false);
  assert.deepEqual(Object.keys(snapshot), ['month', 'data', 'tiers', 'archive', 'auditLog']);
});

test('versioned backup has a valid state checksum and excludes auth secrets', async () => {
  const { createBackupDocument, verifyBackupDocument } = loadCurrentApp();
  const source = {
    month: '08/2026',
    data: { old: [], new: [] },
    tiers: [],
    archive: {},
    auditLog: [],
    hrins_supabase_session: {
      access_token: 'secret-access',
      refresh_token: 'secret-refresh',
    },
  };

  const backup = await createBackupDocument(source, '2026-08-04T10:00:00.000Z', 'admin@example.com');
  const serialized = JSON.stringify(backup);

  assert.equal(backup.format, 'babil-commission-backup');
  assert.equal(backup.version, 1);
  assert.equal(backup.exportedBy, 'admin@example.com');
  assert.match(backup.integrity.value, /^[a-f0-9]{64}$/);
  assert.equal(serialized.includes('hrins_supabase_session'), false);
  assert.equal(serialized.includes('secret-access'), false);
  assert.equal(serialized.includes('secret-refresh'), false);
  assert.equal(await verifyBackupDocument(backup), true);

  backup.state.month = '09/2026';
  assert.equal(await verifyBackupDocument(backup), false);
});
