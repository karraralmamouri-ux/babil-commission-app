const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadCurrentApp } = require('./load-current-app');

const fees = require(path.join(__dirname, '..', 'assets', 'js', 'installation-fees.js'));

// The dashboard used to read installation_entitlements alone. With a historical
// baseline loaded and no operational entitlements yet, every counter showed 0
// while the database held thousands of subscribers. These tests pin the merge:
// current state always comes from the baseline, invoice and payment columns
// come from the entitlement when one exists.

function dbSubscriber(overrides, stateOverrides, payments) {
  return Object.assign({
    subscriber_id: 'SUB-1',
    reseller: 'صفاء 1',
    fdt: null,
    start_date: '2025-11-24',
    installation_subscriber_state: [Object.assign({
      as_of_date: '2026-07-31',
      remaining: 4000,
      current_stage: 'P4',
      resolution: 'resolved',
      payment_eligible: true,
      warnings: [],
    }, stateOverrides || {})],
    installation_payment_history: payments || [],
  }, overrides);
}

const BASELINE = [
  dbSubscriber({ subscriber_id: 'a-p1' }, { remaining: 13000, current_stage: 'P1' }, []),
  dbSubscriber({ subscriber_id: 'a-p2' }, { remaining: 10000, current_stage: 'P2' },
    [{ stage: 'P1', amount: 3000, payment_date: '2025-12-20' }]),
  dbSubscriber({ subscriber_id: 'a-p3' }, { remaining: 7000, current_stage: 'P3' },
    [{ stage: 'P1', amount: 3000, payment_date: '2025-12-20' },
     { stage: 'P2', amount: 3000, payment_date: '2026-01-20' }]),
  dbSubscriber({ subscriber_id: 'a-p4', fdt: '74' }, { remaining: 4000, current_stage: 'P4' },
    [{ stage: 'P1', amount: 3000, payment_date: '2025-12-20' }]),
  dbSubscriber({ subscriber_id: 'a-done' },
    { remaining: 0, current_stage: 'DONE', payment_eligible: false },
    [{ stage: 'P4', amount: 4000, payment_date: '2026-03-15' }]),
  dbSubscriber({ subscriber_id: 'a-mismatch' },
    { remaining: 0, current_stage: 'DONE', resolution: 'unresolved',
      payment_eligible: false, warnings: ['remaining_mismatch'] }, []),
  dbSubscriber({ subscriber_id: 'a-blank', reseller: 'بارق ليث شعران' },
    { remaining: null, current_stage: null, resolution: 'unresolved',
      payment_eligible: false, warnings: ['remaining_missing'] }, []),
];

test('the dashboard counts the baseline, not the operational entitlements', () => {
  const records = BASELINE.map(fees.normalizeSubscriberRecord);
  const summary = fees.summarizeSubscriberStates(records);

  assert.equal(summary.total, 7);
  assert.deepEqual({ ...summary.stages }, { P1: 1, P2: 1, P3: 1, P4: 1, DONE: 2 });
  assert.equal(summary.noStage, 1);
  assert.equal(summary.unresolved, 2);
  assert.equal(summary.resolved, 5);
  assert.equal(summary.eligible, 4);
  assert.equal(summary.blocked, 3);
  assert.equal(summary.eligible + summary.blocked, summary.total);
  assert.equal(summary.historicalPayments, 5);
  assert.equal(summary.warnings.remaining_mismatch, 1);
  assert.equal(summary.warnings.remaining_missing, 1);
});

test('with zero operational entitlements the dashboard still shows every subscriber', () => {
  const records = BASELINE.map(fees.normalizeSubscriberRecord);
  const rows = fees.buildInstallationDashboardRows(records, []);

  assert.equal(rows.length, 7, 'an empty entitlement table must not empty the dashboard');
  assert.ok(rows.every((row) => row.source === 'baseline'));
  assert.ok(rows.every((row) => row.entitlementId === null));
  // The stage and eligibility survive even with no entitlement to attach to.
  assert.equal(rows.filter((row) => row.stage === 'DONE').length, 2);
  assert.equal(rows.filter((row) => row.paymentEligible).length, 4);
});

test('an entitlement attaches its invoice and payment columns to the baseline row', () => {
  const records = BASELINE.map(fees.normalizeSubscriberRecord);
  const rows = fees.buildInstallationDashboardRows(records, [{
    id: 'ent-1', period: '2026-08', subscriber_id: 'a-p4', subscriber_name: 'Named',
    reseller: 'صفاء 1', zone: 'new', fdt: '74', remaining: 4000, stage: 'P4', amount: 4000,
    invoice_status: 'approved', payment_status: 'eligible', paid_amount: 0, paid_at: null,
  }]);

  assert.equal(rows.length, 7, 'the entitlement joins an existing row rather than adding one');
  const joined = rows.find((row) => row.subscriberId === 'a-p4');
  assert.equal(joined.source, 'baseline+entitlement');
  assert.equal(joined.entitlementId, 'ent-1');
  assert.equal(joined.invoiceStatus, 'approved');
  assert.equal(joined.paymentStatus, 'eligible');
  assert.equal(joined.period, '2026-08');
  // Its baseline facts are untouched by the join.
  assert.equal(joined.stage, 'P4');
  assert.equal(joined.historicalPayments, 1);
});

test('an entitlement with no baseline subscriber is still shown, never silently dropped', () => {
  const rows = fees.buildInstallationDashboardRows([], [{
    id: 'ent-orphan', period: '2026-08', subscriber_id: 'not-in-baseline',
    reseller: 'R', zone: 'old', fdt: '12', remaining: 7000, stage: 'P3', amount: 3000,
    invoice_status: 'pending', payment_status: 'awaiting_invoice', paid_amount: 0,
  }]);

  assert.equal(rows.length, 1);
  assert.equal(rows[0].source, 'entitlement');
  assert.equal(rows[0].subscriberId, 'not-in-baseline');
  assert.equal(rows[0].entitlementId, 'ent-orphan');
});

test('eligibility is read from the stored value and never re-derived from the stage', () => {
  const records = [fees.normalizeSubscriberRecord(dbSubscriber(
    { subscriber_id: 'server-blocked' },
    { remaining: 4000, current_stage: 'P4', resolution: 'unresolved',
      payment_eligible: false, warnings: ['remaining_mismatch'] },
  ))];
  const [row] = fees.buildInstallationDashboardRows(records, []);

  assert.equal(row.stage, 'P4', 'the stage the file implied is still shown');
  assert.equal(row.paymentEligible, false, 'but the stored decision governs payment');
  assert.equal(fees.summarizeSubscriberStates(records).eligible, 0);
});

test('the embedded state arrives as an array or an object and both are read', () => {
  const asArray = fees.normalizeSubscriberRecord(dbSubscriber({}, { current_stage: 'P4' }));
  const asObject = fees.normalizeSubscriberRecord({
    subscriber_id: 'SUB-1', reseller: 'R',
    installation_subscriber_state: { remaining: 4000, current_stage: 'P4', payment_eligible: true },
    installation_payment_history: [],
  });
  assert.equal(asArray.currentStage, 'P4');
  assert.equal(asObject.currentStage, 'P4');
  assert.equal(asObject.paymentEligible, true);
});

test('a subscriber with no state row at all does not crash the dashboard', () => {
  const record = fees.normalizeSubscriberRecord({
    subscriber_id: 'no-state', reseller: 'R',
    installation_subscriber_state: [], installation_payment_history: [],
  });
  assert.equal(record.currentStage, null);
  assert.equal(record.paymentEligible, false);
  assert.deepEqual(record.warnings, []);

  const summary = fees.summarizeSubscriberStates([record]);
  assert.equal(summary.total, 1);
  assert.equal(summary.noStage, 1);
  assert.equal(summary.blocked, 1);
});

// ------------------------------------------------------------- through the app --

test('the rendered panel shows baseline subscribers when no entitlement exists', () => {
  const app = loadCurrentApp();
  app.__setAuthProfile({ role: 'admin', is_active: true });
  app.installationState.subscribers = BASELINE;
  app.installationState.rows = [];
  app.installationState.loading = false;
  app.installationState.error = '';

  app.renderInstallation();

  const cards = app.__elements.get("installationCards").innerHTML;
  const panel = app.__elements.get("installationPanel").innerHTML;

  // Read the value out of each card rather than checking a label exists: the
  // first cut of this fix rendered every stage card as 0 because the summary
  // was handed the merged row shape and looked for the normalized one, and a
  // label-only assertion sailed straight past it.
  const cardValues = new Map(
    [...cards.matchAll(/<div class="label">([^<]*)<\/div><div class="value">([^<]*)<\/div>/g)]
      .map((m) => [m[1], m[2]]),
  );
  const expected = {
    'إجمالي المشتركين': '7',
    'مكتمل DONE': '2',
    P1: '1', P2: '1', P3: '1', P4: '1',
    'مؤهل للصرف': '4',
    'محجوب عن الصرف': '3',
    'غير محسوم': '2',
    'دفعات تاريخية': '5',
  };
  Object.entries(expected).forEach(([label, value]) => {
    assert.equal(cardValues.get(label), value, `card "${label}" should read ${value}`);
  });
  // Every baseline subscriber reaches the table body; the header row is not one.
  const bodyRows = ((panel.match(/<tbody>([\s\S]*)<\/tbody>/) || [])[1] || '')
    .match(/<tr>/g) || [];
  assert.equal(bodyRows.length, BASELINE.length);
  assert.ok(panel.includes('a-p1') && panel.includes('a-done'));
});

test('the filter summary counts the merged rows, not the entitlements alone', () => {
  const app = loadCurrentApp();
  app.__setAuthProfile({ role: 'admin', is_active: true });
  app.installationState.subscribers = BASELINE;
  app.installationState.rows = [];
  app.installationState.loading = false;
  app.installationState.error = '';

  app.renderInstallation();
  const summary = app.__elements.get("installationFilterSummary").textContent;
  assert.ok(summary.includes('7'), `expected 7 rows in "${summary}"`);
});
