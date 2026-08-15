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
function runGuard(script, linkedRef) {
  const cwd = fs.mkdtempSync(path.join(os.tmpdir(), 'guard-'));
  try {
    if (linkedRef !== null) {
      fs.mkdirSync(path.join(cwd, 'supabase', '.temp'), { recursive: true });
      fs.writeFileSync(path.join(cwd, 'supabase', '.temp', 'project-ref'), linkedRef);
    }
    const result = spawnSync(process.execPath, [path.join(REPO, 'scripts', script)], {
      cwd,
      encoding: 'utf8',
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
