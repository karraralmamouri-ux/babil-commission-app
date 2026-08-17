const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

// Supabase's default privileges grant ALL on a newly created table to the
// `authenticated` role. A migration that only says `grant select` therefore adds
// nothing and silently leaves INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER
// in place — and TRUNCATE is not filtered by row level security.
//
// This has happened twice in this repository:
//   20260815160000  installation tables  → fixed by 20260815180000
//   20260809190000  app_settings         → fixed by 20260817120000
//
// Both were invisible on local Postgres and on staging, because neither carries
// Supabase's default privileges. Only production did. So the guard has to live
// in the migration text itself rather than in a database assertion.

const MIGRATIONS_DIR = path.join(__dirname, '..', 'supabase', 'migrations');

// Migrations published before this rule existed. They are NOT rewritten —
// published migrations are immutable — and the live privileges they produced
// have been verified directly against production with aclexplode:
//
//   commission_months / commission_rows / commission_agents / commission_audit_logs
//   audit_logs / profiles / installation_*        → authenticated = SELECT only
//   app_settings                                  → had TRUNCATE; closed by 20260817120000
//
// This list must never grow. A new entry means a new migration shipped the
// exact shape that caused both incidents.
const GRANDFATHERED = new Set([
  '20260804170000_reconstructed_baseline.sql',
  '20260804183000_harden_authorization.sql',
  '20260804230000_add_atomic_financial_rpcs.sql',
  '20260809190000_add_central_month_workflow.sql',
  '20260815160000_add_installation_fees.sql',
  '20260815180000_tighten_installation_grants.sql',
  '20260816090000_add_installation_history.sql',
]);

function migrations() {
  return fs.readdirSync(MIGRATIONS_DIR)
    .filter((name) => name.endsWith('.sql'))
    .sort()
    .map((name) => ({ name, sql: fs.readFileSync(path.join(MIGRATIONS_DIR, name), 'utf8') }));
}

/* Strips line comments so prose about a grant is never mistaken for one. */
function statements(sql) {
  return sql
    .split('\n')
    .map((line) => line.replace(/--.*$/, ''))
    .join('\n');
}

const GRANT_TO_AUTHENTICATED = /grant\s+[^;]*?\s+on\s+table\s+public\.([a-z_]+)\s+to\s+[^;]*authenticated/gi;
const REVOKE_ALL = /revoke\s+all\s+on\s+table\s+public\.([a-z_]+)\s+from\s+[^;]*authenticated/gi;

test('every table granted to authenticated is first revoked in full', () => {
  const offenders = [];

  migrations().filter(({ name }) => !GRANDFATHERED.has(name)).forEach(({ name, sql }) => {
    const code = statements(sql);
    const granted = new Set([...code.matchAll(GRANT_TO_AUTHENTICATED)].map((m) => m[1].toLowerCase()));
    const revoked = new Set([...code.matchAll(REVOKE_ALL)].map((m) => m[1].toLowerCase()));

    granted.forEach((table) => {
      if (!revoked.has(table)) offenders.push(`${name} → public.${table}`);
    });
  });

  assert.deepEqual(offenders, [], [
    'These migrations grant to `authenticated` without a preceding `revoke all`,',
    "so Supabase's default ALL privileges survive — including TRUNCATE, which RLS",
    'does not filter. Use `revoke all ... from authenticated` then grant only what',
    'is needed:',
    ...offenders.map((o) => `  - ${o}`),
  ].join('\n'));
});

test('no migration revokes a verb list instead of revoking all', () => {
  // `revoke insert, update, delete` is the exact shape that left TRUNCATE behind.
  const verbList = /revoke\s+(?!all\b)[a-z, ]*?(insert|update|delete)[a-z, ]*\s+on\s+table\s+public\.([a-z_]+)\s+from\s+[^;]*authenticated/gi;
  const offenders = [];

  migrations().filter(({ name }) => !GRANDFATHERED.has(name)).forEach(({ name, sql }) => {
    [...statements(sql).matchAll(verbList)].forEach((m) => {
      offenders.push(`${name} → public.${m[2]}`);
    });
  });

  assert.deepEqual(offenders, [], [
    'A verb-list revoke leaves TRUNCATE, REFERENCES, TRIGGER and MAINTAIN in place.',
    'Revoke everything, then grant back what the browser genuinely needs:',
    ...offenders.map((o) => `  - ${o}`),
  ].join('\n'));
});

test('anon is revoked wherever authenticated is granted', () => {
  const missing = [];

  migrations().filter(({ name }) => !GRANDFATHERED.has(name)).forEach(({ name, sql }) => {
    const code = statements(sql);
    const granted = new Set([...code.matchAll(GRANT_TO_AUTHENTICATED)].map((m) => m[1].toLowerCase()));
    const anonRevoked = new Set(
      [...code.matchAll(/revoke\s+all\s+on\s+table\s+public\.([a-z_]+)\s+from\s+[^;]*anon/gi)]
        .map((m) => m[1].toLowerCase()),
    );
    granted.forEach((table) => {
      if (!anonRevoked.has(table)) missing.push(`${name} → public.${table}`);
    });
  });

  assert.deepEqual(missing, [], [
    'These tables are granted to `authenticated` but `anon` is never revoked,',
    "so Supabase's defaults may leave the table readable or worse without a session:",
    ...missing.map((o) => `  - ${o}`),
  ].join('\n'));
});

test('the guard actually catches the shape that caused both incidents', () => {
  // A guard that cannot fail is not a guard. This reproduces the historical bug
  // text and asserts each rule rejects it.
  const bad = 'create table public.thing (id uuid);\ngrant select on table public.thing to authenticated;\n';
  const code = statements(bad);

  const granted = [...code.matchAll(GRANT_TO_AUTHENTICATED)].map((m) => m[1]);
  const revoked = [...code.matchAll(REVOKE_ALL)].map((m) => m[1]);
  assert.deepEqual(granted, ['thing'], 'the grant must be detected');
  assert.deepEqual(revoked, [], 'and no revoke-all should be found');

  const verbList = /revoke\s+(?!all\b)[a-z, ]*?(insert|update|delete)[a-z, ]*\s+on\s+table\s+public\.([a-z_]+)\s+from\s+[^;]*authenticated/gi;
  const legacy = 'revoke insert, update, delete on table public.thing from authenticated;';
  assert.equal([...statements(legacy).matchAll(verbList)].length, 1,
    'the verb-list shape must be detected');
});

test('the grandfather list is closed', () => {
  // Every published migration is accounted for. A migration that exists on disk
  // but is neither grandfathered nor rule-compliant will already have failed the
  // tests above; this one catches the opposite mistake — silencing a new
  // migration by adding it to the list.
  const known = new Set(migrations().map((m) => m.name));
  const stale = [...GRANDFATHERED].filter((name) => !known.has(name));
  assert.deepEqual(stale, [], 'grandfathered entries that no longer exist');

  assert.equal(GRANDFATHERED.size, 7,
    'the grandfather list must not grow — a new migration has to follow the rule');
});

test('a comment mentioning a grant is not treated as a grant', () => {
  const commented = '-- grant select on table public.thing to authenticated;\nselect 1;\n';
  const granted = [...statements(commented).matchAll(GRANT_TO_AUTHENTICATED)];
  assert.equal(granted.length, 0);
});
