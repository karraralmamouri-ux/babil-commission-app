// الصلاحيات، والعلامة، ولغة الأيقونات.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');

const usersUi = read('src/features/system/users.ts');
const usersSql = read('supabase/migrations/20260911090000_users_and_permissions.sql');
const html = read('index.html');
const shell = read('src/app/shell.ts');
const css = read('assets/css/babil-flow.css');

/* ---- الصلاحيات ----------------------------------------------------------- */

test('الكتالوج هو المرجع: لا عدد مثبَّت ولا قائمة مكرّرة', () => {
  // العدد يُقرأ من القاعدة.
  assert.match(usersSql, /'catalogue_size', \(select count\(\*\) from public\.permission_capabilities\)/);
  assert.match(usersUi, /num\(cat \|\| \{\}, 'total'\)/);
  // ولا قائمة قدرات مكتوبة في الواجهة.
  const caps = [...usersUi.matchAll(/'[a-z]+\.[a-z_]+'/g)].map((m) => m[0]);
  const declared = caps.filter((c) => !c.includes('permission.manage'));
  assert.equal(declared.length, 0, `قدرات مثبّتة في الواجهة: ${declared.join(', ')}`);
});

test('كل قدرة تُعرض بحكمها ومصدره', () => {
  for (const key of ['label_ar', 'description', 'domain', 'is_sensitive', 'effective', 'source']) {
    assert.ok(usersSql.includes(key), `حقل مفقود في الخادم: ${key}`);
  }
  for (const src of ['ROLE', 'OVERRIDE_GRANT', 'OVERRIDE_DENY', 'NONE']) {
    assert.ok(usersSql.includes(`'${src}'`), `مصدر مفقود: ${src}`);
    assert.ok(usersUi.includes(src), `مصدر غير معروض: ${src}`);
  }
  // والنطاق والسبب والانتهاء.
  assert.match(usersUi, /override_scope_type/);
  assert.match(usersUi, /override_reason/);
  assert.match(usersUi, /override_expires_at/);
});

test('الحكم النهائي من المحرّك لا من إعادة حسابٍ في الواجهة', () => {
  assert.match(usersSql, /public\.effective_permission\(p_user_id, c\.key, null, null\) as effective/);
  // الواجهة تقرأ effective ولا تشتقّه من الدور والاستثناء.
  assert.match(usersUi, /c\['effective'\] === true/);
  assert.doesNotMatch(usersUi, /from_role\s*&&|from_role\s*\?\?/);
});

test('قدرة خارج الكتالوج تُقال بمفتاحها لا تُخفى ولا تصير ؟؟؟', () => {
  assert.match(usersSql, /'uncatalogued'/);
  assert.match(usersSql, /not exists \(select 1 from public\.permission_capabilities c/);
  assert.match(usersUi, /غير معرّفة في كتالوج الصلاحيات/);
  assert.match(usersUi, /capability_key/);
});

test('لا «؟؟؟» في أيّ مصدر واجهة', () => {
  // التعليقات تُستثنى: شرحُ القاعدة يذكرها مثالاً، والمقصود منعُ ظهورها
  // على الشاشة لا منعُ ذكرها في تعليق.
  const BLOCK = /\/\*[\s\S]*?\*\//g;
  const codeOnly = (s) => s.replace(BLOCK, '')
    .split(String.fromCharCode(10)).filter((l) => !l.trim().startsWith('//')).join(' ');
  for (const f of ['src/features/system/users.ts', 'src/features/installation/invoices.ts',
    'src/features/installation/payout.ts', 'src/features/installation/holds.ts',
    'src/app/shell.ts', 'index.html']) {
    assert.ok(!codeOnly(read(f)).includes('؟؟؟'), `«؟؟؟» في ${f}`);
  }
});

test('حارس القفل معروض: آخر إداري لا يُسحب منه بصمت', () => {
  assert.match(usersSql, /permission_administrators_remaining\(\)/);
  assert.match(usersUi, /آخر إداري/);
});

test('الصلاحيات محروسة بـpermission.manage', () => {
  assert.match(usersSql, /require_capability\('permission\.manage'\)/);
  assert.match(usersSql, /revoke execute on function public\.page_users/);
  assert.match(usersSql, /revoke execute on function public\.user_effective_permissions/);
  assert.match(usersUi, /capability: 'permission\.manage'/);
});

/* ---- العلامة ------------------------------------------------------------- */

test('طقم العلامة كامل: أساسي ومصغَّر، على داكن وفاتح', () => {
  for (const id of ['bfMark', 'bfMarkLight', 'bfMarkCompact', 'bfMarkCompactLight']) {
    assert.ok(html.includes(`id="${id}"`), `علامة مفقودة: ${id}`);
  }
});

test('الساق شريط مصمت لا مسارٌ مضمر', () => {
  // كانت تُرسم ضمناً بعودة المسار إلى H14 فترقّ عند 20px.
  const mark = html.slice(html.indexOf('id="bfMark"'), html.indexOf('id="bfMarkLight"'));
  assert.match(mark, /<rect x="12" y="11" width="5\.2" height="26"/);
});

test('المُصغَّرة بلا ذيل التدفّق', () => {
  const compact = html.slice(html.indexOf('id="bfMarkCompact"'), html.indexOf('id="bfMarkCompactLight"'));
  // الذيل والنقطة يلتصقان تحت 24px فيُقرأ الحرف خطأً.
  assert.doesNotMatch(compact, /<circle/);
  assert.equal((compact.match(/<path/g) || []).length, 2);
});

test('العلامة متوازنة داخل إطارها', () => {
  // الهامش كان 12 يساراً و8.2 يميناً؛ الإزاحة تُسوّيه.
  assert.match(html, /<g transform="translate\(-1\.9 0\.6\)">/);
  assert.match(html, /<g transform="translate\(-0\.7 0\)">/);
});

test('العلامة تحمل ألوان الهوية لا ألواناً حرّة', () => {
  const marks = html.slice(html.indexOf('id="bfMark"'), html.indexOf('</defs>'));
  const colours = [...marks.matchAll(/#[0-9A-Fa-f]{6}/g)].map((m) => m[0].toUpperCase());
  const allowed = new Set(['#0B1930', '#F8FAFC', '#E2E8F0']);
  const stray = [...new Set(colours)].filter((c) => !allowed.has(c));
  assert.deepEqual(stray, [], `لون خارج الهوية: ${stray.join(', ')}`);
});

/* ---- لغة الأيقونات والهوية ---------------------------------------------- */

test('لغة أيقونات واحدة: لا رموز تعبيرية في الملاحة', () => {
  const icons = [...shell.matchAll(/icon: '([^']+)'/g)].map((m) => m[1]);
  assert.ok(icons.length >= 10, 'الملاحة أقصر من المتوقّع');
  // الرموز التعبيرية تُرسم ملوّنةً وتتغيّر بين المنصّات.
  const emoji = icons.filter((i) => /\p{Extended_Pictographic}/u.test(i));
  assert.deepEqual(emoji, [], `رموز تعبيرية في الملاحة: ${emoji.join(' ')}`);
});

test('المجموعات هي المعتمدة', () => {
  for (const label of ['عمولات الوكلاء', 'أجور التنصيب', 'المالية', 'تحتاج إجراء',
    'البيانات الرئيسية', 'النظام']) {
    assert.ok(shell.includes(label), `مجموعة مفقودة: ${label}`);
  }
});

test('ألوان الهوية معرَّفة كما اعتُمدت', () => {
  for (const [token, value] of [['--navy', '#0B1930'], ['--gold', '#C9972B'],
    ['--cloud', '#F8FAFC'], ['--slate', '#64748B']]) {
    assert.ok(new RegExp(`${token}:\\s*${value}`, 'i').test(css), `لون مفقود: ${token} ${value}`);
  }
});

test('الخطوط محلّية: لا طلب خارجي ولا ملفّ مرفق', () => {
  assert.doesNotMatch(css, /@font-face/);
  assert.doesNotMatch(css, /fonts\.googleapis|fonts\.gstatic/);
  assert.doesNotMatch(html, /fonts\.googleapis|fonts\.gstatic/);
  assert.match(css, /--font-ar:\s*"IBM Plex Sans Arabic"/);
  assert.match(css, /--font-num:\s*"Inter"/);
});

test('حقول الدخول موصولة بتسمياتها', () => {
  // <label> بلا for لا يصل قارئ الشاشة بينه وبين الحقل.
  for (const id of ['loginEmail', 'loginPassword', 'newPasswordInput', 'confirmPasswordInput']) {
    assert.ok(html.includes(`<label for="${id}">`), `تسمية غير موصولة: ${id}`);
  }
  assert.match(html, /id="monthSelect"[^>]*aria-label=/);
});

/* ---- المستودع يحمل ما يبنيه ---------------------------------------------- */

test('كل وحدة يستوردها التطبيق متعقَّبة في git', () => {
  // «work/» في .gitignore كان بلا جذر، فطابق src/features/work/ وابتلع مركز
  // العمل. البناء المحلّي يمرّ لأن الملفّ على القرص، وأوّل استنساخ نظيف يسقط.
  const { execFileSync } = require('node:child_process');
  const tracked = new Set(
    execFileSync('git', ['ls-files', 'src'], { cwd: root, encoding: 'utf8' })
      .split('\n').filter(Boolean).map((f) => f.split('\\').join('/')));

  const main = read('src/main.ts');
  const specs = [...main.matchAll(/from '(\.\/[^']+)'/g)].map((m) => m[1]);
  const missing = specs.filter((spec) => {
    const base = 'src/' + spec.replace(/^\.\//, '');
    return !tracked.has(base + '.ts') && !tracked.has(base + '/index.ts');
  });
  assert.deepEqual(missing, [], `وحدات مستورَدة وغير متعقَّبة: ${missing.join(', ')}`);
});

test('أنماط التجاهل مجذورة، فلا تبتلع مجلّداً في العمق', () => {
  const ignore = read('.gitignore');
  for (const pattern of ['work/', 'backups/', 'exports/', 'coverage/']) {
    assert.ok(ignore.includes('/' + pattern),
      `نمط بلا جذر يطابق أيّ عمق: ${pattern}`);
  }
});
