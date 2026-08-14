import assert from 'node:assert/strict';
import crypto from 'node:crypto';

const {
  SUPABASE_URL,
  SUPABASE_ANON_KEY,
  SUPABASE_SERVICE_ROLE_KEY,
  SUPABASE_STAGING_PROJECT_REF,
  SUPABASE_PRODUCTION_PROJECT_REF,
  ALLOW_STAGING_TESTS,
} = process.env;

for (const [name, value] of Object.entries({
  SUPABASE_URL,
  SUPABASE_ANON_KEY,
  SUPABASE_SERVICE_ROLE_KEY,
  SUPABASE_STAGING_PROJECT_REF,
  SUPABASE_PRODUCTION_PROJECT_REF,
})) assert.ok(value, `${name} is required`);
assert.equal(ALLOW_STAGING_TESTS, 'true', 'ALLOW_STAGING_TESTS=true is required');
assert.equal(SUPABASE_URL, `https://${SUPABASE_STAGING_PROJECT_REF}.supabase.co`);
assert.notEqual(SUPABASE_STAGING_PROJECT_REF, SUPABASE_PRODUCTION_PROJECT_REF);

const suffix = `${Date.now()}-${crypto.randomBytes(3).toString('hex')}`;
const email = `babil.qa.breakdown.${suffix}@gmail.com`;
const password = `Stage-${crypto.randomBytes(8).toString('hex')}!`;
const createdMonthIds = new Set();
const temporaryMonthKeys = [];
let userId = '';
let assertions = 0;

function pass(condition, message) {
  assert.ok(condition, message);
  assertions += 1;
}

async function request(path, { method = 'GET', token, apiKey = SUPABASE_ANON_KEY, body, prefer } = {}) {
  const response = await fetch(`${SUPABASE_URL}${path}`, {
    method,
    headers: {
      apikey: apiKey,
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
      ...(prefer ? { Prefer: prefer } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  let data = null;
  if (text) {
    try { data = JSON.parse(text); } catch { data = text; }
  }
  return { response, data };
}

function serviceRequest(path, options = {}) {
  return request(path, { ...options, apiKey: SUPABASE_SERVICE_ROLE_KEY, token: SUPABASE_SERVICE_ROLE_KEY });
}

const tiers = [
  { key: 't1', label: 'T1', min: 0, max: 200, p35: 4000, p45: 5500, p65: 8000 },
  { key: 't2', label: 'T2', min: 201, max: 400, p35: 4750, p45: 6000, p65: 9000 },
  { key: 't3', label: 'T3', min: 401, max: null, p35: 6000, p45: 8000, p65: 11500 },
];

async function unusedMonthKeys(count) {
  const candidates = [];
  for (let year = 2099; year >= 2090; year -= 1) {
    for (let month = 12; month >= 1; month -= 1) candidates.push(`${String(month).padStart(2, '0')}/${year}`);
  }
  const existing = await serviceRequest('/rest/v1/commission_months?month_key=gte.01/2090&select=month_key');
  assert.ok(existing.response.ok, 'service can inspect temporary month range');
  const used = new Set((existing.data || []).map((row) => row.month_key));
  return candidates.filter((key) => !used.has(key)).slice(0, count);
}

async function publish(token, month, rows) {
  return request('/rest/v1/rpc/publish_commission_month', {
    method: 'POST',
    token,
    body: { p_month_key: month, p_tiers: tiers, p_rows: rows, p_request_id: crypto.randomUUID() },
  });
}

try {
  const created = await serviceRequest('/auth/v1/admin/users', {
    method: 'POST',
    body: { email, password, email_confirm: true, user_metadata: { full_name: 'Breakdown QA Admin' } },
  });
  assert.ok(created.response.ok, `service can create test admin (${created.response.status})`);
  userId = created.data?.id || created.data?.user?.id;
  assert.ok(userId, 'test admin has an id');
  const profile = await serviceRequest('/rest/v1/profiles?on_conflict=id', {
    method: 'POST',
    body: { id: userId, full_name: 'Breakdown QA Admin', email, role: 'admin', is_active: true },
    prefer: 'resolution=merge-duplicates,return=minimal',
  });
  assert.ok(profile.response.ok, 'service can create test admin profile');
  const session = await request('/auth/v1/token?grant_type=password', { method: 'POST', body: { email, password } });
  assert.ok(session.response.ok && session.data?.access_token, 'test admin can sign in');
  const token = session.data.access_token;
  const [validMonth, emptyMonth, mismatchMonth] = await unusedMonthKeys(3);
  assert.ok(validMonth && emptyMonth && mismatchMonth, 'temporary month keys are available');
  temporaryMonthKeys.push(validMonth, emptyMonth, mismatchMonth);

  const baseRow = {
    zone: 'new', name: `QA-FDT-94-${suffix}`, p35: 1, p45: 1, p65: 0,
    tier_mode: 'auto', applied_tier: 't1', tier_basis_qty: 2,
    owner_name: 'QA Main Agent', source_account: null,
  };
  const validRows = [{
    ...baseRow,
    source_breakdown: [
      { parent: 'r.qa.main', fdt: 94, p35: 1, p45: 0, p65: 0 },
      { parent: 'r.qa.main.sub1', fdt: 94, p35: 0, p45: 1, p65: 0 },
    ],
  }];
  const valid = await publish(token, validMonth, validRows);
  pass(valid.response.ok, `valid parent/FDT distribution publishes (${valid.response.status})`);

  const monthResult = await serviceRequest(`/rest/v1/commission_months?month_key=eq.${encodeURIComponent(validMonth)}&select=id`);
  const monthId = monthResult.data?.[0]?.id;
  assert.ok(monthId, 'published temporary month is readable');
  createdMonthIds.add(monthId);
  const rowsResult = await serviceRequest(`/rest/v1/commission_rows?month_id=eq.${monthId}&select=id,p35,p45,p65,source_breakdown`);
  pass(rowsResult.response.ok && rowsResult.data?.length === 1, 'published row is readable');
  const stored = rowsResult.data[0];
  pass(Array.isArray(stored.source_breakdown) && stored.source_breakdown.length === 2, 'both parent shares are stored');
  pass(stored.source_breakdown.reduce((sum, item) => sum + item.p35, 0) === stored.p35, 'stored P35 shares reconcile');
  pass(stored.source_breakdown.reduce((sum, item) => sum + item.p45, 0) === stored.p45, 'stored P45 shares reconcile');

  const empty = await publish(token, emptyMonth, [{ ...baseRow, name: `${baseRow.name}-empty`, source_breakdown: [] }]);
  pass(!empty.response.ok, 'positive quantities with an empty breakdown are rejected');
  const mismatch = await publish(token, mismatchMonth, [{
    ...baseRow,
    name: `${baseRow.name}-mismatch`,
    source_breakdown: [{ parent: 'r.qa.main', fdt: 94, p35: 1, p45: 0, p65: 0 }],
  }]);
  pass(!mismatch.response.ok, 'a non-reconciling breakdown is rejected');

  const unsafeUpdate = await serviceRequest(`/rest/v1/commission_rows?id=eq.${stored.id}`, {
    method: 'PATCH',
    body: { p35: 2 },
    prefer: 'return=minimal',
  });
  pass(!unsafeUpdate.response.ok, 'the database trigger rejects a quantity change that breaks the distribution');

  const legacyInsert = await serviceRequest('/rest/v1/commission_rows', {
    method: 'POST',
    body: { month_id: monthId, zone: 'old', name: `QA-Legacy-${suffix}`, p35: 1, p45: 0, p65: 0, custom_tier: 't1', tier_mode: 't1', tier_basis_qty: 1, source_breakdown: null },
    prefer: 'return=representation',
  });
  pass(legacyInsert.response.ok, 'legacy null breakdown rows remain compatible');
  const legacyId = legacyInsert.data?.[0]?.id;
  if (legacyId) {
    const legacyPayment = await serviceRequest(`/rest/v1/commission_rows?id=eq.${legacyId}`, { method: 'PATCH', body: { paid: 100 }, prefer: 'return=minimal' });
    pass(legacyPayment.response.ok, 'legacy payment-only updates remain compatible');
  }

  console.log(JSON.stringify({ passed: true, projectRef: SUPABASE_STAGING_PROJECT_REF, assertions }));
} finally {
  for (const monthKey of temporaryMonthKeys) {
    const months = await serviceRequest(`/rest/v1/commission_months?month_key=eq.${encodeURIComponent(monthKey)}&select=id`);
    for (const month of months.data || []) createdMonthIds.add(month.id);
    await serviceRequest(`/rest/v1/audit_logs?month_key=eq.${encodeURIComponent(monthKey)}`, { method: 'DELETE' });
  }
  for (const monthId of createdMonthIds) {
    await serviceRequest(`/rest/v1/commission_months?id=eq.${monthId}`, { method: 'DELETE' });
  }
  if (userId) {
    await serviceRequest(`/rest/v1/audit_logs?actor_id=eq.${userId}`, { method: 'DELETE' });
    await serviceRequest(`/auth/v1/admin/users/${userId}`, { method: 'DELETE' });
  }
}
