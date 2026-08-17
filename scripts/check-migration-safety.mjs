#!/usr/bin/env node
// Refuses to let a migration reach a real database if it would destroy data or
// silently rewrite production rows.
//
// Usage:  node scripts/check-migration-safety.mjs <file.sql> [more.sql ...]
//         node scripts/check-migration-safety.mjs            (scans all migrations)
//
// Exit 0 = safe. Exit 1 = at least one finding.
//
// Three things this has to get right, each learned the hard way:
//
//   CRLF        `.` does not match \r in JavaScript, so `--.*$` silently fails
//               to strip a comment on a CRLF file and the scanner then reads the
//               prose as code. Carriage returns are removed first.
//
//   function    A financial RPC legitimately contains `insert into audit_logs`.
//   bodies      That is runtime behaviour, not migration-time DML, so anything
//               between $$ markers is skipped.
//
//   drop kind   `drop policy if exists x` followed by `create policy x` is the
//               ordinary idempotent re-creation pattern and destroys nothing.
//               `drop table` destroys everything. Treating them alike produced
//               a scanner nobody could use, which is worse than no scanner.

import { readFileSync, readdirSync } from 'node:fs';
import { join, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const MIGRATIONS_DIR = join(HERE, '..', 'supabase', 'migrations');

/* Tables that already hold production data. A migration must not write to them
   at the top level; changing live financial rows is a data operation, not a
   schema change, and belongs in a reviewed RPC call instead. */
const LIVE_TABLES = /public\.(commission_months|commission_rows|commission_agents|commission_audit_logs|profiles|audit_logs|app_settings|installation_entitlements|installation_batches|installation_payments|installation_subscribers|installation_subscriber_state|installation_payment_history)\b/i;

/* Anchored at the start of the statement. Unanchored, `update` also matches the
   `before update on public.commission_rows` clause of a CREATE TRIGGER, and
   `alter table` matches `enable row level security` — both ordinary schema work
   rather than data writes. Only INSERT / UPDATE / DELETE against a live table is
   a data operation; removing a column is covered by DESTRUCTIVE instead. */
const TOP_LEVEL_DML = new RegExp(
  String.raw`^(insert\s+into|update|delete\s+from)\s+[^;]*?${LIVE_TABLES.source}`,
  'i',
);

/* Destroys data or structure that holds data. Never acceptable in a migration
   here without an explicit, separately approved decision. */
const DESTRUCTIVE = [
  /\bdrop\s+table\b/i,
  /\bdrop\s+schema\b/i,
  /\bdrop\s+database\b/i,
  /\bdrop\s+(materialized\s+)?view\b/i,
  /\balter\s+table\s+[^;]*\bdrop\s+column\b/i,
  /\btruncate\b/i,
];

/* Re-creation of a non-data object. `if exists` is required: without it the
   statement is a one-way drop rather than an idempotent replace. */
const IDEMPOTENT_OBJECT_DROP =
  /\bdrop\s+(policy|trigger|constraint|index|function|procedure|rule|type)\s+if\s+exists\b/i;

/* `alter table ... drop constraint if exists` reads as an alter, not a drop. */
const IDEMPOTENT_CONSTRAINT_DROP =
  /\balter\s+table\s+[^;]*\bdrop\s+constraint\s+if\s+exists\b/i;

export function scan(sql, name = '<input>') {
  const findings = { file: name, topLevelWritesToLiveTables: [], destructiveStatements: [] };

  // Carriage returns first — see the header note.
  const lines = sql.split('\n').map((line) => line.replace(/\r$/, ''));

  let inBody = false;
  let inBlockComment = false;

  lines.forEach((line, index) => {
    const lineNo = index + 1;
    let text = line;

    // Block comments may span lines; strip them before anything else.
    if (inBlockComment) {
      const end = text.indexOf('*/');
      if (end === -1) return;
      text = text.slice(end + 2);
      inBlockComment = false;
    }
    const blockStart = text.indexOf('/*');
    if (blockStart !== -1 && !text.slice(blockStart).includes('*/')) {
      text = text.slice(0, blockStart);
      inBlockComment = true;
    }

    const dollars = (text.match(/\$\$/g) || []).length;
    const code = text.replace(/--.*$/, '').trim();

    if (code && !inBody) {
      if (TOP_LEVEL_DML.test(code)) {
        findings.topLevelWritesToLiveTables.push(`${lineNo}: ${code.slice(0, 90)}`);
      }
      const isIdempotent =
        IDEMPOTENT_OBJECT_DROP.test(code) || IDEMPOTENT_CONSTRAINT_DROP.test(code);
      if (!isIdempotent && DESTRUCTIVE.some((pattern) => pattern.test(code))) {
        findings.destructiveStatements.push(`${lineNo}: ${code.slice(0, 90)}`);
      }
    }

    if (dollars % 2 === 1) inBody = !inBody;
  });

  findings.safe =
    findings.topLevelWritesToLiveTables.length === 0 &&
    findings.destructiveStatements.length === 0;
  return findings;
}

function main(argv) {
  const targets = argv.length
    ? argv
    : readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
        .map((f) => join(MIGRATIONS_DIR, f));

  let failed = 0;
  for (const file of targets) {
    const result = scan(readFileSync(file, 'utf8'), basename(file));
    if (!result.safe) {
      failed += 1;
      console.error(JSON.stringify(result, null, 1));
    } else {
      console.log(`safe  ${result.file}`);
    }
  }
  if (failed) console.error(`\n${failed} migration(s) flagged.`);
  return failed ? 1 : 0;
}

if (process.argv[1] && import.meta.url.endsWith(basename(process.argv[1]))) {
  process.exit(main(process.argv.slice(2)));
}
