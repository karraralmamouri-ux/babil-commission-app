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
  // إدارة الحسابات انتقلت إلى شاشة المستخدمين. والحكمان اللذان يحرسهما هذا
  // الاختبار لم يسقطا: تغيير الدور لا يقع بمجرّد تحريك قائمة، وكلمة المرور
  // تُؤكَّد قبل تعيينها — حقلٌ لا يُعرض محتواه يُقفل الحساب بخطأٍ مطبعيّ
  // واحد لا يظهر إلا عند أوّل محاولة دخول.
  const users = require('node:fs').readFileSync(
    require('node:path').join(__dirname, '..', 'src/features/system/users.ts'), 'utf8');

  // الحفظ بزرٍّ صريح وسببٍ مكتوب، لا بتغيير قائمة.
  assert.match(users, /id="upSave"/);
  assert.match(users, /السبب إلزامي/);
  assert.doesNotMatch(users, /onchange=/);

  // والتأكيد مشروط في الموضعين: الإنشاء والتعيين.
  assert.match(users, /id="nuPass2"/);
  assert.match(users, /id="upPass2"/);
  const mismatches = users.match(/التأكيد لا يطابق كلمة المرور/g) || [];
  assert.equal(mismatches.length, 2, 'أحد مساري كلمة المرور بلا تأكيد');

  // وكلمة المرور لا تبقى في الحقل بعد الإرسال، نجح أو أخفق.
  assert.match(users, /confirmPass\.value = ''/);
  assert.match(users, /passConfirm\.value = ''/);

  // والتصفية بالدور والحالة باقية.
  assert.match(users, /key: 'role'/);
  assert.match(users, /key: 'active'/);
});
