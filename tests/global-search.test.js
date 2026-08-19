// البحث الشامل.
//
// عطبان صامتان يُحرسان هنا: ردٌّ قديم يكتب فوق ردٍّ جديد فيرى المستخدم
// نتائج حرفٍ مضى، وبحثٌ يتجاوز الصلاحية فيكشف ما لا يُرى في شاشته.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');

const search = read('src/app/search.ts');
const migration = read('supabase/migrations/20260903090000_global_search.sql');

test('البحث محروس بالقدرة لكل نوع على حدة', () => {
  assert.match(migration, /has_capability\('installation\.view'\)/);
  assert.match(migration, /has_capability\('agent\.view'\)/);
  assert.match(migration, /has_capability\('commission\.view'\)/);
  assert.match(migration, /revoke execute on function public\.global_search\(text,integer\) from public, anon/);
});

test('حرفٌ واحد لا يمسح الجداول', () => {
  assert.match(migration, /if length\(v_q\) < 2 then/);
  assert.match(migration, /'too_short', true/);
  assert.match(search, /q\.trim\(\)\.length < 2/);
});

test('المطابقة التامة أوّلاً ثم البادئة ثم الاحتواء', () => {
  // ثلاث رتب في كل نوع، والترتيب النهائي عبر الأنواع بالرتبة.
  const ranks = [...migration.matchAll(/then 0[\s\S]{0,120}?then 1[\s\S]{0,60}?else 2 end as rank/g)];
  assert.ok(ranks.length >= 4, `رتب ناقصة: ${ranks.length}`);
  assert.match(migration, /order by \(r ->> 'rank'\)::int/);
});

test('ردُّ طلبٍ ألغي لا يُكتب فوق الأحدث', () => {
  assert.match(search, /controller\?\.abort\(\)/);
  assert.match(search, /if \(mine\.signal\.aborted \|\| controller !== mine\) return/);
  // في كلا المسارين: النجاح والفشل.
  const guards = [...search.matchAll(/controller !== mine\) return/g)];
  assert.equal(guards.length, 2, 'الحارس ناقص في أحد المسارين');
});

test('الطلب مؤجَّل فلا يُرسل بكل ضغطة', () => {
  assert.match(search, /window\.clearTimeout\(timer\)/);
  assert.match(search, /window\.setTimeout\(\(\) => void run\(q\), 220\)/);
});

test('كل نتيجة تحمل نوعها ومسار ملفّها', () => {
  for (const kind of ['subscriber', 'parent', 'agent', 'fdt']) {
    assert.ok(migration.includes(`'${kind}' as kind`), `نوع مفقود: ${kind}`);
  }
  assert.match(migration, /'\/master\/parents\/' \|\| p\.raw_parent as path/);
  assert.match(search, /href="\$\{esc\(href\(str\(r, 'path'\)\)\)\}"/);
});

test('اسم الأب يُعرض كما ورد وبمحاذاة لاتينية', () => {
  assert.match(search, /LTR_KINDS/);
  assert.match(search, /'subscriber', 'parent', 'fdt'/);
  // ولا يُستبدل بتسمية التصنيف: العنوان هو title القادم من المصدر.
  assert.match(search, /esc\(str\(r, 'title'\)\)/);
});

test('البحث مركَّب في الإقلاع، ويحتمل غياب مضيفه', () => {
  const main = read('src/main.ts');
  assert.match(main, /import \{ mountSearch \} from '\.\/app\/search'/);
  assert.match(main, /const searchHost = document\.getElementById\('appSearch'\)/);
  assert.match(main, /if \(searchHost\) mountSearch\(searchHost\)/);
  const html = read('index.html');
  assert.match(html, /id="appSearch"/);
  assert.match(html, /assets\/css\/omni\.css/);
});

test('لوحة المفاتيح تعمل: تركيز وتنقّل وخروج', () => {
  assert.match(search, /ev\.key\.toLowerCase\(\) === 'k'/);
  assert.match(search, /'ArrowDown'/);
  assert.match(search, /'ArrowUp'/);
  assert.match(search, /'Escape'/);
  assert.match(search, /aria-expanded/);
  assert.match(search, /role="listbox"/);
});
