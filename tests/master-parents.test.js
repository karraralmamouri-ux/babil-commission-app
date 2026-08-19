// البيانات المرجعية: سجلّ الآباء وشاشة الحسم.
//
// العقد الذي تحرسه هذه الاختبارات واحد: اسم الأب بيانٌ من المصدر، والتصنيف
// حكمٌ بجانبه. أيّ شيفرة تستبدل الاسم بتسمية التصنيف، أو تثبّت اسم أبٍ في
// الواجهة، تُسقط هذه الاختبارات.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');
const NL = String.fromCharCode(10);

/** الشيفرة وحدها — التعليقات تذكر الأسماء شرحاً للقاعدة لا اعتماداً عليها. */
const BLOCK = /\/\*[\s\S]*?\*\//g;
const codeOnly = (s) => s.replace(BLOCK, '')
  .split(NL).filter((l) => !l.trim().startsWith('//')).join(NL);

const master = read('src/features/master/index.ts');
const migration = read('supabase/migrations/20260901090000_parent_evidence.sql');

test('الشاشتان مسجّلتان بمسارَيهما', () => {
  assert.match(master, /pattern: '\/master\/parents'/);
  assert.match(master, /pattern: '\/master\/parents\/:name'/);
  assert.match(master, /export const routes: Route\[\] = \[parents, parentCase\]/);

  const main = read('src/main.ts');
  assert.match(main, /routes as masterRoutes/);
  assert.match(main, /\.\.\.masterRoutes,/);

  const shell = read('src/app/shell.ts');
  assert.match(shell, /'\/master\/parents'/);
});

test('التصنيف ثلاثي في الواجهة كما في الخادم', () => {
  const values = [...master.matchAll(/\{ value: '([A-Z_]+)', label:/g)].map((m) => m[1]);
  assert.deepEqual(values.sort(), ['DIRECT_COMPANY', 'NEEDS_REVIEW', 'RESELLER']);
  assert.ok(!master.includes('FTTH_USER'), 'صنف مالي ملغى ما زال في الواجهة');
  assert.ok(!codeOnly(master).includes("'OFFICE'"), 'صنف مالي ملغى ما زال في الواجهة');
});

test('عمود الأب يعرض الاسم الأصلي لا تسمية التصنيف', () => {
  // العمود يُبنى من parent_name نفسه، ويمرّ بدالة عرضٍ لا بجدول تسميات.
  assert.match(master, /label: 'الأب \(كما ورد في المصدر\)'/);
  assert.match(master, /parentName\(str\(r, 'parent_name'\)\)/);

  // دالة العرض تُخرج الاسم كما هو، بلا استبدال.
  assert.match(master, /class="parent-name" dir="ltr">\$\{esc\(name\)\}/);
});

test('لا اسم أبٍ مثبَّت في الشيفرة', () => {
  const code = codeOnly(master);
  for (const name of ['FTTH_Users', 'TTH_Users', 'hrins.office', 'hrins.oice', 'office.1']) {
    assert.ok(!code.includes(name), `اسم أب مثبَّت في الواجهة: ${name}`);
  }
});

test('القرارات ثلاثة، و«تابع للشركة» يقول صراحةً إن الاسم لا يتغيّر', () => {
  assert.match(master, /ربط بوكيل/);
  assert.match(master, /تابع للشركة/);
  assert.match(master, /تحتاج مراجعة/);
  // الوعد مكتوبٌ في الشاشة لا في التوثيق وحده.
  assert.match(master, /يبقى كما هو في كل الحالات/);
});

test('«ربط بوكيل» وحده يطلب وكيلاً، والواجهة تمنع الإرسال بدونه', () => {
  assert.match(master, /const needsAgent = choice\.value === 'RESELLER'/);
  assert.match(master, /«ربط بوكيل» يحتاج وكيلاً محدَّداً/);
  // ولا يُرسل وكيل مع قرارٍ غير الوكالة — الخادم يرفضها، والواجهة لا تحاول.
  assert.match(master, /p_agent_id: ownership === 'RESELLER' \? agent\.value : null/);
});

test('كل حفظ يحمل معرّف طلب، فالنقرة المكرّرة بلا أثر ثانٍ', () => {
  assert.match(master, /p_request_id: crypto\.randomUUID\(\)/);
  assert.match(master, /idempotent/);
});

test('الشاشة تحترم الصلاحية قبل أن تعرض أزرار القرار', () => {
  assert.match(master, /if \(!can\('agent\.manage'\)\)/);
  assert.match(master, /capability: 'agent\.view'/);
});

test('الشواهد تُعرض قبل القرار: حجم ومال وباقات ومصدر', () => {
  for (const key of ['volume', 'exposure', 'packages', 'related_parents', 'samples', 'audit']) {
    assert.ok(master.includes(`'${key}'`), `شاهد ناقص في الشاشة: ${key}`);
  }
  // المبلغ يُقال مؤشِّراً لا مستحقاً.
  assert.match(master, /المبلغ المؤشِّر/);
});

test('تداخل المشتركين يُعرض شاهداً لا استنتاجاً يُطبَّق', () => {
  assert.match(master, /آباء يتقاسمون المشتركين أنفسهم/);
  assert.match(master, /شاهدٌ يُقرأ، لا استنتاجٌ يُطبَّق/);
  // ولا تصنيف تلقائي في الواجهة: الحفظ لا يقع إلا من نقرة المستخدم.
  const autoCalls = [...master.matchAll(/classify_parent/g)].length;
  assert.equal(autoCalls, 1, 'استدعاء تصنيف زائد — التصنيف قرار يدوي');
});

test('المهاجرة لا تُصنِّف شيئاً ولا تكتب في جدول مالي', () => {
  // parent_evidence قراءةٌ فقط — stable، ولا insert/update فيها.
  assert.match(migration, /create or replace function public\.parent_evidence/);
  assert.match(migration, /\bstable\b/);
  const body = migration.replace(/--.*$/gm, '');
  assert.doesNotMatch(body, /\binsert\s+into\b/i, 'دالة الشواهد تكتب');
  assert.doesNotMatch(body, /\bupdate\s+public\./i, 'دالة الشواهد تكتب');
  assert.doesNotMatch(body, /\bdelete\s+from\b/i, 'دالة الشواهد تحذف');
});

test('الشواهد محروسة بقدرة، ومحجوبة عن anon', () => {
  assert.match(migration, /perform public\.require_capability\('agent\.view'\)/);
  assert.match(migration, /revoke execute on function public\.parent_evidence\(text\) from public, anon/);
  assert.match(migration, /revoke execute on function public\.list_agents_for_pick\(text,integer\) from public, anon/);
  // الحارس perform لا CTE: المخطِّط يُسقط الـCTE غير المستعملة فيسقط الحارس معها.
  assert.doesNotMatch(migration, /with\s+guard\s+as/i);
});

test('اسم الأب يُطابَق بمفتاح مشتق ويُعرض بالأصل', () => {
  // المطابقة على lower(btrim(...)) لأن المصدر غير منتظم، والعرض من raw_parent.
  assert.match(migration, /v_key\s+text := lower\(btrim\(coalesce\(p_parent_name, ''\)\)\)/);
  assert.match(migration, /select e\.raw_parent into v_exact/);
  assert.match(migration, /'parent_name', v_exact/);
});
