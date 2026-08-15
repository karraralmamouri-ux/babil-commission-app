const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

const fees = require(path.join(__dirname, '..', 'assets', 'js', 'installation-fees.js'));

// Builds `count` subscriber rows sitting at the given Remaining value.
function rowsAt(reseller, remaining, count, offset) {
  return Array.from({ length: count }, (_, index) => ({
    subscriberId: `${reseller}-${remaining}-${offset + index}`,
    subscriberName: `subscriber ${offset + index}`,
    reseller,
    zone: 'new',
    remaining,
  }));
}

function resellerFixture(reseller, plan) {
  let offset = 0;
  return plan.flatMap(([remaining, count]) => {
    const rows = rowsAt(reseller, remaining, count, offset);
    offset += count;
    return rows;
  });
}

test('every documented Remaining value maps to its stage and amount', () => {
  assert.deepEqual(fees.resolveInstallationStage(13000), { resolved: true, stage: 'P1', amount: 3000, remaining: 13000 });
  assert.deepEqual(fees.resolveInstallationStage(10000), { resolved: true, stage: 'P2', amount: 3000, remaining: 10000 });
  assert.deepEqual(fees.resolveInstallationStage(7000), { resolved: true, stage: 'P3', amount: 3000, remaining: 7000 });
  assert.deepEqual(fees.resolveInstallationStage(4000), { resolved: true, stage: 'P4', amount: 4000, remaining: 4000 });
  assert.deepEqual(fees.resolveInstallationStage(0), { resolved: true, stage: 'DONE', amount: 0, remaining: 0 });
});

test('an unknown Remaining never invents a stage or an amount', () => {
  for (const value of [12999, 13001, 5000, 3000, -4000, 1, 999999]) {
    const result = fees.resolveInstallationStage(value);
    assert.equal(result.resolved, false, `${value} must not resolve`);
    assert.equal(result.stage, null);
    assert.equal(result.amount, 0);
  }
});

test('fractional, empty, and non-numeric Remaining values are rejected', () => {
  for (const value of [13000.5, '13,000.5', '', null, undefined, 'thirteen', {}, NaN]) {
    const result = fees.resolveInstallationStage(value);
    assert.equal(result.resolved, false);
    assert.equal(result.amount, 0);
  }
  // Thousands separators and Arabic-Indic digits are a formatting difference, not a value difference.
  assert.equal(fees.resolveInstallationStage('13,000').stage, 'P1');
  assert.equal(fees.resolveInstallationStage('١٣٠٠٠').stage, 'P1');
});

test('acceptance fixture — Saeed Ammar', () => {
  const rows = resellerFixture('Saeed Ammar', [
    [0, 2687],
    [13000, 662],
    [10000, 166],
    [7000, 175],
    [4000, 253],
  ]);

  const batch = fees.summarizeInstallationBatch(rows, { period: '2026-07' });

  assert.equal(batch.total, 3943);
  assert.equal(batch.done, 2687);
  assert.equal(batch.stages.P1, 662);
  assert.equal(batch.stages.P2, 166);
  assert.equal(batch.stages.P3, 175);
  assert.equal(batch.stages.P4, 253);
  assert.equal(batch.pending, 1256);
  assert.equal(batch.done + batch.pending, batch.total);
  assert.equal(batch.reconciled, true);

  // 662x3000 + 166x3000 + 175x3000 + 253x4000
  assert.equal(batch.stageAmounts.P1, 1986000);
  assert.equal(batch.stageAmounts.P2, 498000);
  assert.equal(batch.stageAmounts.P3, 525000);
  assert.equal(batch.stageAmounts.P4, 1012000);
  assert.equal(batch.amount, 4021000);
  assert.equal(Number.isInteger(batch.amount), true);
});

test('acceptance fixture — Ahmed Abdulabbas', () => {
  const rows = resellerFixture('Ahmed Abdulabbas', [
    [0, 602],
    [13000, 114],
    [10000, 177],
    [7000, 197],
    [4000, 417],
  ]);

  const batch = fees.summarizeInstallationBatch(rows, { period: '2026-07' });

  assert.equal(batch.total, 1507);
  assert.equal(batch.done, 602);
  assert.equal(batch.stages.P1, 114);
  assert.equal(batch.stages.P2, 177);
  assert.equal(batch.stages.P3, 197);
  assert.equal(batch.stages.P4, 417);
  assert.equal(batch.pending, 905);
  assert.equal(batch.done + batch.pending, batch.total);

  assert.equal(batch.stageAmounts.P1, 342000);
  assert.equal(batch.stageAmounts.P2, 531000);
  assert.equal(batch.stageAmounts.P3, 591000);
  assert.equal(batch.stageAmounts.P4, 1668000);
  assert.equal(batch.amount, 3132000);
});

test('both fixtures stay separated when imported in one batch', () => {
  const rows = [
    ...resellerFixture('Saeed Ammar', [[0, 2687], [13000, 662], [10000, 166], [7000, 175], [4000, 253]]),
    ...resellerFixture('Ahmed Abdulabbas', [[0, 602], [13000, 114], [10000, 177], [7000, 197], [4000, 417]]),
  ];

  const batch = fees.summarizeInstallationBatch(rows, { period: '2026-07' });
  assert.equal(batch.total, 3943 + 1507);
  assert.equal(batch.amount, 4021000 + 3132000);

  const byReseller = fees.summarizeByReseller(batch);
  const saeed = byReseller.find((item) => item.reseller === 'Saeed Ammar');
  const ahmed = byReseller.find((item) => item.reseller === 'Ahmed Abdulabbas');
  assert.equal(saeed.amount, 4021000);
  assert.equal(saeed.total, 3943);
  assert.equal(ahmed.amount, 3132000);
  assert.equal(ahmed.total, 1507);
});

test('re-importing the same subscriber and stage does not double the entitlement', () => {
  const rows = resellerFixture('Saeed Ammar', [[13000, 3]]);
  const batch = fees.summarizeInstallationBatch([...rows, ...rows], { period: '2026-07' });

  assert.equal(batch.sourceRows, 6);
  assert.equal(batch.total, 3);
  assert.equal(batch.duplicates.length, 3);
  assert.equal(batch.amount, 9000);
  // The duplicate points back at the row it collided with, not at a row number identity.
  assert.equal(typeof batch.duplicates[0].duplicateOfRow, 'number');
});

test('the same subscriber in a different period is a separate entitlement', () => {
  const rows = resellerFixture('Saeed Ammar', [[13000, 2]]);
  const july = fees.summarizeInstallationBatch(rows, { period: '2026-07' });
  const august = fees.summarizeInstallationBatch(rows, { period: '2026-08' });

  assert.equal(july.duplicates.length, 0);
  assert.equal(august.duplicates.length, 0);
  assert.notEqual(
    fees.entitlementKey({ subscriberId: 'x', stage: 'P1', period: '2026-07' }),
    fees.entitlementKey({ subscriberId: 'x', stage: 'P1', period: '2026-08' }),
  );
});

test('invalid rows are quarantined and never counted as money', () => {
  const batch = fees.summarizeInstallationBatch(
    [
      { subscriberId: 'a', reseller: 'R', remaining: 13000 },
      { subscriberId: '', reseller: 'R', remaining: 13000 },
      { subscriberId: 'c', reseller: '', remaining: 13000 },
      { subscriberId: 'd', reseller: 'R', remaining: 5500 },
    ],
    { period: '2026-07' },
  );

  assert.equal(batch.total, 1);
  assert.equal(batch.amount, 3000);
  assert.equal(batch.invalid.length, 3);
  assert.ok(batch.invalid.some((row) => row.problems.join(' ').includes('معرّف المشترك مفقود')));
  assert.ok(batch.invalid.some((row) => row.problems.join(' ').includes('الوكيل مفقود')));
  assert.ok(batch.invalid.some((row) => row.problems.join(' ').includes('غير معروفة')));
});

test('DONE subscribers stay in the data with a zero entitlement', () => {
  const batch = fees.summarizeInstallationBatch(
    [{ subscriberId: 'a', reseller: 'R', remaining: 0 }],
    { period: '2026-07' },
  );

  assert.equal(batch.total, 1);
  assert.equal(batch.done, 1);
  assert.equal(batch.stages.DONE, 1);
  assert.equal(batch.amount, 0);
  assert.equal(batch.accepted[0].stage, 'DONE');
});
