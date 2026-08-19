// التطبيق: التوجيه، والملاحة، والمال، والبناء.
//
// المصدر TypeScript، والاختبار يقرأه نصّاً ويتحقّق من العقود التي تُكسَر
// صامتةً: مطابقة المسار، وعدم تكرار الوجهات، وصيغة المال، وحدود الصفحة.
// المنطق النقيّ (matchRoute, money) يُستخرج ويُنفَّذ فعلاً لا يُفحص شكلاً.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');

/**
 * يُنفِّذ دوالّ TypeScript نقيّة فعلاً.
 *
 * يستعمل مُترجِم TypeScript نفسه لا نزعاً بالتعابير النمطية: أوّل محاولة
 * نزعت الأنواع يدوياً فانكسرت على `Record<string, string> | null`. مُحلِّل
 * نصّي للغة ذات قواعد كاملة يُخطئ دائماً؛ الأداة الصحيحة موجودة أصلاً في
 * تبعيّات المشروع.
 */
const ts = require('typescript');

function evalTs(source, names) {
  const js = ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.CommonJS,
      target: ts.ScriptTarget.ES2022,
    },
  }).outputText;
  const sandbox = {
    module: { exports: {} }, exports: {}, console,
    require: () => ({}),
    window: { location: { hash: '' } },
  };
  sandbox.exports = sandbox.module.exports;
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(js, sandbox);
  const out = {};
  names.forEach((n) => { out[n] = sandbox.module.exports[n]; });
  return out;
}

/* ---------------------------------------------------------------------------
   مطابقة المسار
   ------------------------------------------------------------------------ */

const routerSrc = read('src/app/router.ts');
const { matchRoute: rawMatch } = evalTs(routerSrc, ['matchRoute']);
// الكائن يعود من realm الصندوق، فبروتوتايبه ليس بروتوتايب الاختبار.
// يُنسخ نسخاً عادياً قبل المقارنة البنيوية.
const matchRoute = (a, b) => { const r = rawMatch(a, b); return r === null ? null : { ...r }; };

test('المسار الثابت يطابق نفسه فقط', () => {
  assert.deepEqual(matchRoute('/commissions', '/commissions'), {});
  assert.equal(matchRoute('/commissions', '/installation'), null);
  assert.equal(matchRoute('/commissions', '/commissions/cycles'), null);
});

test('المعامل يُلتقط ويُفكّ ترميزه', () => {
  assert.deepEqual(matchRoute('/installation/subscribers/:id', '/installation/subscribers/AB-12'),
    { id: 'AB-12' });
  assert.deepEqual(matchRoute('/x/:a/:b', '/x/one/two'), { a: 'one', b: 'two' });
  // المعرّفات تحمل محارف تحتاج ترميزاً؛ فكُّها هنا لا في كل شاشة.
  assert.deepEqual(matchRoute('/s/:id', '/s/' + encodeURIComponent('a b/c')), { id: 'a b/c' });
});

test('عدد المقاطع يجب أن يتطابق', () => {
  assert.equal(matchRoute('/a/:id', '/a'), null);
  assert.equal(matchRoute('/a/:id', '/a/b/c'), null);
});

/* ---------------------------------------------------------------------------
   المال
   ------------------------------------------------------------------------ */

const { money, amount, count, maybeIqd } = evalTs(read('src/domain/money.ts'),
  ['money', 'amount', 'count', 'maybeIqd']);

test('صيغة المال واحدة', () => {
  assert.equal(money(37059000), '37,059,000 د.ع');
  assert.equal(money(0), '0 د.ع');
  assert.equal(amount(1234567), '1,234,567');
});

test('الدينار بلا كسور', () => {
  assert.equal(amount(1500.4), '1,500');
  assert.equal(amount(1500.6), '1,501');
});

test('الغياب شرطة لا صفر', () => {
  // الفرق بين «لم يُحمَّل» و«قال الخادم صفراً» هو الفرق بين طابور مفتوح
  // وطابور مُغلق بالخطأ.
  assert.equal(money(null), '—');
  assert.equal(money(undefined), '—');
  assert.equal(count(null), '—');
  assert.equal(money(0), '0 د.ع');
  assert.equal(maybeIqd(null), null);
  assert.equal(maybeIqd(''), null);
  assert.equal(maybeIqd(0), 0);
  assert.equal(maybeIqd('12.7'), 13);
  assert.equal(maybeIqd('abc'), null);
});

/* ---------------------------------------------------------------------------
   الملاحة — لا وجهة مكرَّرة
   ------------------------------------------------------------------------ */

const shellSrc = read('src/app/shell.ts');

test('لا تسميتان تقصدان مساراً واحداً', () => {
  // هذا هو العيب الذي أخرجنا منه هذا العمل: خمس تسميات في «أجور التنصيب»
  // كانت تصل إلى نفس اللوحة.
  const paths = [...shellSrc.matchAll(/path:\s*'([^']+)'/g)].map((m) => m[1]);
  const seen = new Set();
  const dupes = paths.filter((p) => (seen.has(p) ? true : (seen.add(p), false)));
  assert.deepEqual(dupes, [], `وجهات مكرَّرة: ${dupes.join(', ')}`);
  assert.ok(paths.length >= 10, 'الشريط أقصر من معمارية المعلومات المعتمدة');
});

test('الإبراز يختار أطول مسار مطابق لا أوّل بادئة', () => {
  // `/installation` بادئة لـ`/installation/subscribers`؛ مطابقة البادئة كانت
  // تُبرز «مركز التحكّم» والمستخدم في «المشتركون».
  assert.match(shellSrc, /sort\(\(a, b\) => b\.path\.length - a\.path\.length\)/);
});

test('كل عنصر ملاحة يحمل قدرته أو يكون قديماً معلَناً', () => {
  const items = [...shellSrc.matchAll(/\{ label: '[^']+', path: '[^']+', icon: '[^']*'([^}]*)\}/g)];
  assert.ok(items.length >= 10);
  items.forEach((m) => {
    assert.ok(/capability:|legacy: true/.test(m[1]), `عنصر بلا قدرة ولا وسم قديم: ${m[0]}`);
  });
});

/* ---------------------------------------------------------------------------
   الحالات
   ------------------------------------------------------------------------ */

const uiSrc = read('src/components/ui.ts');

test('لكل شاشة حالات تحميل وفراغ وخطأ ومنع', () => {
  ['export function loading', 'export function empty', 'export function errorState',
    'export function forbidden'].forEach((f) => assert.ok(uiSrc.includes(f), `${f} مفقودة`));
});

test('حالة المنع تُسمّي القدرة ولا تُخفي وجود الشاشة', () => {
  assert.match(uiSrc, /لا صلاحية لعرض هذه الشاشة/);
  assert.match(uiSrc, /القدرة المطلوبة/);
  assert.match(uiSrc, /الخادم يفحص الصلاحية في كل الأحوال/);
});

test('الخطأ لا يعرض أثر مكدّس ولا تفاصيل داخلية', () => {
  const api = read('src/services/api.ts');
  assert.match(api, /تعذّر الاتصال بالخادم/);
  assert.match(api, /لا صلاحية لهذا الإجراء/);
  assert.match(api, /message\.slice\(0, 200\)/);
  assert.doesNotMatch(api, /error\.stack/);
});

/* ---------------------------------------------------------------------------
   التصفيح
   ------------------------------------------------------------------------ */

test('الترقيم يُعلن حدوده دائماً', () => {
  // القائمة التي تُخفي أنها مقصوصة هي أصل العيب: 300 من 22,727 بلا إشارة.
  assert.match(uiSrc, /export function pager/);
  assert.match(uiSrc, /من \$\{total\.toLocaleString/);
  assert.match(uiSrc, /صفحة \$\{page\} من \$\{pages\}/);
});

test('المرشِّحات تعيش في الاستعلام فيصير الطابور قابلاً للإرسال', () => {
  assert.match(uiSrc, /export function filterBar/);
  assert.match(uiSrc, /window\.location\.hash = href\(path, q\)/);
});

test('الصفحة تُقرأ من الخادم لا تُقصّ في المتصفح', () => {
  const api = read('src/services/api.ts');
  assert.match(api, /export function toPage/);
  assert.match(api, /total_count/);
  ['src/features/installation/index.ts', 'src/features/commissions/index.ts'].forEach((f) => {
    const s = read(f);
    // slice(0,19) قصُّ طابع زمني لا قصُّ قائمة. الحدّ ≥50 يميّز الحالتين:
    // لا أحد يقصّ نصّاً عند 50 محرفاً، ولا أحد يعرض قائمة من 19 صفّاً بحدٍّ صلب.
    const listTruncation = [...s.matchAll(/\.slice\(0,\s*(\d+)\)/g)]
      .filter((m) => Number(m[1]) >= 50)
      .map((m) => m[0]);
    assert.deepEqual(listTruncation, [], `${f} يقصّ القائمة في المتصفح`);
  });
});

/* ---------------------------------------------------------------------------
   لا حساب مالي في المتصفح
   ------------------------------------------------------------------------ */

test('الشاشات لا تحمل معدّلات ولا حدود شرائح', () => {
  ['home', 'commissions', 'installation', 'finance'].forEach((f) => {
    const s = read(`src/features/${f}/index.ts`);
    assert.doesNotMatch(s, /\b(4000|4750|5500|6000|8000|11500|3000|13000)\b/,
      `${f} يحمل رقماً مالياً ثابتاً`);
  });
});

test('الأرقام تأتي من دوالّ الخادم', () => {
  const s = read('src/features/home/index.ts');
  assert.match(s, /report_management_summary/);
  assert.match(s, /report_commission_exception_impact/);
});

test('أساس الشريحة والأحداث المؤهَّلة معروضان منفصلين', () => {
  const s = read('src/features/commissions/index.ts');
  assert.match(s, /أساس الشريحة/);
  assert.match(s, /الأحداث المؤهَّلة/);
  assert.match(s, /ليست أساس الشريحة/);
});

/* ---------------------------------------------------------------------------
   المال الموقوف والمعتمد
   ------------------------------------------------------------------------ */

test('الرقم غير المعتمد موسوم تقديرياً', () => {
  const s = read('src/features/commissions/index.ts');
  assert.match(s, /const isProjected/);
  assert.match(s, /FINALIZED', 'PARTIALLY_PAID', 'PAID', 'CLOSED'/);
  assert.match(s, /projectedTag\(\)/);
});

test('الدفع لا يُقرَّر في الواجهة', () => {
  const s = read('src/features/finance/index.ts');
  assert.match(s, /سبب الرفض يأتي من الخادم/);
  assert.match(s, /blocked_reason/);
  assert.doesNotMatch(s, /canPay|allowPayment|isPayable\s*=/);
});

test('الاستثناء يقود إلى شاشة حسمه', () => {
  const s = read('src/features/commissions/index.ts');
  assert.match(s, /UNKNOWN_FDT: href/);
  assert.match(s, /UNKNOWN_AGENT: href/);
  assert.match(s, /SOURCE_INCOMPLETE: href/);
  assert.doesNotMatch(s, /مطوّر|developer/i);
});

/* ---------------------------------------------------------------------------
   ملفّ الحالة
   ------------------------------------------------------------------------ */

test('ملفّ المشترك يحمل التبويبات الثمانية', () => {
  const s = read('src/features/installation/index.ts');
  ['نظرة عامة', 'التفعيلات', 'الفواتير', 'الاستحقاقات', 'الدفعات', 'الإيقافات', 'التاريخ', 'التدقيق']
    .forEach((t) => assert.ok(s.includes(t), `تبويب مفقود: ${t}`));
});

test('الخطّ الزمني مُشتَقّ لا مُخزَّن', () => {
  const s = read('src/features/installation/index.ts');
  assert.match(s, /subscriber_timeline/);
  assert.match(s, /مُشتَقّ من المصادر المعتمدة/);
  const migration = read('supabase/migrations/20260828090000_add_operational_read_api.sql');
  assert.doesNotMatch(migration, /create table[^;]*timeline/i);
});

/* ---------------------------------------------------------------------------
   البناء
   ------------------------------------------------------------------------ */

test('البناء يرفض مخرَجاً ناقصاً', () => {
  // إدخال خطوة بناء أدخل عطلاً جديداً: مخرَج ينقصه ملف يُنشَر فيسقط عند
  // التحميل. أوّل بناء هنا أنتج dist بلا السكربتات القديمة ولا xlsx.
  const cfg = read('vite.config.ts');
  assert.match(cfg, /BUILD REJECTED/);
  assert.match(cfg, /babil-verify-bundle/);
  assert.match(cfg, /babil-copy-legacy-assets/);
});

test('التوجيه بالـhash حتى يعمل الرابط العميق على Pages', () => {
  const cfg = read('vite.config.ts');
  assert.match(cfg, /hash/i);
  assert.match(routerSrc, /window\.location\.hash/);
});

test('استرجاع كلمة المرور يُفحص قبل أن يرى الموجِّه الـhash', () => {
  // الـhash مشترك بين الموجِّه ورابط الاسترجاع من Supabase؛ ابتلاعه يكسر
  // إعادة تعيين كلمة المرور.
  const main = read('src/main.ts');
  assert.match(main, /access_token/);
  assert.match(main, /detectRecoveryRedirect|الاسترجاع/);
  assert.match(routerSrc, /raw\.startsWith\('\/'\)/);
});

/* ---------------------------------------------------------------------------
   الهيكل القديم
   ------------------------------------------------------------------------ */

test('الشيفرة القديمة تبقى تحت مسارها ولا تُحذف قبل بديلها', () => {
  const html = read('index.html');
  assert.match(html, /id="legacyWorkspace"/);
  assert.match(html, /id="appOutlet"/);
  assert.match(html, /id="appNav"/);
  const css = read('assets/css/babil-flow.css');
  assert.match(css, /#legacyWorkspace \{ display: none; \}/);
  assert.match(css, /body\.legacy-visible #legacyWorkspace \{ display: block; \}/);
});

test('محوّل الجلسة القديم موثَّق بشرط إزالته', () => {
  const api = read('src/services/api.ts');
  assert.match(api, /محوّل مؤقّت مقصود/);
  assert.match(api, /شرط الإزالة/);
  assert.match(api, /index-html-exit-plan/);
});
