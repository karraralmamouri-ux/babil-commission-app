const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const REPO = path.join(__dirname, '..');
const PRODUCTION_REF = 'fbgffpxpskjzgheheikd';
const STAGING_REF = 'unohqhxubraelqgjhxgh';
const EMPLOYEE_REF = 'qolrsefpbvfuugwyqggu';

// Runs a guard against a throwaway working directory holding only a linked ref,
// so the real repo's link state is never read or modified.
function runGuard(script, linkedRef, env = {}) {
  const cwd = fs.mkdtempSync(path.join(os.tmpdir(), 'guard-'));
  try {
    if (linkedRef !== null) {
      fs.mkdirSync(path.join(cwd, 'supabase', '.temp'), { recursive: true });
      fs.writeFileSync(path.join(cwd, 'supabase', '.temp', 'project-ref'), linkedRef);
    }
    // A stray SUPABASE_* left in the developer's shell must not decide the
    // outcome of a test about SUPABASE_*.
    const childEnv = { ...process.env, ...env };
    for (const name of ['SUPABASE_URL', 'SUPABASE_STAGING_PROJECT_REF', 'SUPABASE_DB_URL']) {
      if (!(name in env)) delete childEnv[name];
    }
    const result = spawnSync(process.execPath, [path.join(REPO, 'scripts', script)], {
      cwd,
      encoding: 'utf8',
      env: childEnv,
    });
    return { code: result.status, out: `${result.stdout}${result.stderr}` };
  } finally {
    fs.rmSync(cwd, { recursive: true, force: true });
  }
}

test('the production guard accepts only the production project', () => {
  const ok = runGuard('assert-project-ref.mjs', PRODUCTION_REF);
  assert.equal(ok.code, 0);
  assert.match(ok.out, /OK/);
});

test('the staging guard accepts only the staging project', () => {
  const ok = runGuard('assert-staging-project-ref.mjs', STAGING_REF);
  assert.equal(ok.code, 0);
  assert.match(ok.out, /OK/);
});

test('swapping the two refs fails both guards', () => {
  // Production tooling pointed at staging.
  const productionAtStaging = runGuard('assert-project-ref.mjs', STAGING_REF);
  assert.notEqual(productionAtStaging.code, 0);
  assert.match(productionAtStaging.out, /REFUSING/);

  // Staging tooling pointed at production — the dangerous direction.
  const stagingAtProduction = runGuard('assert-staging-project-ref.mjs', PRODUCTION_REF);
  assert.notEqual(stagingAtProduction.code, 0);
  assert.match(stagingAtProduction.out, /REFUSING/);
  assert.match(stagingAtProduction.out, /never a test target/);
});

test('both guards refuse the Employee Performance Dashboard project', () => {
  for (const script of ['assert-project-ref.mjs', 'assert-staging-project-ref.mjs']) {
    const result = runGuard(script, EMPLOYEE_REF);
    assert.notEqual(result.code, 0, `${script} must refuse the employee project`);
    assert.match(result.out, /REFUSING/);
  }
});

test('a staging command is refused when the environment aims it at production', () => {
  // The link is correct in every case below. Only the environment is wrong —
  // which is precisely what a linked-ref check cannot see.
  const byUrl = runGuard('assert-staging-project-ref.mjs', STAGING_REF, {
    SUPABASE_URL: `https://${PRODUCTION_REF}.supabase.co`,
  });
  assert.notEqual(byUrl.code, 0, 'SUPABASE_URL aimed at production must refuse');
  assert.match(byUrl.out, /REFUSING/);

  // The label says staging; the identity is production.
  const byLabel = runGuard('assert-staging-project-ref.mjs', STAGING_REF, {
    SUPABASE_STAGING_PROJECT_REF: PRODUCTION_REF,
  });
  assert.notEqual(byLabel.code, 0, 'the production ref labelled as staging must refuse');
  assert.match(byLabel.out, /REFUSING/);

  // The CLI prefers a connection string over the linked project.
  const byDbUrl = runGuard('assert-staging-project-ref.mjs', STAGING_REF, {
    SUPABASE_DB_URL:
      `postgresql://postgres.${PRODUCTION_REF}:pw@aws-0-ap-northeast-1.pooler.supabase.com:6543/postgres`,
  });
  assert.notEqual(byDbUrl.code, 0, 'a production connection string must refuse');
  assert.match(byDbUrl.out, /REFUSING/);
});

test('a correctly aimed staging environment still passes', () => {
  const ok = runGuard('assert-staging-project-ref.mjs', STAGING_REF, {
    SUPABASE_URL: `https://${STAGING_REF}.supabase.co`,
    SUPABASE_STAGING_PROJECT_REF: STAGING_REF,
  });
  assert.equal(ok.code, 0, ok.out);
  assert.match(ok.out, /OK/);
});
test('both guards refuse an unlinked repository', () => {
  for (const script of ['assert-project-ref.mjs', 'assert-staging-project-ref.mjs']) {
    const result = runGuard(script, null);
    assert.notEqual(result.code, 0, `${script} must refuse when unlinked`);
    assert.match(result.out, /Not linked/);
  }
});

test('every environment-touching script calls its own guard first', () => {
  const pkg = JSON.parse(fs.readFileSync(path.join(REPO, 'package.json'), 'utf8'));

  for (const [name, command] of Object.entries(pkg.scripts)) {
    if (name.startsWith('guard:')) continue;
    if (/staging/i.test(name) || /staging/i.test(command)) {
      assert.match(
        command,
        /^npm run guard:staging-ref &&/,
        `"${name}" touches staging and must call the staging guard first`,
      );
    }
  }

  // The production guard stays production-only and is never repointed.
  const productionGuard = fs.readFileSync(path.join(REPO, 'scripts', 'assert-project-ref.mjs'), 'utf8');
  assert.ok(productionGuard.includes(`const EXPECTED_REF = '${PRODUCTION_REF}'`));
  assert.ok(productionGuard.includes(STAGING_REF), 'production guard must still forbid staging');
});
