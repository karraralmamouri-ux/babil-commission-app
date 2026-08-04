const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');

const root = path.resolve(__dirname, '..');
const baselinePath = path.join(
  root,
  'supabase',
  'migrations',
  '20260804170000_reconstructed_baseline.sql'
);
const baseline = fs.readFileSync(baselinePath, 'utf8');
const hardening = fs.readFileSync(
  path.join(
    root,
    'supabase',
    'migrations',
    '20260804183000_harden_authorization.sql'
  ),
  'utf8'
);
const financialConstraints = fs.readFileSync(
  path.join(
    root,
    'supabase',
    'migrations',
    '20260804203000_add_nonnegative_financial_constraints.sql'
  ),
  'utf8'
);

const expectedTables = [
  'profiles',
  'commission_months',
  'commission_rows',
  'commission_agents',
  'audit_logs',
  'commission_audit_logs',
];

test('reconstructed baseline refuses a non-empty application schema', () => {
  assert.match(baseline, /reconstructed baseline requires an empty public application schema/);
  assert.match(baseline, /to_regclass\('public\.profiles'\) is not null/);
});

test('reconstructed baseline creates every reviewed public table with RLS', () => {
  for (const table of expectedTables) {
    assert.match(baseline, new RegExp(`create table public\\.${table} \\(`));
    assert.match(baseline, new RegExp(`alter table public\\.${table} enable row level security;`));
  }
});

test('reconstructed baseline includes role helpers, triggers, and hardened grants', () => {
  for (const fn of [
    'current_app_role',
    'current_user_role',
    'get_my_role',
    'is_admin',
    'protect_accountant_rows',
    'set_updated_at',
  ]) {
    assert.match(baseline, new RegExp(`function public\\.${fn}\\(`));
  }

  assert.match(baseline, /create trigger trg_protect_accountant/);
  assert.doesNotMatch(baseline, /create policy profiles_select_own_or_admin/);
  assert.match(hardening, /create policy profiles_select_own_or_admin/);
  assert.doesNotMatch(baseline, /create policy profiles_(insert|update|delete)/);
  assert.match(baseline, /revoke all privileges on all tables in schema public from anon, authenticated;/);
  assert.match(baseline, /grant select on table public\.profiles to authenticated;/);
});

test('financial constraints reject negative quantities and paid values in both models', () => {
  for (const table of ['commission_rows', 'commission_agents']) {
    assert.match(
      financialConstraints,
      new RegExp(`${table}_quantities_nonnegative[\\s\\S]*p35 >= 0 and p45 >= 0 and p65 >= 0`)
    );
    assert.match(
      financialConstraints,
      new RegExp(`${table}_paid_nonnegative[\\s\\S]*paid >= 0`)
    );
    assert.match(
      financialConstraints,
      new RegExp(`validate constraint ${table}_quantities_nonnegative`)
    );
    assert.match(
      financialConstraints,
      new RegExp(`validate constraint ${table}_paid_nonnegative`)
    );
  }
});
