const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');

const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');

test('admin has complete account-management permissions in the interface', () => {
  assert.match(
    html,
    /admin:\{edit:true,payment:true,rates:true,users:true,delete:true,backup:true\}/,
  );
  assert.match(html, /if\(\['users','backup'\]\.includes\(p\)\)return roleAllows\(p\)/);
});

test('Supabase errors preserve the Edge Function error message', () => {
  assert.match(html, /body\?\.error_description\|\|body\?\.error\|\|/);
});

test('account management requires explicit role saves and confirmed passwords', () => {
  assert.match(html, /saveManagedUserRole\('\$\{esc\(u\.id\)\}'/);
  assert.doesNotMatch(html, /onchange="updateManagedUser\('/);
  assert.match(html, /id="passwordModal"[\s\S]*id="managedPasswordConfirm"/);
  assert.match(html, /password!==confirmation/);
  assert.match(html, /usersRoleFilter/);
  assert.match(html, /usersStatusFilter/);
});
