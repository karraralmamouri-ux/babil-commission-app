const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadCurrentApp } = require('./load-current-app');

const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');

function sampleSnapshot() {
  return {
    data: {
      old: [{ name: 'Agent', p35: 2, p45: 1, p65: 0, customTier: 't1', paid: 1000 }],
      new: [],
    },
    tiers: [
      { key: 't1', label: 'T1', min: 1, max: 200, p35: 4000, p45: 5500, p65: 8000 },
      { key: 't2', label: 'T2', min: 201, max: 400, p35: 4750, p45: 6000, p65: 9000 },
      { key: 't3', label: 'T3', min: 401, max: null, p35: 6000, p45: 8000, p65: 11500 },
    ],
    savedAt: '2026-08-09T12:00:00.000Z',
  };
}

test('admin archive manager exposes selected-period view, edit, export, and import', () => {
  assert.match(html, /function openArchiveManager\(\)/);
  assert.match(html, /function openSelectedArchivePeriod\(forEdit=false\)/);
  assert.match(html, /function exportSelectedPeriodArchive\(\)/);
  assert.match(html, /function importSelectedPeriodArchive\(event\)/);
  assert.match(html, /الملف يخص \$\{document\.month\} بينما الفترة المختارة هي \$\{target\}/);
  assert.match(html, /لن تتغير البيانات المركزية قبل اعتماد الشهر/);
});

test('a selected period archive is signed and rejects tampering', async () => {
  const app = loadCurrentApp();
  const document = await app.createPeriodArchiveDocument('07/2026', sampleSnapshot(), '2026-08-09T13:00:00.000Z');

  assert.equal(document.format, 'babil-commission-period');
  assert.equal(document.month, '07/2026');
  assert.equal(await app.verifyPeriodArchiveDocument(document), true);

  document.snapshot.data.old[0].p35 = 999;
  assert.equal(await app.verifyPeriodArchiveDocument(document), false);
});

test('period validation rejects overpayment and central payment fields survive import', () => {
  const app = loadCurrentApp();
  const invalid = sampleSnapshot();
  invalid.data.old[0].paid = 999999;
  assert.throws(() => app.validatePeriodArchiveSnapshot(invalid, '07/2026'), /المدفوع يتجاوز المستحق/);

  const imported = sampleSnapshot();
  imported.data.old[0].paid = 0;
  const existing = { data: { old: [{ name: 'Agent', paid: 7000, paymentDate: '2026-07-31', centralId: 'row-1', centralUpdatedAt: 'v1' }], new: [] } };
  const merged = app.preserveExistingCentralPayments(imported, existing);
  assert.equal(merged.data.old[0].paid, 7000);
  assert.equal(merged.data.old[0].centralId, 'row-1');
});
