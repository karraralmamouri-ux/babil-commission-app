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

console.log(`OK: linked to the expected Commission staging project (${EXPECTED_REF}).`);
