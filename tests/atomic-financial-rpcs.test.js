const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');

const migration = fs.readFileSync(
  path.join(
    __dirname,
    '..',
    'supabase',
    'migrations',
    '20260804230000_add_atomic_financial_rpcs.sql'
  ),
  'utf8'
);

function functionDefinition(name) {
  const start = migration.indexOf(`function public.${name}(`);
  assert.notEqual(start, -1, `${name} must be defined`);
  const end = migration.indexOf('$$;', start);
  assert.notEqual(end, -1, `${name} must have a complete body`);
  return migration.slice(start, end);
}

test('financial RPC migration adds structured idempotent audit fields', () => {
  for (const column of [
    'entity_type text',
    'entity_id uuid',
    'before_data jsonb',
    'after_data jsonb',
    'request_id uuid',
  ]) {
    assert.match(migration, new RegExp(`add column ${column}`));
  }

  assert.match(
    migration,
    /create unique index audit_logs_actor_request_uidx[\s\S]*\(actor_id, request_id\)[\s\S]*where request_id is not null/
  );
});

test('financial RPCs use authorization, row locks, optimistic concurrency, and atomic audit', () => {
  const updateRow = functionDefinition('update_commission_row');
  const recordPayment = functionDefinition('record_commission_payment');

  assert.match(updateRow, /public\.current_app_role\(\) <> 'admin'/);
  assert.match(recordPayment, /v_role not in \('admin', 'accountant'\)/);

  for (const definition of [updateRow, recordPayment]) {
    assert.match(definition, /security definer/);
    assert.match(definition, /set search_path = ''/);
    assert.match(definition, /request_id is required/);
    assert.match(definition, /pg_catalog\.pg_advisory_xact_lock/);
    assert.match(definition, /for update/);
    assert.match(definition, /updated_at is distinct from p_expected_updated_at/);
    assert.match(definition, /insert into public\.audit_logs/);
    assert.match(definition, /before_data/);
    assert.match(definition, /after_data/);
    assert.match(definition, /'replayed', true/);
  }
});

test('payment RPC calculates the server-side due and rejects overpayment', () => {
  const calculator = functionDefinition('calculate_commission_due');
  const updateRow = functionDefinition('update_commission_row');
  const recordPayment = functionDefinition('record_commission_payment');

  assert.match(calculator, /p_p35 \* v_p35_rate/);
  assert.match(calculator, /p_p45 \* v_p45_rate/);
  assert.match(calculator, /p_p65 \* v_p65_rate/);
  assert.match(calculator, /Commission tier rates must be non-negative numbers/);
  assert.match(recordPayment, /p_paid > v_due/);
  assert.match(recordPayment, /Payment cannot exceed commission due/);
  assert.match(updateRow, /v_before\.paid > v_due/);
  assert.match(updateRow, /Updated commission due cannot be lower than recorded payment/);
});

test('authenticated browser sessions cannot bypass audited financial RPCs', () => {
  for (const table of [
    'commission_months',
    'commission_rows',
    'commission_agents',
  ]) {
    assert.match(
      migration,
      new RegExp(`revoke insert, update, delete on table public\\.${table} from authenticated`)
    );
  }

  assert.match(
    migration,
    /revoke insert on table public\.audit_logs from authenticated/
  );
  assert.match(
    migration,
    /grant execute on function public\.record_commission_payment[\s\S]*to authenticated/
  );
  assert.match(
    migration,
    /grant execute on function public\.update_commission_row[\s\S]*to authenticated/
  );
});
