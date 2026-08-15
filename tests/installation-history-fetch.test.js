const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const { loadCurrentApp } = require('./load-current-app');

// payment_eligible and warnings are derived on the server and stored. If the
// read does not ask for them, the interface silently loses both on reload and
// reports zeros while the database holds the real figures. These tests pin the
// read down so that regression cannot come back unnoticed.

function stubFetch(captured, rows) {
  return async (url) => {
    captured.push(String(url));
    return {
      ok: true,
      status: 200,
      headers: { get: () => null },
      json: async () => rows,
      text: async () => JSON.stringify(rows),
    };
  };
}

const STORED_ROWS = [
  {
    subscriber_id: 'a-eligible', reseller: 'R1', fdt: '74', start_date: '2025-11-24',
    installation_subscriber_state: [{
      as_of_date: '2026-07-31', remaining: 4000, current_stage: 'P4',
      resolution: 'resolved', payment_eligible: true, warnings: [],
    }],
    installation_payment_history: [{ stage: 'P1', amount: 3000, payment_date: '2025-12-20' }],
  },
  {
    subscriber_id: 'b-mismatch', reseller: 'R1', fdt: null, start_date: '2025-11-24',
    installation_subscriber_state: [{
      as_of_date: '2026-07-31', remaining: 0, current_stage: 'DONE',
      resolution: 'unresolved', payment_eligible: false, warnings: ['remaining_mismatch'],
    }],
    installation_payment_history: [],
  },
  {
    subscriber_id: 'c-blank', reseller: 'R2', fdt: null, start_date: '2026-01-17',
    installation_subscriber_state: [{
      as_of_date: '2026-07-31', remaining: null, current_stage: null,
      resolution: 'unresolved', payment_eligible: false, warnings: ['remaining_missing'],
    }],
    installation_payment_history: [{ stage: 'P1', amount: 3000, payment_date: '2026-02-17' }],
  },
  {
    subscriber_id: 'd-incomplete', reseller: 'R2', fdt: null, start_date: '2026-01-19',
    installation_subscriber_state: [{
      as_of_date: '2026-07-31', remaining: 0, current_stage: 'DONE',
      resolution: 'resolved', payment_eligible: false,
      warnings: ['historical_payment_detail_incomplete'],
    }],
    installation_payment_history: [{ stage: 'P1', amount: 3000, payment_date: '2025-12-20' }],
  },
];

test('the subscriber read asks the database for eligibility and warnings', () => {
  const source = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
  const select = (source.match(/installation_subscriber_state\(([^)]+)\)/) || [])[1] || '';

  assert.ok(select.includes('payment_eligible'), 'payment_eligible must be selected');
  assert.ok(select.includes('warnings'), 'warnings must be selected');
  // The fields that were already there must survive.
  ['as_of_date', 'remaining', 'current_stage', 'resolution'].forEach((field) => {
    assert.ok(select.includes(field), `${field} must still be selected`);
  });
});

test('the fetched rows carry eligibility and warnings through to the caller', async () => {
  const captured = [];
  const app = loadCurrentApp({ fetch: stubFetch(captured, STORED_ROWS) });

  const rows = await app.fetchInstallationSubscribers();

  assert.equal(captured.length, 1);
  assert.ok(captured[0].includes('payment_eligible'), 'the request must ask for payment_eligible');
  assert.ok(captured[0].includes('warnings'), 'the request must ask for warnings');

  const state = (row) => row.installation_subscriber_state[0];
  assert.equal(state(rows[0]).payment_eligible, true);
  assert.deepEqual(state(rows[1]).warnings, ['remaining_mismatch']);
  assert.deepEqual(state(rows[2]).warnings, ['remaining_missing']);
  assert.deepEqual(state(rows[3]).warnings, ['historical_payment_detail_incomplete']);
});

test('counters after a reload come from the stored values, not a re-derivation', async () => {
  const captured = [];
  const app = loadCurrentApp({ fetch: stubFetch(captured, STORED_ROWS) });
  const rows = await app.fetchInstallationSubscribers();
  const states = rows.map((r) => r.installation_subscriber_state[0]);

  const eligible = states.filter((s) => s.payment_eligible).length;
  const blocked = states.filter((s) => s.payment_eligible === false).length;
  const unresolved = states.filter((s) => s.resolution === 'unresolved').length;

  assert.equal(eligible, 1);
  assert.equal(blocked, 3);
  assert.equal(unresolved, 2);
  assert.equal(eligible + blocked, rows.length, 'every subscriber lands in exactly one bucket');
});

test('a stored decision is honoured even when the raw figures would suggest otherwise', async () => {
  // A row sitting on P4 with clean-looking figures, but the server stored it as
  // unresolved and blocked. The interface must report what the server decided;
  // eligibility is never recomputed in the browser.
  const contradictory = [{
    subscriber_id: 'server-says-blocked', reseller: 'R1', fdt: null, start_date: '2025-11-24',
    installation_subscriber_state: [{
      as_of_date: '2026-07-31', remaining: 4000, current_stage: 'P4',
      resolution: 'unresolved', payment_eligible: false, warnings: ['remaining_mismatch'],
    }],
    installation_payment_history: [],
  }];
  const app = loadCurrentApp({ fetch: stubFetch([], contradictory) });
  const [row] = await app.fetchInstallationSubscribers();
  const state = row.installation_subscriber_state[0];

  assert.equal(state.current_stage, 'P4');
  assert.equal(state.payment_eligible, false, 'the stored decision wins over the stage');
  assert.equal(state.resolution, 'unresolved');
});

test('payment stages are still derived for the import preview', async () => {
  const app = loadCurrentApp({ fetch: stubFetch([], STORED_ROWS) });
  const rows = await app.fetchInstallationSubscribers();

  assert.deepEqual(rows[0].payment_stages, ['P1']);
  assert.deepEqual(rows[1].payment_stages, []);
});
