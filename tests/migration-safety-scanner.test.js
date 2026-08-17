const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

// The scanner is loaded as an ES module from CommonJS, so every test awaits it.
const loadScanner = (() => {
  let cached;
  return async () => {
    if (!cached) {
      const url = require('node:url')
        .pathToFileURL(path.join(__dirname, '..', 'scripts', 'check-migration-safety.mjs')).href;
      cached = await import(url);
    }
    return cached;
  };
})();

const MIGRATIONS_DIR = path.join(__dirname, '..', 'supabase', 'migrations');

test('every published migration passes the scanner', async () => {
  const { scan } = await loadScanner();
  const flagged = fs.readdirSync(MIGRATIONS_DIR)
    .filter((f) => f.endsWith('.sql'))
    .map((f) => scan(fs.readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8'), f))
    .filter((r) => !r.safe);

  assert.deepEqual(flagged.map((f) => f.file), [],
    `flagged:\n${JSON.stringify(flagged, null, 1)}`);
});

test('a real destructive statement is still rejected', async () => {
  const { scan } = await loadScanner();
  const cases = [
    'drop table public.commission_rows;',
    'drop schema public cascade;',
    'truncate table public.installation_payment_history;',
    'alter table public.commission_rows drop column paid;',
    'drop view public.some_report;',
  ];
  cases.forEach((sql) => {
    assert.equal(scan(sql).safe, false, `should reject: ${sql}`);
  });
});

test('idempotent object re-creation is not destruction', async () => {
  const { scan } = await loadScanner();
  const cases = [
    'drop policy if exists p on public.thing;\ncreate policy p on public.thing for select using (true);',
    'drop trigger if exists t on public.thing;',
    'alter table public.thing drop constraint if exists c;',
    'drop index if exists public.idx_thing;',
    'drop function if exists public.f(uuid);',
  ];
  cases.forEach((sql) => {
    assert.equal(scan(sql).safe, true, `should accept: ${sql}`);
  });
});

test('a drop without IF EXISTS is not treated as idempotent', async () => {
  const { scan } = await loadScanner();
  // A bare `drop table` must never slip through on the strength of the word
  // "drop" appearing in an allowed form elsewhere.
  const sql = 'drop policy if exists p on public.thing;\ndrop table public.commission_rows;';
  assert.equal(scan(sql).safe, false);
  assert.equal(scan(sql).destructiveStatements.length, 1);
});

test('CRLF files are handled — the bug that blocked a safe deployment', async () => {
  const { scan } = await loadScanner();
  // `.` does not match \r, so `--.*$` failed to strip this comment and the
  // scanner read TRUNCATE out of the prose describing the fix.
  const crlf = '-- closing the TRUNCATE hole on app_settings.\r\nrevoke all on table public.app_settings from authenticated;\r\n';
  const result = scan(crlf);
  assert.equal(result.safe, true, JSON.stringify(result));

  // And the same content with real danger still fails on CRLF.
  const crlfBad = '-- a harmless note\r\ndrop table public.commission_rows;\r\n';
  assert.equal(scan(crlfBad).safe, false);
});

test('writes inside a function body are runtime behaviour, not migration DML', async () => {
  const { scan } = await loadScanner();
  const sql = [
    'create or replace function public.f() returns void language plpgsql as $$',
    'begin',
    "  insert into public.audit_logs (action) values ('x');",
    '  update public.commission_rows set paid = 0;',
    'end;',
    '$$;',
  ].join('\n');
  assert.equal(scan(sql).safe, true);
});

test('a top-level write to a live table is rejected', async () => {
  const { scan } = await loadScanner();
  const cases = [
    "insert into public.commission_rows (name) values ('x');",
    'update public.installation_payment_history set amount = 0;',
    'delete from public.installation_subscribers;',
  ];
  cases.forEach((sql) => {
    const result = scan(sql);
    assert.equal(result.safe, false, `should reject: ${sql}`);
    assert.equal(result.topLevelWritesToLiveTables.length, 1);
  });
});

test('block comments are stripped, including multi-line ones', async () => {
  const { scan } = await loadScanner();
  const sql = [
    '/* this migration explains why',
    '   drop table public.commission_rows was NOT used',
    '   and why truncate is dangerous */',
    'select 1;',
  ].join('\n');
  assert.equal(scan(sql).safe, true, JSON.stringify(scan(sql)));
});

test('schema work on a live table is allowed; dropping its data is not', async () => {
  const { scan } = await loadScanner();
  // Additive schema and security changes are how migrations legitimately evolve
  // a live table.
  assert.equal(scan('alter table public.installation_batches add column if not exists x text;').safe, true);
  assert.equal(scan('alter table public.commission_rows enable row level security;').safe, true);
  assert.equal(scan('alter table public.commission_rows add constraint c check (paid >= 0);').safe, true);
  // Removing the data is not.
  assert.equal(scan('alter table public.commission_rows drop column paid;').safe, false);
});

test('a trigger definition is not mistaken for an UPDATE statement', async () => {
  const { scan } = await loadScanner();
  // `before update on public.commission_rows` contains the word update but
  // writes nothing.
  const sql = [
    'create trigger trg_x',
    'before update on public.commission_rows',
    'for each row execute function public.set_updated_at();',
  ].join('\n');
  assert.equal(scan(sql).safe, true, JSON.stringify(scan(sql)));
});
