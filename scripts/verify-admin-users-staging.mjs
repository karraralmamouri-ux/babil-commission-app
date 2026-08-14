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

let assertions = 0;
const createdIds = new Set();
const suffix = `${Date.now()}-${crypto.randomBytes(3).toString('hex')}`;
const initialPassword = `Stage-${crypto.randomBytes(8).toString('hex')}!`;
const changedPassword = `Changed-${crypto.randomBytes(8).toString('hex')}!`;
let fixtureSequence = 0;

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
  return request(path, {
    ...options,
    apiKey: SUPABASE_SERVICE_ROLE_KEY,
    token: SUPABASE_SERVICE_ROLE_KEY,
  });
}

async function createFixture(role, active = true) {
  fixtureSequence += 1;
  const email = `babil.qa.${role}.${fixtureSequence}.${suffix}@gmail.com`;
  const created = await serviceRequest('/auth/v1/admin/users', {
    method: 'POST',
    body: { email, password: initialPassword, email_confirm: true, user_metadata: { full_name: `Codex ${role}` } },
  });
  assert.ok(
    created.response.ok,
    `service can create ${role} fixture ${email} (${created.response.status}: ${created.data?.msg || created.data?.message || created.data?.error || 'unknown error'})`,
  );
  const id = created.data?.id || created.data?.user?.id;
  assert.ok(id, `${role} fixture has an id`);
  createdIds.add(id);

  const profile = await serviceRequest('/rest/v1/profiles?on_conflict=id', {
    method: 'POST',
    body: { id, full_name: `Codex ${role}`, email, role, is_active: active },
    prefer: 'resolution=merge-duplicates,return=minimal',
  });
  assert.ok(profile.response.ok, `service can configure ${role} profile`);
  return { id, email, password: initialPassword };
}

async function signIn(email, password) {
  const result = await request('/auth/v1/token?grant_type=password', {
    method: 'POST',
    body: { email, password },
  });
  return { ...result, token: result.data?.access_token };
}

function callAdminUsers(token, body) {
  return request('/functions/v1/admin-users', { method: 'POST', token, body });
}

async function auditActions(entityId) {
  const audit = await serviceRequest(`/rest/v1/audit_logs?entity_id=eq.${entityId}&select=action&order=created_at.asc`);
  assert.ok(audit.response.ok, 'audit rows are readable by the service role');
  return (audit.data || []).map((row) => row.action);
}

try {
  const admin = await createFixture('admin');
  const accountant = await createFixture('accountant');
  const inactiveAdmin = await createFixture('admin', false);

  const adminSession = await signIn(admin.email, admin.password);
  const accountantSession = await signIn(accountant.email, accountant.password);
  const inactiveSession = await signIn(inactiveAdmin.email, inactiveAdmin.password);
  pass(adminSession.response.ok && adminSession.token, 'temporary admin can sign in');
  pass(accountantSession.response.ok && accountantSession.token, 'temporary accountant can sign in');
  pass(inactiveSession.response.ok && inactiveSession.token, 'inactive admin can authenticate before the profile gate');

  const noToken = await callAdminUsers(null, { action: 'list' });
  pass(noToken.response.status === 401, 'admin-users rejects requests without a bearer token');

  const accountantDenied = await callAdminUsers(accountantSession.token, { action: 'list' });
  pass(accountantDenied.response.status === 403, 'admin-users rejects a non-admin role');

  const inactiveDenied = await callAdminUsers(inactiveSession.token, { action: 'list' });
  pass(inactiveDenied.response.status === 403, 'admin-users rejects an inactive admin');

  const adminList = await callAdminUsers(adminSession.token, { action: 'list' });
  pass(adminList.response.ok && Array.isArray(adminList.data?.users), 'active admin can list users');

  const selfRole = await callAdminUsers(adminSession.token, { action: 'update', id: admin.id, role: 'viewer' });
  pass(selfRole.response.status === 400, 'admin cannot remove their own admin role');
  const selfDisable = await callAdminUsers(adminSession.token, { action: 'update', id: admin.id, is_active: false });
  pass(selfDisable.response.status === 400, 'admin cannot disable their own account');
  const combined = await callAdminUsers(adminSession.token, { action: 'update', id: accountant.id, role: 'viewer', password: changedPassword });
  pass(combined.response.status === 400, 'profile and password mutations must be separate requests');

  const targetEmail = `babil.qa.managed.${suffix}@gmail.com`;
  const created = await callAdminUsers(adminSession.token, {
    action: 'create',
    full_name: 'Codex Managed User',
    email: targetEmail,
    password: initialPassword,
    role: 'viewer',
  });
  pass(created.response.status === 201 && created.data?.user?.id, 'admin can create a managed user');
  const targetId = created.data.user.id;
  createdIds.add(targetId);

  const roleUpdate = await callAdminUsers(adminSession.token, { action: 'update', id: targetId, role: 'accountant' });
  pass(roleUpdate.response.ok, 'admin can change a managed user role');

  const passwordUpdate = await callAdminUsers(adminSession.token, { action: 'update', id: targetId, password: changedPassword });
  pass(passwordUpdate.response.ok, 'admin can change a managed user password separately');
  const changedSession = await signIn(targetEmail, changedPassword);
  pass(changedSession.response.ok && changedSession.token, 'managed user can sign in with the new password');

  const disable = await callAdminUsers(adminSession.token, { action: 'update', id: targetId, is_active: false });
  pass(disable.response.ok, 'admin can disable a managed user');
  const disabledDenied = await callAdminUsers(changedSession.token, { action: 'list' });
  pass(disabledDenied.response.status === 403, 'disabled managed user cannot call admin-users');

  const actions = await auditActions(targetId);
  for (const action of ['user.created', 'user.permissions.updated', 'user.password.update.requested', 'user.password.updated']) {
    pass(actions.includes(action), `audit contains ${action}`);
  }

  console.log(JSON.stringify({ passed: true, projectRef: SUPABASE_STAGING_PROJECT_REF, assertions }));
} finally {
  for (const id of createdIds) {
    await serviceRequest(`/rest/v1/audit_logs?entity_id=eq.${id}`, { method: 'DELETE' });
    await serviceRequest(`/rest/v1/audit_logs?actor_id=eq.${id}`, { method: 'DELETE' });
  }
  for (const id of createdIds) {
    await serviceRequest(`/auth/v1/admin/users/${id}`, { method: 'DELETE' });
  }
}
