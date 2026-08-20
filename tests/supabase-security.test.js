const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');

const root = path.join(__dirname, '..');

function read(relativePath) {
  return fs.readFileSync(path.join(root, relativePath), 'utf8');
}

test('deployed Edge Function sources are tracked without embedded keys', () => {
  const adminUsers = read('supabase/functions/admin-users/index.ts');
  const legacyCreateUser = read('supabase/functions/admin-create-user/index.ts');
  const combined = `${adminUsers}\n${legacyCreateUser}`;

  assert.match(adminUsers, /auth\.getUser\(token\)/);
  assert.match(adminUsers, /callerProfile\.role !== "admin"/);
  assert.match(adminUsers, /SUPABASE_SERVICE_ROLE_KEY/);
  assert.match(adminUsers, /action: "user\.created"/);
  assert.match(adminUsers, /action: "user\.password\.update\.requested"/);
  assert.match(adminUsers, /action: "user\.password\.updated"/);
  assert.doesNotMatch(adminUsers, /after_data:\s*\{\s*full_name,\s*email/);
  assert.doesNotMatch(combined, /sbp_[a-zA-Z0-9_-]{20,}/);
  assert.doesNotMatch(combined, /sb_secret_[a-zA-Z0-9_-]{20,}/);
  assert.doesNotMatch(combined, /eyJ[a-zA-Z0-9_-]{20,}\.[a-zA-Z0-9_-]{20,}/);
});

test('only one authority may write profiles.role and profiles.is_active', () => {
  // The Edge Function holds a service key, so anything it writes bypasses RLS
  // and every capability check. Role and activation are guarded elsewhere —
  // update_user_profile checks permission.manage, demands a stated reason, and
  // refuses to strip the last active administrator. While both could write the
  // field, the weaker path was the one that decided. It no longer writes it.
  const adminUsers = read('supabase/functions/admin-users/index.ts');
  const update = adminUsers.slice(adminUsers.indexOf('action === "update"'));

  assert.match(update, /PROFILE_FIELDS_MOVED_TO_RPC/);
  assert.match(update, /update_user_profile RPC/);
  assert.doesNotMatch(update, /profilePatch/);
  assert.doesNotMatch(update, /\.from\("profiles"\)\s*\.update\(/);

  // And the RPC still carries the guard the Edge Function gave up.
  const rpc = read('supabase/migrations/20260918090000_master_and_admin_writes.sql');
  const body = rpc.slice(rpc.indexOf('function public.update_user_profile'));

  assert.match(body, /require_capability\('permission\.manage'\)/);
  assert.match(body, /last active administrator/);
  assert.match(body, /A profile change must state its reason/);
});

test('the role catalogue is read from role_templates, not copied', () => {
  const adminUsers = read('supabase/functions/admin-users/index.ts');

  assert.match(adminUsers, /from\("role_templates"\)/);
  assert.doesNotMatch(adminUsers, /new Set\(\["admin", "accountant"/);
});

test('admin-users verifies bearer tokens inside the function', () => {
  const config = read('supabase/config.toml');

  assert.match(config, /\[functions\.admin-create-user\][\s\S]*?verify_jwt = false/);
  assert.match(config, /\[functions\.admin-users\][\s\S]*?verify_jwt = false/);
});

test('authorization migration removes profile self-mutation paths', () => {
  const migration = read('supabase/migrations/20260804183000_harden_authorization.sql');

  assert.match(migration, /drop policy if exists profiles_insert/);
  assert.match(migration, /drop policy if exists profiles_update/);
  assert.match(migration, /drop policy if exists profiles_delete/);
  assert.match(migration, /grant select on table public\.profiles to authenticated/);
  assert.doesNotMatch(migration, /grant[^;]*(insert|update|delete)[^;]*public\.profiles/i);
  assert.match(migration, /revoke all privileges on all tables in schema public from anon/);
  assert.match(migration, /drop policy if exists audit_delete_admin/);
});

test('inactive users cannot retain a role through helper functions', () => {
  const migration = read('supabase/migrations/20260804183000_harden_authorization.sql');
  const helpers = ['current_app_role', 'current_user_role', 'get_my_role'];

  for (const helper of helpers) {
    const functionStart = migration.indexOf(`function public.${helper}()`);
    assert.notEqual(functionStart, -1, `${helper} must be defined`);
    const functionEnd = migration.indexOf('$$;', functionStart);
    const definition = migration.slice(functionStart, functionEnd);
    assert.match(definition, /is_active = true/);
    assert.match(definition, /set search_path = ''/);
  }
});
