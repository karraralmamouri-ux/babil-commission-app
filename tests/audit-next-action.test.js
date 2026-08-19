// سجلّ التدقيق والإجراء التالي.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');

const audit = read('src/features/audit/index.ts');
const inst = read('src/features/installation/index.ts');
const migration = read('supabase/migrations/20260905090000_audit_and_next_action.sql');

test('السجلّ محروس بقدرة التدقيق ومحجوب عن anon', () => {
  assert.match(migration, /require_capability\('audit\.view'\)/);
  assert.match(migration, /revoke execute on function public\.page_audit_logs/);
  assert.match(migration, /revoke execute on function public\.audit_facets\(\) from public, anon/);
  assert.match(audit, /capability: 'audit\.view'/);
});

test('السجلّ يُصفَّح على الخادم بالصدفة نفسها', () => {
  assert.match(migration, /return public\.page_envelope\(v_rows, v_total, v_lim, v_off\)/);
  assert.match(audit, /pageRpc<Row>\('page_audit_logs', args, view\.signal\)/);
  // والإجمالي يُحسب على المجموعة كلها لا على الصفحة.
  assert.match(migration, /select count\(\*\), coalesce\(\(/);
  assert.match(audit, /page\.outOfRange/);
});

test('السجلّ يقرأ التغيير تغييراً: قبل ثم بعد', () => {
  assert.match(audit, /const before = str\(r, 'old_value'\)/);
  assert.match(audit, /const after = str\(r, 'new_value'\)/);
  assert.match(audit, /←/);
});

test('الفاعل يُعرض باسمه، والفعل بلا فاعلٍ يُنسب إلى النظام', () => {
  assert.match(migration, /left join public\.profiles p on p\.id = a\.actor_id/);
  assert.match(audit, /str\(r, 'actor_name'\) \|\| str\(r, 'actor_email'\) \|\| 'النظام'/);
});

test('قائمة الأفعال تُقرأ من السجلّ لا تُثبَّت', () => {
  assert.match(migration, /select a\.action as value, count\(\*\) as n/);
  assert.match(audit, /audit_facets/);
  // والاسم العربي المفقود لا يُخفي الفعل بل يُعرض كما هو.
  assert.match(audit, /ACTION_AR\[str\(a, 'value'\)\] \|\| str\(a, 'value'\)/);
});

test('الإجراء التالي قراءةٌ لا حكم: لا مبلغ يُحسب فيه', () => {
  const body = migration.replace(/--.*$/gm, '');
  assert.doesNotMatch(body, /insert\s+into/i, 'الإجراء التالي يكتب');
  assert.doesNotMatch(body, /update\s+public\./i, 'الإجراء التالي يكتب');
  assert.match(migration, /\bstable\b/);
});

test('ترتيب الإجراء هو ترتيب الحجب المالي', () => {
  const order = ['RESOLVE_HOLD', 'RESOLVE_OWNERSHIP', 'NEEDS_BUSINESS_DECISION',
    'VERIFY_INVOICE', 'READY_TO_PAY'];
  const at = order.map((c) => migration.indexOf(`'${c}'`));
  assert.ok(at.every((i) => i > -1), 'رمز إجراء مفقود');
  for (let i = 1; i < at.length; i += 1) {
    assert.ok(at[i] > at[i - 1], `الترتيب مكسور عند ${order[i]}`);
  }
});

test('كل إجراء يقول سببه ويقود إلى شاشته', () => {
  assert.match(migration, /'why',/);
  assert.match(migration, /'path',/);
  assert.match(inst, /function nextActionBanner/);
  assert.match(inst, /الإجراء التالي:/);
  assert.match(inst, /esc\(str\(a, 'why'\)\)/);
  // ولا شريط حين لا إجراء.
  assert.match(inst, /if \(!a \|\| str\(a, 'code'\) === 'NONE'\) return ''/);
});

test('المسار مسجَّل في المُوجِّه والملاحة', () => {
  const main = read('src/main.ts');
  assert.match(main, /routes as auditRoutes/);
  assert.match(main, /\.\.\.auditRoutes,/);
  assert.match(read('src/app/shell.ts'), /'\/audit'/);
  assert.match(audit, /pattern: '\/audit'/);
});
