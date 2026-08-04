import fs from 'node:fs/promises';
import assert from 'node:assert/strict';

const {
  SUPABASE_URL,
  SUPABASE_ANON_KEY,
  SUPABASE_SERVICE_ROLE_KEY,
  SUPABASE_STAGING_PROJECT_REF,
  SUPABASE_PRODUCTION_PROJECT_REF,
  SUPABASE_STAGING_ACCOUNTS_FILE,
  ALLOW_STAGING_TESTS,
} = process.env;

for (const [name, value] of Object.entries({
  SUPABASE_URL,
  SUPABASE_ANON_KEY,
  SUPABASE_SERVICE_ROLE_KEY,
  SUPABASE_STAGING_PROJECT_REF,
  SUPABASE_PRODUCTION_PROJECT_REF,
  SUPABASE_STAGING_ACCOUNTS_FILE,
})) {
  assert.ok(value, `${name} is required`);
}

assert.equal(ALLOW_STAGING_TESTS, 'true', 'ALLOW_STAGING_TESTS=true is required');
assert.equal(
  SUPABASE_URL,
  `https://${SUPABASE_STAGING_PROJECT_REF}.supabase.co`,
  'SUPABASE_URL must exactly match the staging project ref'
);
assert.notEqual(
  SUPABASE_STAGING_PROJECT_REF,
  SUPABASE_PRODUCTION_PROJECT_REF,
  'staging tests refuse the production project'
);

const accounts = JSON.parse(
  await fs.readFile(SUPABASE_STAGING_ACCOUNTS_FILE, 'utf8')
);
const expectedRoles = ['admin', 'accountant', 'monitor', 'viewer'];
assert.deepEqual(
  accounts.map((account) => account.role).sort(),
  [...expectedRoles].sort(),
  'the ignored accounts file must contain all four roles'
);

let assertions = 0;
const fixtureMonthKey = '12/2099';

async function request(path, {
  method = 'GET',
  token,
  apiKey = SUPABASE_ANON_KEY,
  body,
  prefer,
} = {}) {
  const response = await fetch(`${SUPABASE_URL}${path}`, {
    method,
    headers: {
      apikey: apiKey,
      Authorization: `Bearer ${token ?? apiKey}`,
      ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
      ...(prefer ? { Prefer: prefer } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  let data = null;
  if (text) {
    try {
      data = JSON.parse(text);
    } catch {
      data = text;
    }
  }
  return { response, data };
}

function pass(condition, message) {
  assert.ok(condition, message);
  assertions += 1;
}

async function signIn(account) {
  const result = await request('/auth/v1/token?grant_type=password', {
    method: 'POST',
    body: { email: account.email, password: account.password },
  });
  pass(result.response.ok, `${account.role} can sign in to staging`);
  pass(Boolean(result.data?.access_token), `${account.role} receives an access token`);
  return result.data.access_token;
}

async function serviceDelete(path) {
  return request(path, {
    method: 'DELETE',
    apiKey: SUPABASE_SERVICE_ROLE_KEY,
    token: SUPABASE_SERVICE_ROLE_KEY,
  });
}

async function serviceRequest(path, options = {}) {
  return request(path, {
    ...options,
    apiKey: SUPABASE_SERVICE_ROLE_KEY,
    token: SUPABASE_SERVICE_ROLE_KEY,
  });
}

const sessions = new Map();
let fixtureMonthId = null;
let fixtureRowId = null;
const paymentRequestId = '00000000-0000-4000-8000-000000000001';
const updateRequestId = '00000000-0000-4000-8000-000000000002';

try {
  await serviceDelete(`/rest/v1/audit_logs?month_key=eq.${encodeURIComponent(fixtureMonthKey)}`);
  await serviceDelete(`/rest/v1/commission_months?month_key=eq.${encodeURIComponent(fixtureMonthKey)}`);

  for (const account of accounts) {
    sessions.set(account.role, await signIn(account));
  }

  const adminUsersList = await request('/functions/v1/admin-users', {
    method: 'POST',
    token: sessions.get('admin'),
    body: { action: 'list' },
  });
  pass(adminUsersList.response.ok, 'admin can call the admin-users Edge Function');
  pass(adminUsersList.data?.users?.length === 4, 'admin-users lists all staging profiles');

  const deniedAdminUsersList = await request('/functions/v1/admin-users', {
    method: 'POST',
    token: sessions.get('accountant'),
    body: { action: 'list' },
  });
  pass(
    deniedAdminUsersList.response.status === 403,
    'admin-users rejects a signed-in non-admin'
  );

  for (const account of accounts) {
    const token = sessions.get(account.role);
    const profiles = await request('/rest/v1/profiles?select=id,role&order=role', { token });
    pass(profiles.response.ok, `${account.role} can read allowed profiles`);
    const expectedCount = account.role === 'admin' ? 4 : 1;
    pass(profiles.data.length === expectedCount, `${account.role} sees ${expectedCount} profile(s)`);
    if (account.role !== 'admin') {
      pass(profiles.data[0]?.id === account.id, `${account.role} sees only its own profile`);
    }

    const roleRpc = await request('/rest/v1/rpc/current_app_role', {
      method: 'POST',
      token,
      body: {},
    });
    pass(roleRpc.response.ok, `${account.role} can call current_app_role`);
    pass(roleRpc.data === account.role, `${account.role} helper returns the correct role`);

    const escalation = await request(`/rest/v1/profiles?id=eq.${account.id}`, {
      method: 'PATCH',
      token,
      body: { role: 'admin' },
      prefer: 'return=representation',
    });
    pass(!escalation.response.ok, `${account.role} cannot mutate profiles directly`);
  }

  const admin = accounts.find((account) => account.role === 'admin');
  const adminToken = sessions.get('admin');
  const directMonth = await request('/rest/v1/commission_months', {
    method: 'POST',
    token: adminToken,
    body: {
      month_key: fixtureMonthKey,
      tiers: [],
      created_by: admin.id,
      updated_by: admin.id,
    },
    prefer: 'return=representation',
  });
  pass(!directMonth.response.ok, 'admin cannot bypass the audited RPCs with a direct month insert');

  const month = await serviceRequest('/rest/v1/commission_months', {
    method: 'POST',
    body: {
      month_key: fixtureMonthKey,
      tiers: [
        { key: 't1', min: 0, max: 200, p35: 4000, p45: 5500, p65: 8000 },
        { key: 't2', min: 201, max: 400, p35: 4750, p45: 6000, p65: 9000 },
        { key: 't3', min: 401, max: null, p35: 6000, p45: 8000, p65: 11500 },
      ],
      created_by: admin.id,
      updated_by: admin.id,
    },
    prefer: 'return=representation',
  });
  pass(month.response.ok && month.data?.length === 1, 'service fixture can create a staging month');
  fixtureMonthId = month.data[0].id;

  const row = await serviceRequest('/rest/v1/commission_rows', {
    method: 'POST',
    body: {
      month_id: fixtureMonthId,
      zone: 'old',
      name: 'STAGING RLS TEST',
      p35: 1,
      p45: 0,
      p65: 0,
      custom_tier: 'auto',
      paid: 0,
      created_by: admin.id,
      updated_by: admin.id,
    },
    prefer: 'return=representation',
  });
  pass(row.response.ok && row.data?.length === 1, 'service fixture can create a staging commission row');
  fixtureRowId = row.data[0].id;
  const originalUpdatedAt = row.data[0].updated_at;

  for (const account of accounts) {
    const visible = await request(
      `/rest/v1/commission_rows?id=eq.${fixtureRowId}&select=id,p35,paid`,
      { token: sessions.get(account.role) }
    );
    pass(visible.response.ok && visible.data?.length === 1, `${account.role} can read commission rows`);
  }

  const accountantToken = sessions.get('accountant');
  const directPayment = await request(`/rest/v1/commission_rows?id=eq.${fixtureRowId}`, {
    method: 'PATCH',
    token: accountantToken,
    body: { paid: 1 },
    prefer: 'return=representation',
  });
  pass(!directPayment.response.ok, 'accountant cannot bypass the payment RPC with a direct update');

  const payment = await request('/rest/v1/rpc/record_commission_payment', {
    method: 'POST',
    token: accountantToken,
    body: {
      p_row_id: fixtureRowId,
      p_expected_updated_at: originalUpdatedAt,
      p_paid: 4000,
      p_payment_date: '2099-12-15',
      p_request_id: paymentRequestId,
    },
  });
  pass(
    payment.response.ok && payment.data?.row?.paid === 4000 && payment.data?.replayed === false,
    'accountant records a payment through the atomic RPC'
  );

  const replay = await request('/rest/v1/rpc/record_commission_payment', {
    method: 'POST',
    token: accountantToken,
    body: {
      p_row_id: fixtureRowId,
      p_expected_updated_at: originalUpdatedAt,
      p_paid: 4000,
      p_payment_date: '2099-12-15',
      p_request_id: paymentRequestId,
    },
  });
  pass(
    replay.response.ok && replay.data?.replayed === true,
    'replaying the same payment request is idempotent'
  );

  const overpayment = await request('/rest/v1/rpc/record_commission_payment', {
    method: 'POST',
    token: accountantToken,
    body: {
      p_row_id: fixtureRowId,
      p_expected_updated_at: payment.data.row.updated_at,
      p_paid: 4001,
      p_payment_date: '2099-12-15',
      p_request_id: '00000000-0000-4000-8000-000000000003',
    },
  });
  pass(!overpayment.response.ok, 'payment RPC rejects payment above the server-calculated due');

  const accountantQuantityChange = await request('/rest/v1/rpc/update_commission_row', {
    method: 'POST',
    token: accountantToken,
    body: {
      p_row_id: fixtureRowId,
      p_expected_updated_at: payment.data.row.updated_at,
      p_name: 'STAGING RLS TEST',
      p_p35: 2,
      p_p45: 0,
      p_p65: 0,
      p_custom_tier: 'auto',
      p_request_id: '00000000-0000-4000-8000-000000000004',
    },
  });
  pass(!accountantQuantityChange.response.ok, 'accountant cannot call the commission row update RPC');

  const quantityChange = await request('/rest/v1/rpc/update_commission_row', {
    method: 'POST',
    token: adminToken,
    body: {
      p_row_id: fixtureRowId,
      p_expected_updated_at: payment.data.row.updated_at,
      p_name: 'STAGING RLS TEST',
      p_p35: 2,
      p_p45: 0,
      p_p65: 0,
      p_custom_tier: 'auto',
      p_request_id: updateRequestId,
    },
  });
  pass(
    quantityChange.response.ok && quantityChange.data?.row?.p35 === 2,
    'admin updates commission quantities through the atomic RPC'
  );

  const staleUpdate = await request('/rest/v1/rpc/update_commission_row', {
    method: 'POST',
    token: adminToken,
    body: {
      p_row_id: fixtureRowId,
      p_expected_updated_at: originalUpdatedAt,
      p_name: 'STALE UPDATE MUST FAIL',
      p_p35: 3,
      p_p45: 0,
      p_p65: 0,
      p_custom_tier: 'auto',
      p_request_id: '00000000-0000-4000-8000-000000000005',
    },
  });
  pass(!staleUpdate.response.ok, 'optimistic concurrency rejects a stale commission update');

  const belowPaidUpdate = await request('/rest/v1/rpc/update_commission_row', {
    method: 'POST',
    token: adminToken,
    body: {
      p_row_id: fixtureRowId,
      p_expected_updated_at: quantityChange.data.row.updated_at,
      p_name: 'STAGING RLS TEST',
      p_p35: 0,
      p_p45: 0,
      p_p65: 0,
      p_custom_tier: 'auto',
      p_request_id: '00000000-0000-4000-8000-000000000008',
    },
  });
  pass(
    !belowPaidUpdate.response.ok,
    'commission update cannot reduce amount due below the recorded payment'
  );

  const accountantInsert = await request('/rest/v1/commission_rows', {
    method: 'POST',
    token: accountantToken,
    body: {
      month_id: fixtureMonthId,
      zone: 'new',
      name: 'ACCOUNTANT INSERT MUST FAIL',
    },
  });
  pass(!accountantInsert.response.ok, 'accountant cannot insert commission rows');

  const negativeQuantity = await serviceRequest('/rest/v1/commission_rows', {
    method: 'POST',
    body: {
      month_id: fixtureMonthId,
      zone: 'new',
      name: 'NEGATIVE QUANTITY MUST FAIL',
      p35: -1,
      created_by: admin.id,
      updated_by: admin.id,
    },
  });
  pass(!negativeQuantity.response.ok, 'database rejects a negative quantity');

  const negativePayment = await serviceRequest(`/rest/v1/commission_rows?id=eq.${fixtureRowId}`, {
    method: 'PATCH',
    body: { paid: -1 },
    prefer: 'return=representation',
  });
  pass(!negativePayment.response.ok, 'database rejects a negative payment');

  for (const role of ['monitor', 'viewer']) {
    const attemptedPayment = await request('/rest/v1/rpc/record_commission_payment', {
      method: 'POST',
      token: sessions.get(role),
      body: {
        p_row_id: fixtureRowId,
        p_expected_updated_at: quantityChange.data.row.updated_at,
        p_paid: 1,
        p_payment_date: '2099-12-16',
        p_request_id: role === 'monitor'
          ? '00000000-0000-4000-8000-000000000006'
          : '00000000-0000-4000-8000-000000000007',
      },
    });
    pass(!attemptedPayment.response.ok, `${role} cannot call the payment RPC`);
  }

  const audit = await request(
    `/rest/v1/audit_logs?month_key=eq.${encodeURIComponent(fixtureMonthKey)}&select=action,request_id&order=created_at`,
    { token: adminToken }
  );
  pass(
    audit.response.ok && audit.data?.length === 2,
    'successful financial RPCs create exactly one audit event per request'
  );

  const unchanged = await request(
    `/rest/v1/commission_rows?id=eq.${fixtureRowId}&select=p35,paid`,
    { token: adminToken }
  );
  pass(
    unchanged.data?.[0]?.p35 === 2 && unchanged.data?.[0]?.paid === 4000,
    'denied writes leave the staging row unchanged'
  );

  console.log(JSON.stringify({
    passed: true,
    projectRef: SUPABASE_STAGING_PROJECT_REF,
    roles: expectedRoles,
    assertions,
  }));
} finally {
  await serviceDelete(`/rest/v1/audit_logs?month_key=eq.${encodeURIComponent(fixtureMonthKey)}`);
  if (fixtureRowId) {
    await serviceDelete(`/rest/v1/commission_rows?id=eq.${fixtureRowId}`);
  }
  await serviceDelete(`/rest/v1/commission_months?month_key=eq.${encodeURIComponent(fixtureMonthKey)}`);
}
