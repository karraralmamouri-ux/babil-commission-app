import fs from 'node:fs';
import path from 'node:path';

// Mirror of assert-project-ref.mjs, pointing the other way. The production guard
// stays production-only; this one is the single gate for anything that touches
// staging. Neither guard ever accepts the other's target.
const EXPECTED_REF = 'unohqhxubraelqgjhxgh'; // babil-commission-staging
const FORBIDDEN_REFS = {
  fbgffpxpskjzgheheikd:
    'babil-commission-production — the live Commission database, never a test target',
  qolrsefpbvfuugwyqggu:
    'Employee Performance Dashboard (V1/Pulse) — the shared project Commission was separated FROM',
};

const refFile = path.join(process.cwd(), 'supabase', '.temp', 'project-ref');

if (!fs.existsSync(refFile)) {
  console.error(`Not linked to any Supabase project. Run: npx supabase link --project-ref ${EXPECTED_REF}`);
  process.exit(1);
}

const linkedRef = fs.readFileSync(refFile, 'utf8').trim();

if (linkedRef in FORBIDDEN_REFS) {
  console.error(
    `REFUSING: this repo is linked to ${linkedRef} (${FORBIDDEN_REFS[linkedRef]}).\n` +
    `Staging tooling must never run against production or the Employee project. Re-link with:\n` +
    `  npx supabase link --project-ref ${EXPECTED_REF}`
  );
  process.exit(1);
}

if (linkedRef !== EXPECTED_REF) {
  console.error(
    `REFUSING: linked project ref "${linkedRef}" does not match the expected Commission staging ` +
    `project "${EXPECTED_REF}". Re-link before running any staging command.`
  );
  process.exit(1);
}


// The linked ref is not the only channel that can aim a staging command at
// production. The verify-*-staging scripts read their target from SUPABASE_URL
// and check it against SUPABASE_STAGING_PROJECT_REF — both supplied by the same
// environment, so a single wrong value satisfies both sides of that comparison
// and the check above never sees it. Judge these by identity, not by label.
const EXPECTED_URL = `https://${EXPECTED_REF}.supabase.co`;

for (const name of ['SUPABASE_STAGING_PROJECT_REF', 'SUPABASE_URL']) {
  const value = process.env[name];
  if (!value) continue;
  const expected = name === 'SUPABASE_URL' ? EXPECTED_URL : EXPECTED_REF;
  if (value.trim() !== expected) {
    console.error(
      `REFUSING: ${name}="${value}" is not the Commission staging project.\n` +
      `A staging command takes its target from this variable, so it must be exactly "${expected}".`
    );
    process.exit(1);
  }
}

// A connection string has too many legal shapes to match exactly, so this one is
// checked the other way round: it may not name a project already known to be
// forbidden. The CLI prefers it over the linked project, so a correct link is no
// defence here.
const dbUrl = process.env.SUPABASE_DB_URL;
if (dbUrl) {
  for (const [ref, why] of Object.entries(FORBIDDEN_REFS)) {
    if (dbUrl.includes(ref)) {
      console.error(
        `REFUSING: SUPABASE_DB_URL names ${ref} (${why}).\n` +
        `This overrides the linked project, so being correctly linked does not make it safe.`
      );
      process.exit(1);
    }
  }
}
console.log(`OK: linked to the expected Commission staging project (${EXPECTED_REF}).`);
