const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

// The commission tier basis is a LEGACY UNVERIFIED CLIENT INPUT until Phase 8.
//
// `publish_commission_month` receives `tier_basis_qty` from the browser. It
// checks that the applied tier is consistent with that basis and that the basis
// is not below the row's own quantity — but it never derives the basis itself.
//
// The approved architecture says the authoritative basis must eventually be
// UNIQUE ACTIVE USERS, computed server-side from persisted SaaS user state that
// this system does not store yet (docs/engineering/risk-and-open-decisions.md
// R-01 and D-03).
//
// So Phase 0a deliberately does NOT "fix" this by making the server recompute
// p35 + p45 + p65: that would harden the wrong business rule and make a legacy
// approximation look authoritative. What Phase 0a does instead is pin the
// boundary, so the limitation stays visible and no future change can quietly
// promote a client value into a trusted server fact.

const ROOT = path.join(__dirname, '..');
const PUBLISH_MIGRATION = path.join(
  ROOT, 'supabase', 'migrations', '20260815113000_add_commission_source_breakdown.sql',
);

const publishSql = fs.readFileSync(PUBLISH_MIGRATION, 'utf8');
const appHtml = fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8');

test('the tier basis still originates from the client payload', () => {
  // Pinning the current truth. If this ever stops matching, the basis has become
  // server-derived and R-01 can be closed — which is a Phase 8 decision, not an
  // accident.
  assert.match(
    publishSql,
    /v_tier_basis\s*:=\s*coalesce\(\(v_item ->> 'tier_basis_qty'\)::integer/,
    'tier_basis_qty is read from the client payload',
  );
});

test('the server rejects a basis below the row it belongs to', () => {
  // The one guard that does exist: a basis cannot be smaller than the row's own
  // quantity. It bounds the value from below only.
  assert.match(publishSql, /v_tier_basis < v_p35 \+ v_p45 \+ v_p65/);
});

test('the applied tier is verified against the basis, not accepted blindly', () => {
  assert.match(publishSql, /resolve_commission_tier_key\(p_tiers, v_tier_basis\)/);
  assert.match(publishSql, /Applied tier does not match server calculation/);
});

test('nothing claims the basis is server-derived', () => {
  // Wording matters here: a comment calling this value "verified" or "derived"
  // would mislead the next reader into trusting it.
  const claims = [
    /server[- ]derived tier[_ ]basis/i,
    /authoritative tier[_ ]basis/i,
    /verified tier[_ ]basis/i,
  ];
  claims.forEach((pattern) => {
    assert.ok(!pattern.test(publishSql), `migration must not claim ${pattern}`);
    assert.ok(!pattern.test(appHtml), `index.html must not claim ${pattern}`);
  });
});

test('the limitation is recorded where the value originates', () => {
  // The note lives beside rowsForCentralPublish rather than inside the published
  // migration: 20260815113000 is already applied to production and must not be
  // edited. The client is where tier_basis_qty is actually produced, so that is
  // where a future implementer meets it first.
  assert.match(appHtml, /LEGACY UNVERIFIED CLIENT INPUT/);
  assert.match(appHtml, /rowsForCentralPublish/);
  assert.match(appHtml, /R-01/, 'the note should point at the risk register');
});

test('the browser is not the only thing standing between a payload and a tier', () => {
  // Even though the basis is untrusted, the surrounding controls are real and
  // must not regress: role check, request id, and the source-breakdown
  // reconciliation that ties the quantities to their per-parent detail.
  assert.match(publishSql, /current_app_role\(\)/);
  assert.match(publishSql, /request_id/);
  assert.match(publishSql, /Source breakdown does not reconcile/);
});

test('Phase 0a changed no commission amount, threshold or tier rule', () => {
  // The shipped defaults are business configuration (Phase 4/8), not something
  // this phase may touch. Pinned so an accidental edit is loud.
  assert.match(appHtml, /\{key:'t1',label:'T1',min:0,max:200,p35:4000,p45:5500,p65:8000\}/);
  assert.match(appHtml, /\{key:'t2',label:'T2',min:201,max:400,p35:4750,p45:6000,p65:9000\}/);
  assert.match(appHtml, /\{key:'t3',label:'T3',min:401,max:Infinity,p35:6000,p45:8000,p65:11500\}/);
});
