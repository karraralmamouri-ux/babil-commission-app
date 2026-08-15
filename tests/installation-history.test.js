const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

const fees = require(path.join(__dirname, '..', 'assets', 'js', 'installation-fees.js'));

// Sheet rows arrive from SheetJS keyed by the header text, which differs
// between resellers: one sheet carries FDT, another does not, and one carries
// a stray "Column 18". The parser must key on header names, never position.
function sheetRow(overrides) {
  return Object.assign({
    'Subscriber Name': '',
    'Start Date': null,
    'Total Amount': null,
    Payment1: null, Date1: null,
    Payment2: null, Date2: null,
    Payment3: null, Date3: null,
    Payment4: null, Date4: null,
    'Received Total': null,
    Remaining: null,
    Notes: null,
  }, overrides);
}

const FULLY_PAID = {
  'Subscriber Name': 'sub-done',
  'Total Amount': 13000,
  Payment1: 3000, Date1: new Date(2025, 11, 20),
  Payment2: 3000, Date2: new Date(2026, 1, 17),
  Payment3: 3000, Date3: new Date(2026, 1, 17),
  Payment4: 4000, Date4: new Date(2026, 2, 15),
  'Received Total': 13000,
  Remaining: 0,
};

test('1. a DONE subscriber keeps all four historical payments', () => {
  const row = fees.parseHistoryRow(sheetRow(FULLY_PAID), { reseller: 'R' });
  assert.equal(row.currentStage, 'DONE');
  assert.equal(row.resolution, 'resolved');
  assert.deepEqual(row.payments.map((p) => p.stage), ['P1', 'P2', 'P3', 'P4']);
  assert.deepEqual(row.payments.map((p) => p.amount), [3000, 3000, 3000, 4000]);
  assert.deepEqual(row.warnings, []);
});

test('2. a subscriber at P4 carries exactly the first three payments', () => {
  const row = fees.parseHistoryRow(sheetRow({
    'Subscriber Name': 'sub-p4', 'Total Amount': 13000,
    Payment1: 3000, Date1: new Date(2025, 11, 20),
    Payment2: 3000, Date2: new Date(2026, 0, 20),
    Payment3: 3000, Date3: new Date(2026, 1, 20),
    'Received Total': 9000, Remaining: 4000,
  }), { reseller: 'R' });
  assert.equal(row.currentStage, 'P4');
  assert.deepEqual(row.payments.map((p) => p.stage), ['P1', 'P2', 'P3']);
});

test('3. a subscriber at P3 carries two payments', () => {
  const row = fees.parseHistoryRow(sheetRow({
    'Subscriber Name': 'sub-p3', 'Total Amount': 13000,
    Payment1: 3000, Date1: new Date(2025, 11, 20),
    Payment2: 3000, Date2: new Date(2026, 0, 20),
    'Received Total': 6000, Remaining: 7000,
  }), { reseller: 'R' });
  assert.equal(row.currentStage, 'P3');
  assert.equal(row.payments.length, 2);
});

test('4. a subscriber at P2 carries one payment', () => {
  const row = fees.parseHistoryRow(sheetRow({
    'Subscriber Name': 'sub-p2', 'Total Amount': 13000,
    Payment1: 3000, Date1: new Date(2025, 11, 20),
    'Received Total': 3000, Remaining: 10000,
  }), { reseller: 'R' });
  assert.equal(row.currentStage, 'P2');
  assert.equal(row.payments.length, 1);
});

test('5. a subscriber at P1 has no payment history yet', () => {
  const row = fees.parseHistoryRow(sheetRow({
    'Subscriber Name': 'sub-p1', 'Total Amount': 13000,
    'Received Total': 0, Remaining: 13000,
  }), { reseller: 'R' });
  assert.equal(row.currentStage, 'P1');
  assert.deepEqual(row.payments, []);
});

test('6. a blank template row is not a subscriber', () => {
  assert.equal(fees.parseHistoryRow(sheetRow({}), { reseller: 'R' }), null);
  assert.equal(fees.parseHistoryRow(sheetRow({ 'Subscriber Name': '   ' }), { reseller: 'R' }), null);
  // A row carrying stray template values but no subscriber is still ignored.
  assert.equal(
    fees.parseHistoryRow(sheetRow({ 'Total Amount': 13000, Remaining: 13000 }), { reseller: 'R' }),
    null,
  );
});

test('7. a real subscriber with a blank Remaining is unresolved, never guessed', () => {
  const row = fees.parseHistoryRow(sheetRow({
    'Subscriber Name': 'sub-unknown', 'Total Amount': 13000,
    Payment1: 3000, Date1: new Date(2025, 11, 20),
    'Received Total': 3000, Remaining: null,
  }), { reseller: 'R' });
  assert.equal(row.resolution, 'unresolved');
  assert.equal(row.currentStage, null);
  assert.ok(row.warnings.includes('remaining_missing'));
  // Its payment history is still kept.
  assert.equal(row.payments.length, 1);
});

test('7b. a Remaining the business rules do not define is unresolved, not rounded', () => {
  const row = fees.parseHistoryRow(sheetRow({
    'Subscriber Name': 'sub-odd', 'Total Amount': 13000, Remaining: 5500,
  }), { reseller: 'R' });
  assert.equal(row.resolution, 'unresolved');
  assert.equal(row.currentStage, null);
  assert.ok(row.warnings.includes('remaining_unmapped'));
});

test('8. re-previewing the same file against imported state adds nothing', () => {
  const sheets = [{ reseller: 'R', rows: [sheetRow(FULLY_PAID)] }];
  const first = fees.buildHistoricalPreview(sheets, { asOfDate: '2026-08-15' });
  assert.equal(first.newSubscribers, 1);
  assert.equal(first.newPayments, 4);

  const known = new Map(first.rows.map((r) => [r.subscriberKey, {
    reseller: r.reseller, paymentStages: r.payments.map((p) => p.stage),
  }]));
  const second = fees.buildHistoricalPreview(sheets, { asOfDate: '2026-08-15', known });
  assert.equal(second.newSubscribers, 0);
  assert.equal(second.newPayments, 0);
  assert.equal(second.duplicatePayments, 4);
  assert.equal(second.existingUpdated, 1);
});

test('9. a later file contributes only the payment that is genuinely new', () => {
  const known = new Map([['sub-p3', { reseller: 'R', paymentStages: ['P1', 'P2'] }]]);
  const later = fees.buildHistoricalPreview([{
    reseller: 'R',
    rows: [sheetRow({
      'Subscriber Name': 'sub-p3', 'Total Amount': 13000,
      Payment1: 3000, Date1: new Date(2025, 11, 20),
      Payment2: 3000, Date2: new Date(2026, 0, 20),
      Payment3: 3000, Date3: new Date(2026, 7, 30),
      'Received Total': 9000, Remaining: 4000,
    })],
  }], { asOfDate: '2026-08-15', known });

  assert.equal(later.newSubscribers, 0);
  assert.equal(later.newPayments, 1);
  assert.equal(later.duplicatePayments, 2);
  assert.equal(later.stages.P4, 1, 'the current stage moves on to P4');
});

test('10. the same payment offered twice is never counted as new', () => {
  const known = new Map([['sub-done', { reseller: 'R', paymentStages: ['P1', 'P2', 'P3', 'P4'] }]]);
  const preview = fees.buildHistoricalPreview(
    [{ reseller: 'R', rows: [sheetRow(FULLY_PAID)] }],
    { asOfDate: '2026-08-15', known },
  );
  assert.equal(preview.newPayments, 0);
  assert.equal(preview.duplicatePayments, 4);
});

test('11. payments that do not add up to Received Total are flagged, not rejected', () => {
  const row = fees.parseHistoryRow(sheetRow({
    'Subscriber Name': 'sub-recv', 'Total Amount': 13000,
    Payment1: 3000, Date1: new Date(2025, 11, 20),
    Payment2: 3000, Date2: new Date(2026, 0, 20),
    'Received Total': 9000, Remaining: 4000,
  }), { reseller: 'R' });
  assert.ok(row.warnings.includes('received_total_mismatch'));
  assert.equal(row.paidSum, 6000);
  // Still a usable row: the stage is read and the payments are kept.
  assert.equal(row.currentStage, 'P4');
  assert.equal(row.payments.length, 2);
});

test('12. Total minus Received disagreeing with Remaining is flagged, not corrected', () => {
  const row = fees.parseHistoryRow(sheetRow({
    'Subscriber Name': 'sub-rem', 'Total Amount': 13000,
    Payment1: 3000, Date1: new Date(2025, 11, 20),
    Payment2: 3000, Date2: new Date(2026, 0, 20),
    Payment3: 3000, Date3: new Date(2026, 1, 20),
    'Received Total': 9000, Remaining: 0,
  }), { reseller: 'R' });
  assert.ok(row.warnings.includes('remaining_mismatch'));
  assert.equal(row.remaining, 0, 'the file value is preserved as read');
  assert.equal(row.receivedTotal, 9000);
  assert.equal(row.currentStage, 'DONE');
});

test('13. payment dates survive parsing exactly', () => {
  const row = fees.parseHistoryRow(sheetRow(FULLY_PAID), { reseller: 'R' });
  assert.deepEqual(
    row.payments.map((p) => p.paymentDate),
    ['2025-12-20', '2026-02-17', '2026-02-17', '2026-03-15'],
  );
  // A missing date is recorded as missing rather than invented.
  const noDate = fees.parseHistoryRow(sheetRow({
    'Subscriber Name': 'sub-nodate', Payment1: 3000, Remaining: 10000,
  }), { reseller: 'R' });
  assert.equal(noDate.payments[0].paymentDate, null);
  assert.ok(noDate.warnings.includes('payment_date_missing:P1'));
});

test('14. the reseller comes from the sheet it was read from', () => {
  const preview = fees.buildHistoricalPreview([
    { reseller: 'صفاء 1', rows: [sheetRow({ 'Subscriber Name': 'a-1', Remaining: 0 })] },
    { reseller: 'بارق ليث شعران', rows: [sheetRow({ 'Subscriber Name': 'b-1', Remaining: 13000 })] },
  ], { asOfDate: '2026-08-15' });

  assert.deepEqual(preview.perReseller.map((r) => r.reseller), ['صفاء 1', 'بارق ليث شعران']);
  assert.equal(preview.rows.find((r) => r.subscriberId === 'a-1').reseller, 'صفاء 1');
  assert.equal(preview.rows.find((r) => r.subscriberId === 'b-1').reseller, 'بارق ليث شعران');
});

test('15. FDT is kept when the sheet has the column and absent when it does not', () => {
  const withFdt = fees.parseHistoryRow({
    'Subscriber Name': 'sub-fdt', FDT: 74, Remaining: 0, 'Total Amount': 13000,
  }, { reseller: 'R' });
  assert.equal(withFdt.fdt, '74');

  const withoutFdt = fees.parseHistoryRow(sheetRow({
    'Subscriber Name': 'sub-nofdt', Remaining: 0,
  }), { reseller: 'R' });
  assert.equal(withoutFdt.fdt, null);
});

test('a stray template column does not disturb header matching', () => {
  // The real workbook has a "Column 18" between the name and the start date.
  const row = fees.parseHistoryRow({
    'Subscriber Name': 'sub-stray', 'Column 18': null, 'Start Date': new Date(2025, 10, 27),
    'Total Amount': 13000, Payment1: 3000, Date1: new Date(2025, 11, 20),
    'Received Total': 3000, Remaining: 10000, Notes: null,
  }, { reseller: 'R' });
  assert.equal(row.currentStage, 'P2');
  assert.equal(row.startDate, '2025-11-27');
});

test('the same subscriber twice in one upload is counted once and reported', () => {
  const preview = fees.buildHistoricalPreview([{
    reseller: 'R',
    rows: [sheetRow({ 'Subscriber Name': 'dup-1', Remaining: 0 }),
           sheetRow({ 'Subscriber Name': 'DUP-1', Remaining: 13000 })],
  }], { asOfDate: '2026-08-15' });
  assert.equal(preview.realSubscribers, 1);
  assert.equal(preview.duplicates.length, 1);
});

test('the preview refuses to invent an as-of date', () => {
  const preview = fees.buildHistoricalPreview(
    [{ reseller: 'R', rows: [sheetRow(FULLY_PAID)] }], {},
  );
  assert.equal(preview.asOfDate, null);
  assert.equal(preview.asOfDateProvided, false);
});

test('blank rows never reach any subscriber tally', () => {
  const preview = fees.buildHistoricalPreview([{
    reseller: 'R',
    rows: [sheetRow({ 'Subscriber Name': 'real-1', Remaining: 0 }),
           sheetRow({}), sheetRow({}), sheetRow({})],
  }], { asOfDate: '2026-08-15' });

  assert.equal(preview.totalRows, 4);
  assert.equal(preview.ignoredRows, 3);
  assert.equal(preview.realSubscribers, 1);
  assert.equal(preview.unresolved, 0);
  assert.equal(preview.stages.DONE, 1);
});

test('rows sent to the server carry no stage or amount the server should derive', () => {
  const preview = fees.buildHistoricalPreview(
    [{ reseller: 'R', rows: [sheetRow(FULLY_PAID)] }], { asOfDate: '2026-08-15' },
  );
  const [row] = fees.buildHistoricalImportRows(preview);
  assert.equal('stage' in row, false);
  assert.equal('amount' in row, false);
  assert.equal('current_stage' in row, false);
  assert.equal(row.remaining, 0);
  assert.equal(row.payments.length, 4);
});

// ---------------------------------------------------------------- eligibility --
// A validation mismatch must not be able to reach payment eligibility by any
// route: not through the stage it happens to sit on, and not through DONE.

test('a financial mismatch keeps its raw values but loses resolution and eligibility', () => {
  const row = fees.parseHistoryRow(sheetRow({
    'Subscriber Name': 'sub-mismatch', 'Total Amount': 13000,
    Payment1: 3000, Date1: new Date(2025, 11, 20),
    Payment2: 3000, Date2: new Date(2026, 0, 20),
    Payment3: 3000, Date3: new Date(2026, 1, 20),
    'Received Total': 9000, Remaining: 0,
  }), { reseller: 'R' });

  assert.equal(row.totalAmount, 13000, 'raw values are preserved');
  assert.equal(row.receivedTotal, 9000);
  assert.equal(row.remaining, 0);
  assert.equal(row.financialMismatch, true);
  assert.equal(row.resolution, 'unresolved');
  assert.equal(row.stageIsFinal, false, 'the derived stage is not final');
  assert.equal(row.paymentEligible, false);
  assert.ok(row.warnings.includes('remaining_mismatch'));
});

test('a mismatch sitting on a payable stage is still blocked', () => {
  const row = fees.parseHistoryRow(sheetRow({
    'Subscriber Name': 'sub-mismatch-p4', 'Total Amount': 13000,
    Payment1: 3000, Date1: new Date(2025, 11, 20),
    'Received Total': 3000, Remaining: 4000,
  }), { reseller: 'R' });

  assert.equal(row.currentStage, 'P4');
  assert.equal(row.financialMismatch, true);
  assert.equal(row.paymentEligible, false, 'a P4 that does not reconcile must not be payable');
});

test('a blank Remaining is never payment eligible', () => {
  const row = fees.parseHistoryRow(sheetRow({
    'Subscriber Name': 'sub-blank', 'Total Amount': 13000,
    Payment1: 3000, Date1: new Date(2025, 11, 20),
    'Received Total': 3000, Remaining: null,
  }), { reseller: 'R' });

  assert.equal(row.currentStage, null);
  assert.equal(row.resolution, 'unresolved');
  assert.equal(row.paymentEligible, false);
  assert.equal(row.payments.length, 1, 'its history is still kept');
});

test('a balanced DONE without P4 stays resolved but is flagged as incomplete', () => {
  const row = fees.parseHistoryRow(sheetRow({
    'Subscriber Name': 'sub-done-no-p4', 'Total Amount': 13000,
    Payment1: 3000, Date1: new Date(2025, 11, 20),
    Payment2: 3000, Date2: new Date(2026, 0, 20),
    Payment3: 7000, Date3: new Date(2026, 1, 20),
    'Received Total': 13000, Remaining: 0,
  }), { reseller: 'R' });

  assert.equal(row.resolution, 'resolved');
  assert.equal(row.historyIncomplete, true);
  assert.ok(row.warnings.includes('historical_payment_detail_incomplete'));
  assert.equal(row.payments.length, 3, 'no phantom P4 is invented');
  assert.equal(row.paymentEligible, false, 'DONE has nothing left to pay');
});

test('an unbalanced DONE without P4 falls under the mismatch rule instead', () => {
  const row = fees.parseHistoryRow(sheetRow({
    'Subscriber Name': 'sub-done-broken', 'Total Amount': 13000,
    Payment1: 3000, Date1: new Date(2025, 11, 20),
    'Received Total': 3000, Remaining: 0,
  }), { reseller: 'R' });

  assert.equal(row.resolution, 'unresolved');
  assert.equal(row.financialMismatch, true);
  assert.equal(row.paymentEligible, false);
});

test('a clean pending row is the only shape that IS eligible', () => {
  const row = fees.parseHistoryRow(sheetRow({
    'Subscriber Name': 'sub-clean', 'Total Amount': 13000,
    Payment1: 3000, Date1: new Date(2025, 11, 20),
    Payment2: 3000, Date2: new Date(2026, 0, 20),
    Payment3: 3000, Date3: new Date(2026, 1, 20),
    'Received Total': 9000, Remaining: 4000,
  }), { reseller: 'R' });

  assert.equal(row.resolution, 'resolved');
  assert.equal(row.stageIsFinal, true);
  assert.equal(row.paymentEligible, true);
  assert.deepEqual(row.warnings, []);
});

test('no row carrying any validation warning is ever eligible', () => {
  const preview = fees.buildHistoricalPreview([{
    reseller: 'R',
    rows: [
      sheetRow({ 'Subscriber Name': 'w-1', 'Total Amount': 13000, 'Received Total': 9000, Remaining: 0 }),
      sheetRow({ 'Subscriber Name': 'w-2', 'Total Amount': 13000, Remaining: null }),
      sheetRow({ 'Subscriber Name': 'w-3', 'Total Amount': 13000, Remaining: 5500 }),
      sheetRow({
        'Subscriber Name': 'w-4', 'Total Amount': 13000,
        Payment1: 3000, Date1: new Date(2025, 11, 20),
        'Received Total': 3000, Remaining: 10000,
      }),
    ],
  }], { asOfDate: '2026-08-15' });

  preview.rows.forEach((row) => {
    const blocking = row.warnings.filter((w) => !w.startsWith('payment_date_missing')
      && w !== 'historical_payment_detail_incomplete');
    if (blocking.length) {
      assert.equal(row.paymentEligible, false, `${row.subscriberId} carries ${blocking} yet is eligible`);
    }
  });

  assert.equal(preview.eligible, 1, 'only the clean P2 row is eligible');
  assert.equal(preview.blocked, 3);
  assert.equal(preview.financialMismatches, 1);
});

test('the preview reports resolution, mismatches, incompleteness and eligibility', () => {
  const preview = fees.buildHistoricalPreview([{
    reseller: 'R',
    rows: [
      sheetRow({ 'Subscriber Name': 'p-clean', 'Total Amount': 13000, Payment1: 3000, Date1: new Date(2025, 11, 20), 'Received Total': 3000, Remaining: 10000 }),
      sheetRow({ 'Subscriber Name': 'p-mismatch', 'Total Amount': 13000, 'Received Total': 9000, Remaining: 0 }),
      sheetRow({ 'Subscriber Name': 'p-incomplete', 'Total Amount': 13000, Payment1: 13000, Date1: new Date(2026, 1, 20), 'Received Total': 13000, Remaining: 0 }),
    ],
  }], { asOfDate: '2026-08-15' });

  assert.equal(preview.resolved, 2);
  assert.equal(preview.unresolved, 1);
  assert.equal(preview.financialMismatches, 1);
  assert.equal(preview.incompleteHistories, 2, 'both DONE rows lack a P4 payment');
  assert.equal(preview.eligible, 1);
  assert.equal(preview.blocked, 2);
  assert.equal(preview.resolved + preview.unresolved, preview.realSubscribers);
  assert.equal(preview.eligible + preview.blocked, preview.realSubscribers);
});
