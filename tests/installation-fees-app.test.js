const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadCurrentApp } = require('./load-current-app');

const fees = require(path.join(__dirname, '..', 'assets', 'js', 'installation-fees.js'));
const own = (value) => Array.from(value);

function entitlement(overrides) {
  return Object.assign(
    {
      id: `ent-${Math.random().toString(16).slice(2)}`,
      period: '2026-07',
      subscriber_id: 'SUB-1',
      subscriber_name: 'Subscriber One',
      reseller: 'Saeed Ammar',
      zone: 'new',
      fdt: '108',
      remaining: 13000,
      stage: 'P1',
      amount: 3000,
      invoice_status: 'pending',
      invoice_audited_at: null,
      payment_status: 'awaiting_invoice',
      paid_amount: 0,
      paid_at: null,
      updated_at: '2026-08-15T10:00:00Z',
    },
    overrides,
  );
}

// ------------------------------------------------------------------ import --
test('the import preview classifies every row before anything is written', () => {
  const preview = fees.buildImportPreview(
    [
      { 'Subscriber ID': 'S1', Reseller: 'R', Remaining: '13,000', Zone: 'new' },
      { 'Subscriber ID': 'S2', Reseller: 'R', Remaining: 10000 },
      { 'Subscriber ID': 'S3', Reseller: 'R', Remaining: 7000 },
      { 'Subscriber ID': 'S4', Reseller: 'R', Remaining: 4000 },
      { 'Subscriber ID': 'S5', Reseller: 'R', Remaining: 0 },
      { 'Subscriber ID': 'S1', Reseller: 'R', Remaining: 13000 },
      { 'Subscriber ID': '', Reseller: 'R', Remaining: 13000 },
      { 'Subscriber ID': 'S7', Reseller: '', Remaining: 13000 },
      { 'Subscriber ID': 'S8', Reseller: 'R', Remaining: 5500 },
    ],
    { period: '2026-07', existingKeys: [] },
  );

  assert.equal(preview.totalRows, 9);
  assert.equal(preview.valid, 5);
  assert.equal(preview.invalid, 3);
  assert.equal(preview.duplicatesInFile, 1);
  assert.equal(preview.reasons.unknownRemaining, 1);
  assert.equal(preview.reasons.missingSubscriber, 1);
  assert.equal(preview.reasons.missingReseller, 1);
  assert.deepEqual(preview.stages, { P1: 1, P2: 1, P3: 1, P4: 1, DONE: 1 });
  // 3000 + 3000 + 3000 + 4000, DONE adds nothing.
  assert.equal(preview.amount, 13000);
  assert.equal(preview.importable, true);
});

test('Arabic and English headers map to the same fields', () => {
  const english = fees.mapImportRow({ 'Subscriber ID': 'S1', Reseller: 'R', Remaining: 7000, Zone: 'new', FDT: '108' });
  const arabic = fees.mapImportRow({ 'معرّف المشترك': 'S1', 'الوكيل': 'R', 'المتبقي': 7000, 'المنطقة': 'new', 'الكابينة': '108' });
  assert.deepEqual(english, arabic);
  assert.equal(fees.resolveInstallationStage(english.remaining).stage, 'P3');
});

test('re-importing the same file creates no new entitlement', () => {
  const rows = [
    { 'Subscriber ID': 'S1', Reseller: 'R', Remaining: 13000 },
    { 'Subscriber ID': 'S2', Reseller: 'R', Remaining: 4000 },
  ];
  const first = fees.buildImportPreview(rows, { period: '2026-07', existingKeys: [] });
  assert.equal(first.newEntitlements.length, 2);
  assert.equal(first.newAmount, 7000);

  // Everything the first pass accepted is now stored.
  const stored = first.newEntitlements.map((row) =>
    fees.entitlementKey({ subscriberId: row.subscriberId, stage: row.stage, period: '2026-07' }),
  );
  const second = fees.buildImportPreview(rows, { period: '2026-07', existingKeys: stored });

  assert.equal(second.valid, 2);
  assert.equal(second.duplicatesAlreadyStored, 2);
  assert.equal(second.newEntitlements.length, 0);
  assert.equal(second.newAmount, 0);
  assert.equal(second.importable, false);
});

test('an unknown Remaining is never imported silently', () => {
  const preview = fees.buildImportPreview(
    [{ 'Subscriber ID': 'S1', Reseller: 'R', Remaining: 8500 }],
    { period: '2026-07', existingKeys: [] },
  );
  assert.equal(preview.valid, 0);
  assert.equal(preview.invalid, 1);
  assert.equal(preview.reasons.unknownRemaining, 1);
  assert.equal(preview.amount, 0);
  assert.equal(preview.importable, false);
});

// --------------------------------------------------------------- dashboard --
test('the dashboard counters cover stages, invoices and payments', () => {
  const summary = fees.summarizeEntitlements([
    entitlement({ stage: 'P1', amount: 3000, invoice_status: 'approved', payment_status: 'eligible' }),
    entitlement({ stage: 'P2', amount: 3000, invoice_status: 'pending' }),
    entitlement({ stage: 'P3', amount: 3000, invoice_status: 'missing' }),
    entitlement({ stage: 'P4', amount: 4000, invoice_status: 'rejected' }),
    entitlement({ stage: 'P4', amount: 4000, invoice_status: 'approved', payment_status: 'paid', paid_amount: 4000 }),
    entitlement({ stage: 'DONE', remaining: 0, amount: 0, payment_status: 'not_eligible' }),
  ]);

  assert.equal(summary.total, 6);
  assert.equal(summary.done, 1);
  assert.equal(summary.pending, 5);
  assert.deepEqual(summary.stages, { P1: 1, P2: 1, P3: 1, P4: 2, DONE: 1 });
  // The DONE row keeps the default 'pending' invoice status, so pending is 2.
  assert.deepEqual(summary.invoices, { pending: 2, approved: 2, missing: 1, rejected: 1 });
  assert.equal(summary.payments.eligible, 1);
  assert.equal(summary.payments.paid, 1);
  // DONE contributes nothing to the pre-audit total.
  assert.equal(summary.amountBeforeAudit, 3000 + 3000 + 3000 + 4000 + 4000);
  assert.equal(summary.eligibleAmount, 3000);
  assert.equal(summary.paidAmount, 4000);
  assert.equal(summary.remainingToPay, 3000);
});

// ------------------------------------------------------------ payment gate --
test('the payment review separates eligible money from blocked money with reasons', () => {
  const app = loadCurrentApp();
  const rows = [
    entitlement({ reseller: 'Saeed Ammar', stage: 'P1', amount: 3000, invoice_status: 'approved', payment_status: 'eligible' }),
    entitlement({ reseller: 'Saeed Ammar', stage: 'P4', amount: 4000, invoice_status: 'approved', payment_status: 'eligible' }),
    entitlement({ reseller: 'Saeed Ammar', stage: 'P2', amount: 3000, invoice_status: 'missing' }),
    entitlement({ reseller: 'Saeed Ammar', stage: 'P3', amount: 3000, invoice_status: 'rejected' }),
    entitlement({ reseller: 'Saeed Ammar', stage: 'DONE', remaining: 0, amount: 0 }),
    entitlement({ reseller: 'Other Agent', stage: 'P1', amount: 3000, invoice_status: 'approved', payment_status: 'eligible' }),
  ];

  const review = app.installationPaymentReview(rows, 'Saeed Ammar');
  assert.equal(review.eligible.length, 2);
  assert.equal(review.amount, 7000);
  assert.deepEqual({ ...review.stages }, { P1: 1, P2: 0, P3: 0, P4: 1 });
  // DONE is excluded from the review entirely; the other two are blocked with a reason.
  assert.equal(review.blocked.length, 2);
  assert.equal(own(review.reasons).reduce((sum, item) => sum + item.count, 0), 2);
  assert.ok(own(review.reasons).some((item) => item.reason.includes('مفقودة')));
  assert.ok(own(review.reasons).some((item) => item.reason.includes('مرفوضة')));
});

// ------------------------------------------------------------------ export --
test('the export carries every reviewed field', () => {
  const rows = fees.buildExportRows([
    entitlement({
      subscriber_id: 'S1',
      invoice_status: 'approved',
      invoice_audited_at: '2026-08-14T09:30:00Z',
      payment_status: 'paid',
      paid_amount: 3000,
      paid_at: '2026-08-15T08:00:00Z',
    }),
  ]);

  assert.deepEqual(Object.keys(rows[0]), [
    'SubscriberID', 'SubscriberName', 'Reseller', 'Zone', 'FDT', 'Remaining', 'Stage',
    'DueAmount', 'InvoiceStatus', 'InvoiceAuditDate', 'PaymentStatus', 'PaidAmount',
    'PaymentDate', 'Period',
  ]);
  assert.equal(rows[0].InvoiceAuditDate, '2026-08-14');
  assert.equal(rows[0].PaymentDate, '2026-08-15');
  assert.equal(rows[0].Zone, 'NEW');
  assert.equal(rows[0].DueAmount, 3000);
});

test('the Excel report has a summary, a reseller sheet and a detail sheet', () => {
  const app = loadCurrentApp();
  app.installationState.rows = [
    entitlement({ reseller: 'Saeed Ammar', invoice_status: 'approved', payment_status: 'eligible' }),
    entitlement({ reseller: 'Ahmed Abdulabbas', stage: 'DONE', remaining: 0, amount: 0 }),
  ];

  const workbook = app.buildInstallationWorkbook();
  assert.deepEqual(own(workbook.SheetNames), [
    'Installation Summary', 'Installation Resellers', 'Installation Detail',
  ]);
  assert.equal(workbook.Sheets['Installation Detail'].A1.v, 'SubscriberID');
  assert.equal(workbook.Sheets['Installation Detail'].A2.v, 'SUB-1');
});

// -------------------------------------------------------------------- view --
test('the installation panel renders counters and a row per subscriber', () => {
  const app = loadCurrentApp();
  app.installationState.rows = [
    entitlement({ subscriber_id: 'SUB-A', invoice_status: 'approved', payment_status: 'eligible' }),
    entitlement({ subscriber_id: 'SUB-B', stage: 'DONE', remaining: 0, amount: 0, payment_status: 'not_eligible' }),
  ];

  app.renderInstallation();
  const cards = app.__elements.get('installationCards').innerHTML;
  const panel = app.__elements.get('installationPanel').innerHTML;

  assert.ok(cards.includes('إجمالي المشتركين'));
  assert.ok(cards.includes('مؤهل للصرف'));
  assert.ok(cards.includes('المتبقي للصرف'));
  assert.ok(panel.includes('SUB-A'));
  assert.ok(panel.includes('SUB-B'));
  // A DONE subscriber stays visible rather than disappearing from the report.
  assert.ok(panel.includes('مكتمل'));
});

test('an empty result set explains itself instead of rendering a blank table', () => {
  const app = loadCurrentApp();
  app.installationState.rows = [];
  app.renderInstallation();
  assert.ok(app.__elements.get('installationPanel').innerHTML.includes('لا توجد سجلات مطابقة'));
});

// ------------------------------------------------------- acceptance fixtures --
test('acceptance — Saeed Ammar totals survive the entitlement pipeline', () => {
  const rows = [];
  const push = (remaining, count, tag) => {
    for (let index = 0; index < count; index += 1) {
      rows.push(entitlement({
        subscriber_id: `saeed-${tag}-${index}`,
        reseller: 'Saeed Ammar',
        remaining,
        stage: fees.resolveInstallationStage(remaining).stage,
        amount: fees.resolveInstallationStage(remaining).amount,
      }));
    }
  };
  push(0, 2687, 'done'); push(13000, 662, 'p1'); push(10000, 166, 'p2');
  push(7000, 175, 'p3'); push(4000, 253, 'p4');

  const summary = fees.summarizeEntitlements(rows);
  assert.equal(summary.total, 3943);
  assert.equal(summary.done, 2687);
  assert.equal(summary.pending, 1256);
  assert.deepEqual(summary.stages, { P1: 662, P2: 166, P3: 175, P4: 253, DONE: 2687 });
  assert.equal(summary.amountBeforeAudit, 4021000);
});

test('acceptance — Ahmed Abdulabbas totals survive the entitlement pipeline', () => {
  const rows = [];
  const push = (remaining, count, tag) => {
    for (let index = 0; index < count; index += 1) {
      rows.push(entitlement({
        subscriber_id: `ahmed-${tag}-${index}`,
        reseller: 'Ahmed Abdulabbas',
        remaining,
        stage: fees.resolveInstallationStage(remaining).stage,
        amount: fees.resolveInstallationStage(remaining).amount,
      }));
    }
  };
  push(0, 602, 'done'); push(13000, 114, 'p1'); push(10000, 177, 'p2');
  push(7000, 197, 'p3'); push(4000, 417, 'p4');

  const summary = fees.summarizeEntitlements(rows);
  assert.equal(summary.total, 1507);
  assert.equal(summary.done, 602);
  assert.equal(summary.pending, 905);
  assert.deepEqual(summary.stages, { P1: 114, P2: 177, P3: 197, P4: 417, DONE: 602 });
  assert.equal(summary.amountBeforeAudit, 3132000);
});

test('index.html loads the installation-fees module from a path that exists', () => {
  const fs = require('node:fs');
  const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
  const match = html.match(/<script src="(\.\/assets\/js\/[^"]+)"><\/script>/);
  assert.ok(match, 'the module must be loaded with a relative src');
  const onDisk = path.join(__dirname, '..', match[1].replace('./', ''));
  assert.ok(fs.existsSync(onDisk), `${match[1]} must exist on disk`);
  // The harness relies on there being exactly one inline application script.
  const inline = [...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/gi)]
    .map((m) => m[1]).filter((s) => s.trim());
  assert.equal(inline.length, 1);
});
