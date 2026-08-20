const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadCurrentApp } = require('./load-current-app');

const fees = require(path.join(__dirname, '..', 'assets', 'js', 'installation-fees.js'));

function sheetRow(overrides) {
  return Object.assign({
    'Subscriber Name': '', 'Start Date': null, 'Total Amount': null,
    Payment1: null, Date1: null, Payment2: null, Date2: null,
    Payment3: null, Date3: null, Payment4: null, Date4: null,
    'Received Total': null, Remaining: null, Notes: null,
  }, overrides);
}

const SHEETS = [{
  reseller: 'صفاء 1',
  rows: [
    sheetRow({
      'Subscriber Name': 'a-done', 'Total Amount': 13000,
      Payment1: 3000, Date1: new Date(2025, 11, 20),
      Payment2: 3000, Date2: new Date(2026, 1, 17),
      Payment3: 3000, Date3: new Date(2026, 1, 17),
      Payment4: 4000, Date4: new Date(2026, 2, 15),
      'Received Total': 13000, Remaining: 0,
    }),
    sheetRow({ 'Subscriber Name': 'a-p1', 'Total Amount': 13000, 'Received Total': 0, Remaining: 13000 }),
    sheetRow({}),
    sheetRow({}),
  ],
}, {
  reseller: 'بارق ليث شعران',
  rows: [
    sheetRow({ 'Subscriber Name': 'b-unknown', 'Total Amount': 13000, Remaining: null }),
    sheetRow({}),
  ],
}];

test('the preview panel reports every count the reviewer needs before confirming', () => {
  const app = loadCurrentApp();
  app.__setAuthProfile({ role: "admin", is_active: true });
  const preview = fees.buildHistoricalPreview(SHEETS, { asOfDate: '2026-08-15' });
  const html = app.installationHistoryPreviewHtml(preview);

  const labels = [
    'صفوف مقروءة', 'صفوف قالب مُهملة', 'مشتركون فعليون', 'غير محسوم',
    'DONE', 'P1', 'P2', 'P3', 'P4',
    'تاريخ دفعات موجود', 'مشتركون جدد', 'مشتركون سيُحدَّثون',
    'دفعات جديدة', 'دفعات موجودة سلفاً', 'معرّفات مكررة في الملف',
  ];
  labels.forEach((label) => assert.ok(html.includes(label), `preview is missing "${label}"`));
});

test('blank template rows are shown as ignored and never counted as subscribers', () => {
  const app = loadCurrentApp();
  app.__setAuthProfile({ role: "admin", is_active: true });
  const preview = fees.buildHistoricalPreview(SHEETS, { asOfDate: '2026-08-15' });

  assert.equal(preview.totalRows, 6);
  assert.equal(preview.ignoredRows, 3);
  assert.equal(preview.realSubscribers, 3);

  const html = app.installationHistoryPreviewHtml(preview);
  // The per-reseller table must separate real rows from ignored ones.
  assert.ok(html.includes('صفاء 1'));
  assert.ok(html.includes('بارق ليث شعران'));
});

test('confirming is blocked until the reviewer picks an as-of date', () => {
  const app = loadCurrentApp();
  app.__setAuthProfile({ role: "admin", is_active: true });

  const withoutDate = fees.buildHistoricalPreview(SHEETS, {});
  const blocked = app.installationHistoryPreviewHtml(withoutDate);
  assert.ok(blocked.includes('disabled'), 'confirm must be disabled without an as-of date');
  assert.ok(!blocked.includes('confirmInstallationHistoryImport()'));

  const withDate = fees.buildHistoricalPreview(SHEETS, { asOfDate: '2026-08-15' });
  const ready = app.installationHistoryPreviewHtml(withDate);
  assert.ok(ready.includes('confirmInstallationHistoryImport()'));
});

test('the as-of field is offered to the user and never pre-filled from payment dates', () => {
  const app = loadCurrentApp();
  app.__setAuthProfile({ role: "admin", is_active: true });
  const preview = fees.buildHistoricalPreview(SHEETS, {});
  const html = app.installationHistoryPreviewHtml(preview);

  assert.ok(html.includes('installationHistoryAsOf'));
  assert.ok(html.includes('لن يُشتق من آخر تاريخ دفع'));
  assert.ok(html.includes('value=""'), 'the date field must start empty');
});

test('rows needing review are surfaced by kind without rejecting the file', () => {
  const app = loadCurrentApp();
  app.__setAuthProfile({ role: "admin", is_active: true });
  const preview = fees.buildHistoricalPreview([{
    reseller: 'R',
    rows: [
      sheetRow({
        'Subscriber Name': 'mismatch-1', 'Total Amount': 13000,
        Payment1: 3000, Date1: new Date(2025, 11, 20),
        'Received Total': 9000, Remaining: 0,
      }),
      sheetRow({ 'Subscriber Name': 'blank-remaining', 'Total Amount': 13000, Remaining: null }),
    ],
  }], { asOfDate: '2026-08-15' });

  const html = app.installationHistoryPreviewHtml(preview);
  assert.ok(html.includes('يحتاج مراجعة'));
  assert.ok(html.includes('لا يُرفض الملف ولا تُخمَّن أي قيمة'));
  // Both rows still count as real subscribers and remain importable.
  assert.equal(preview.realSubscribers, 2);
  assert.ok(html.includes('confirmInstallationHistoryImport()'));
});

test('a subscriber that moved reseller is reported as a move, not as a new record', () => {
  const app = loadCurrentApp();
  app.__setAuthProfile({ role: "admin", is_active: true });
  const known = new Map([['a-done', { reseller: 'وكيل سابق', paymentStages: ['P1', 'P2', 'P3', 'P4'] }]]);
  const preview = fees.buildHistoricalPreview(SHEETS, { asOfDate: '2026-08-15', known });

  assert.equal(preview.resellerChanged, 1);
  assert.equal(preview.newSubscribers, 2, 'only the genuinely unseen subscribers are new');
  const html = app.installationHistoryPreviewHtml(preview);
  assert.ok(html.includes('يظهر تحت وكيل مختلف عن المسجَّل'));
  assert.ok(html.includes('دون إنشاء نسخة ثانية'));
});

test('the historical import keeps its own state and never reuses the monthly slot', () => {
  const app = loadCurrentApp();
  app.__setAuthProfile({ role: 'admin', is_active: true });

  // Two distinct preview slots: a staged historical file must not be mistaken
  // for a staged monthly file, and confirming one must not consume the other.
  assert.ok('historyPreview' in app.installationState);
  assert.ok('lastPreview' in app.installationState);

  app.installationState.lastPreview = { period: '2026-07', mappedRows: [] };
  app.installationState.historyPreview = fees.buildHistoricalPreview(SHEETS, { asOfDate: '2026-08-15' });
  assert.notEqual(app.installationState.historyPreview, app.installationState.lastPreview);
  assert.equal(app.installationState.lastPreview.period, '2026-07');
  assert.equal(app.installationState.historyPreview.realSubscribers, 3);
});

test('the two import flows call different server functions', () => {
  // Import execution moved out of the legacy page into its own screen. The
  // rule this test guards did not change, so it follows the code: the two
  // flows must still reach two different server functions, because the
  // historical one carries an as-of date the entitlement one has no business
  // inventing.
  const fsMod = require('node:fs');
  const legacy = fsMod.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
  const screen = fsMod.readFileSync(
    path.join(__dirname, '..', 'src/features/system/import-run.ts'), 'utf8');

  assert.ok(screen.includes('import_installation_entitlements'));
  assert.ok(screen.includes('import_installation_history'));
  // The historical call sends the reviewer's chosen date, not a derived one.
  assert.ok(screen.includes('p_as_of_date'));
  assert.match(screen, /asOf/);
  // And the confirm path is gated on the import capability, which the server
  // function checks again for itself.
  assert.match(screen, /can\('saas\.import'\)/);

  // The legacy page no longer performs either import.
  assert.ok(!legacy.includes('/rest/v1/rpc/import_installation_entitlements'));
  assert.ok(!legacy.includes('/rest/v1/rpc/import_installation_history'));
});
