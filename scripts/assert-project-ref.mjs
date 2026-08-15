import fs from 'node:fs';
import path from 'node:path';

const EXPECTED_REF = 'fbgffpxpskjzgheheikd'; // babil-commission-production, separated 2026-08-11
const FORBIDDEN_REFS = {
  qolrsefpbvfuugwyqggu: 'Employee Performance Dashboard (V1/Pulse) — shared project Commission was separated FROM, do NOT deploy Commission tooling here',
  unohqhxubraelqgjhxgh: 'babil-commission-staging — the test target, never the production one',
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
    `Production tooling must never run against staging or the Employee project. Re-link with:\n` +
    `  npx supabase link --project-ref ${EXPECTED_REF}`
  );
  process.exit(1);
}

if (linkedRef !== EXPECTED_REF) {
  console.error(
    `REFUSING: linked project ref "${linkedRef}" does not match the expected Commission production ` +
    `project "${EXPECTED_REF}". Re-link before running any migration/deploy command.`
  );
  process.exit(1);
}

console.log(`OK: linked to the expected Commission production project (${EXPECTED_REF}).`);
