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

const sessions = new Map();
let fixtureMonthId = null;
let fixtureRowId = null;

try {
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
  const month = await request('/rest/v1/commission_months', {
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
  pass(month.response.ok && month.data?.length === 1, 'admin can create a staging month');
  fixtureMonthId = month.data[0].id;

  const row = await request('/rest/v1/commission_rows', {
    method: 'POST',
    token: adminToken,
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
  pass(row.response.ok && row.data?.length === 1, 'admin can create a staging commission row');
  fixtureRowId = row.data[0].id;

  for (const account of accounts) {
    const visible = await request(
      `/rest/v1/commission_rows?id=eq.${fixtureRowId}&select=id,p35,paid`,
      { token: sessions.get(account.role) }
    );
    pass(visible.response.ok && visible.data?.length === 1, `${account.role} can read commission rows`);
  }

  const accountantToken = sessions.get('accountant');
  const payment = await request(`/rest/v1/commission_rows?id=eq.${fixtureRowId}`, {
    method: 'PATCH',
    token: accountantToken,
    body: { paid: 1 },
    prefer: 'return=representation',
  });
  pass(payment.response.ok && payment.data?.[0]?.paid === 1, 'accountant can update payment data');

  const quantityChange = await request(`/rest/v1/commission_rows?id=eq.${fixtureRowId}`, {
    method: 'PATCH',
    token: accountantToken,
    body: { p35: 999 },
    prefer: 'return=representation',
  });
  pass(!quantityChange.response.ok, 'accountant cannot update commission quantities');

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

  const negativeQuantity = await request('/rest/v1/commission_rows', {
    method: 'POST',
    token: adminToken,
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

  const negativePayment = await request(`/rest/v1/commission_rows?id=eq.${fixtureRowId}`, {
    method: 'PATCH',
    token: accountantToken,
    body: { paid: -1 },
    prefer: 'return=representation',
  });
  pass(!negativePayment.response.ok, 'database rejects a negative payment');

  for (const role of ['monitor', 'viewer']) {
    const attemptedPayment = await request(`/rest/v1/commission_rows?id=eq.${fixtureRowId}`, {
      method: 'PATCH',
      token: sessions.get(role),
      body: { paid: 999 },
      prefer: 'return=representation',
    });
    pass(
      !attemptedPayment.response.ok || attemptedPayment.data?.length === 0,
      `${role} cannot update commission rows`
    );
  }

  const unchanged = await request(
    `/rest/v1/commission_rows?id=eq.${fixtureRowId}&select=p35,paid`,
    { token: adminToken }
  );
  pass(
    unchanged.data?.[0]?.p35 === 1 && unchanged.data?.[0]?.paid === 1,
    'denied writes leave the staging row unchanged'
  );

  console.log(JSON.stringify({
    passed: true,
    projectRef: SUPABASE_STAGING_PROJECT_REF,
    roles: expectedRoles,
    assertions,
  }));
} finally {
  if (fixtureRowId) {
    await serviceDelete(`/rest/v1/commission_rows?id=eq.${fixtureRowId}`);
  }
  await serviceDelete(`/rest/v1/commission_months?month_key=eq.${encodeURIComponent(fixtureMonthKey)}`);
}
