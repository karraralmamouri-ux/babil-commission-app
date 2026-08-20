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

function evalTs(source, names, win) {
  const js = ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.CommonJS,
      target: ts.ScriptTarget.ES2022,
    },
  }).outputText;
  const sandbox = {
    module: { exports: {} }, exports: {}, console,
    require: () => ({}), URLSearchParams, DOMException, AbortController, HashChangeEvent: class {}, Promise, setTimeout,
    window: win || { location: { hash: '' }, addEventListener() {}, history: { replaceState() {} } },
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
  assert.match(api, /تعذّر الاتصال/);
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
  // الحجب صار يأتي من مركز العمل: مصدرٌ واحد مصنَّف بدل تقرير يُقرأ وحده.
  assert.match(s, /action_center/);
  assert.match(s, /installation_cycle_pipeline/);
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

/* ---------------------------------------------------------------------------
   سلطة ملاحة واحدة
   ------------------------------------------------------------------------ */

test('لا زرّ في الشريط يقصد شاشةً مخفيّة', () => {
  // كانت كتلة «تجهيز الشهر» تقع بعد #appNav داخل <aside> المشترك، فتظهر على
  // كل مسار. وفيها زرّان ينادِيان openSettingsSection على أقسامٍ تعيش في
  // #legacyWorkspace — وهو مخفيّ خارج #/legacy. فكان الضغط يفتح <details>
  // لا يراه أحد ويمرّر الصفحة إلى عنصرٍ غير مرئي: زرٌّ لا يفعل شيئاً وهو
  // يبدو صالحاً. وهذا أسوأ من زرٍّ غائب.
  const page = read('index.html');
  // التعليقات تُنزع: التعليق الذي يشرح لماذا أُزيلت الكتلة يذكر أسماءها،
  // وذكرُ الاسم ليس زرّاً.
  const aside = page.slice(page.indexOf('<aside'), page.indexOf('</aside>'))
    .replace(/<!--[\s\S]*?-->/g, '');

  assert.doesNotMatch(aside, /openSettingsSection/,
    'زرٌّ في الشريط ما زال يقصد قسماً في الشاشة السابقة');
  assert.doesNotMatch(aside, /تجهيز الشهر/,
    'كتلة تجهيز الشهر ما زالت في الشريط');

  // ولا يبقى في الشريط استدعاءٌ لدالّةٍ من محرّك الشهر المتقاعد.
  for (const retired of ['saveCurrentMonth', 'publishCurrentMonth', 'startNewMonth',
    'toggleCentralPreview', 'focusMonthPicker', 'importFile']) {
    assert.ok(!aside.includes(retired + '('), `الشريط ما زال ينادي ${retired}`);
  }
});

test('كل عنصر ملاحة يقصد مساراً مسجَّلاً', () => {
  // الشريط يُبنى من NAV وحدها، وكل مسار فيها يجب أن يوجد في الموجِّه.
  const shell = read('src/app/shell.ts');
  const navPaths = [...shell.matchAll(/path:\s*'([^']+)'/g)].map((m) => m[1]);
  assert.ok(navPaths.length >= 15, `expected a populated NAV, found ${navPaths.length}`);

  const featureFiles = fs.readdirSync(path.join(root, 'src/features'), { recursive: true })
    .filter((f) => String(f).endsWith('.ts'))
    .map((f) => read(path.join('src/features', String(f))));
  const patterns = new Set(
    featureFiles.flatMap((s) => [...s.matchAll(/pattern:\s*'([^']+)'/g)].map((m) => m[1])));
  patterns.add('/legacy');

  for (const p of navPaths) {
    assert.ok(patterns.has(p), `عنصر ملاحة يقصد مساراً غير مسجَّل: ${p}`);
  }
});

test('الزرّان الميّتان صار لهما مساران حقيقيان', () => {
  const shell = read('src/app/shell.ts');
  assert.match(shell, /أسعار العمولات والتير/);
  assert.match(shell, /ربط الوكلاء والكابينات/);
  assert.match(shell, /'\/master\/commission-schemes'/);
  assert.match(shell, /'\/master\/mapping'/);

  // وكلٌّ منهما يرسم شاشته من الخادم لا من حالةٍ محليّة.
  const schemes = read('src/features/master/commission-schemes.ts');
  assert.match(schemes, /commission_scheme_detail/);
  assert.doesNotMatch(schemes, /localStorage/);

  const mapping = read('src/features/master/mapping.ts');
  assert.match(mapping, /page_fdt_mapping/);
  assert.match(mapping, /register_fdt/);
  assert.doesNotMatch(mapping, /localStorage/);

  // ولا يعود نموذج المدَيات: الرقم ليس حقيقةً مالية.
  assert.doesNotMatch(mapping, /cabinetRange|rawImportConfig|ownerId/);
});

test('الاستثناء يقود إلى شاشة حسمه', () => {
  const s = read('src/features/commissions/index.ts');
  assert.match(s, /UNKNOWN_FDT:/);
  assert.match(s, /UNKNOWN_AGENT:/);
  assert.match(s, /SOURCE_INCOMPLETE:/);
  assert.doesNotMatch(s, /مطوّر|developer/i);

  // ولا يكفي وجود الرابط: كان اثنان منها يشيران إلى ما لا وجود له، فيفتح
  // الزرّ «الصفحة غير موجودة». وزرٌّ يَعِد بحسمٍ ثم يخذل أسوأ من غيابه.
  const patterns = new Set(
    ['src/features/master/fdts.ts', 'src/features/master/agents.ts',
      'src/features/master/index.ts', 'src/features/system/imports.ts',
      'src/features/installation/index.ts']
      .flatMap((f) => [...read(f).matchAll(/pattern:\s*'([^']+)'/g)].map((m) => m[1])));

  const map = s.slice(s.indexOf('const map: Record<string, string>'));
  const targets = [...map.slice(0, map.indexOf('};')).matchAll(/href\(`?'?([^`'$)]+)/g)]
    .map((m) => m[1]).filter((t) => t.startsWith('/'));
  assert.ok(targets.length >= 4, `expected mapped targets, found ${targets.length}`);

  for (const target of targets) {
    const known = [...patterns].some((p) =>
      p === target || p.replace(/\/:[^/]+/g, '') === target.replace(/\/$/, ''));
    assert.ok(known, `الاستثناء يقود إلى مسارٍ غير مسجَّل: ${target}`);
  }
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

/* ---------------------------------------------------------------------------
   سباق الانتقال — ردٌّ بطيء لا يكتب فوق شاشة أخرى
   ------------------------------------------------------------------------ */

test('الردّ البطيء لشاشة غادرها المستخدم لا يكتب فوق الحالية', async () => {
  // الرقم المتسلسل وحده لم يكن كافياً: كان يحرس مسار الخطأ فقط، فشاشةٌ تنتظر
  // الخادم ثم تكتب مباشرةً كانت تكتب فوق الشاشة التالية. يُحاكى هنا فعلاً:
  // شاشة أ بطيئة، ثم انتقال إلى ب، ثم يصل ردّ أ.
  const listeners = [];
  let hash = '#/a';
  const win = {
    get location() { return { get hash() { return hash; }, set hash(v) { hash = v; } }; },
    addEventListener(type, fn) { if (type === 'hashchange') listeners.push(fn); },
    history: { replaceState() {} },
  };
  const { Router } = evalTs(routerSrc, ['Router'], win);

  const el = { innerHTML: '', querySelector: () => null };
  let releaseA;
  const slowA = new Promise((r) => { releaseA = r; });

  const routes = [
    {
      pattern: '/a',
      title: 'A',
      async render(view) {
        view.write('A: loading');
        await slowA;
        // الشاشة تحاول الكتابة بعد أن غادرها المستخدم — بالطريقتين معاً.
        view.write('A: DONE');
        view.innerHTML = 'A: DONE via setter';
      },
    },
    { pattern: '/b', title: 'B', render(view) { view.write('B: ready'); } },
  ];

  const router = new Router({
    outlet: el, routes, can: () => true,
    renderForbidden: () => {}, renderNotFound: () => {}, renderError: () => {},
  });

  router.start();
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(el.innerHTML, 'A: loading', 'الشاشة الأولى رسمت حالتها');

  hash = '#/b';
  listeners.forEach((fn) => fn());
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(el.innerHTML, 'B: ready', 'الانتقال رسم الشاشة الثانية');

  releaseA();
  await new Promise((r) => setTimeout(r, 5));

  assert.equal(el.innerHTML, 'B: ready',
    'ردّ الشاشة الأولى كتب فوق الثانية — السباق لم يُحَل');
});

test('الإلغاء يُمرَّر إشارةً فتُقطع الشبكة لا الكتابة وحدها', () => {
  assert.match(routerSrc, /AbortController/);
  assert.match(routerSrc, /this\.inflight\?\.abort\(\)/);
  assert.match(routerSrc, /readonly signal: AbortSignal/);
  const api = read('src/services/api.ts');
  assert.match(api, /signal\?: AbortSignal/);
  assert.match(api, /signal\?\.aborted/);
});

test('الإلغاء لا يُعرَض خطأً للمستخدم', () => {
  // المستخدم غادر الشاشة عمداً؛ إظهار خطأ على ذلك يُربك بلا سبب.
  assert.match(routerSrc, /الإلغاء ليس خطأً يُعرَض/);
  assert.match(routerSrc, /if \(isAbortError\(error\)\) return;/);
});

/* ---------------------------------------------------------------------------
   صدق الترقيم
   ------------------------------------------------------------------------ */

test('الصدفة تفصل الإجمالي عن الصفوف', () => {
  const api = read('src/services/api.ts');
  const { envelope } = evalTs(api, ['envelope']);

  // صفحة عادية
  const full = envelope({ rows: [{ a: 1 }], total: 22727, limit: 1, offset: 0, returned: 1 });
  assert.equal(full.total, 22727);
  assert.equal(full.outOfRange, false);

  // وصفحة خارج المدى: صفر صفوف، وإجمالي صادق. هذا هو العيب الذي تُصلحه —
  // العقد القديم كان يفقد الإجمالي مع الصفوف فيُقرأ 22,727 صفراً.
  const beyond = envelope({ rows: [], total: 22727, limit: 50, offset: 99999, returned: 0, out_of_range: true });
  assert.equal(beyond.rows.length, 0);
  assert.equal(beyond.total, 22727, 'الإجمالي ضاع مع الصفحة الفارغة');
  assert.equal(beyond.outOfRange, true);

  // وردٌّ مشوَّه لا ينهار
  assert.equal(envelope(null).total, 0);
  assert.equal(envelope({ rows: 'nope' }).rows.length, 0);
});

/* ---------------------------------------------------------------------------
   العائدية التشغيلية
   ------------------------------------------------------------------------ */

test('التصنيف ثلاثي لا خمسة', () => {
  // FTTH وOffice اسما أبَوين لا صنفَين ماليَّين. جعلُهما صنفَين كان يعني أن
  // كل أبٍ شركاتيّ جديد يحتاج نشرَ واجهة.
  // يُقتطع المصدر عند تركيب المسارات: ما بعده يشير إلى وحداتٍ مستوردة،
  // والمقصود هنا جدول التسميات وحده. والنمط كان قد فقد شرطتيه المائلتين
  // فصار يطابق سطر استيرادٍ واحداً لا كتلته.
  const full = read('src/features/installation/index.ts');
  const s = full.slice(0, full.indexOf('export const routes'));
  const { OWNERSHIP_LABEL } = evalTs(s.replace(/^import[\s\S]*?;$/gm, ''), ['OWNERSHIP_LABEL']);
  assert.deepEqual(Object.keys(OWNERSHIP_LABEL).sort(),
    ['DIRECT_COMPANY', 'NEEDS_REVIEW', 'RESELLER']);
  assert.equal(OWNERSHIP_LABEL.RESELLER, 'وكيل');
  assert.equal(OWNERSHIP_LABEL.DIRECT_COMPANY, 'الشركة');
  assert.equal(OWNERSHIP_LABEL.NEEDS_REVIEW, 'تحتاج مراجعة');
  assert.equal(OWNERSHIP_LABEL.FTTH_USER, undefined);
  assert.equal(OWNERSHIP_LABEL.OFFICE, undefined);
});

test('اسم الأب لا يُستبدَل بتسمية التصنيف', () => {
  // المشغّل يبحث في ملف SaaS عن hrins.office بعينه؛ عرضُ «Office» مكانه
  // يقطع الجسر بين الشاشة والمصدر.
  const home = read('src/features/home/index.ts');
  const reg = read('src/features/installation/index.ts');

  // لا أسماء آباء مثبَّتة في شيفرة الواجهة.
  //
  // التعليقات تُستثنى: شرحُ القاعدة يذكر الأسماء مثالاً، والمقصود منعُ
  // اعتمادِ الشيفرة عليها لا منعُ ذكرها.
  const NL = String.fromCharCode(10);
  const homeCode = home.split(NL).filter((l) => !l.trim().startsWith('//')).join(NL);
  assert.ok(!homeCode.includes('FTTH_Users'), 'اسم أب مثبَّت في الشيفرة');
  assert.ok(!homeCode.includes('hrins.office'), 'اسم أب مثبَّت في الشيفرة');
  assert.doesNotMatch(home, /label">FTTH User</);
  assert.doesNotMatch(home, /label">Office</);

  // التفصيل يأتي من الخادم بالأسماء الحقيقية
  assert.match(home, /company_parent_breakdown/);
  assert.match(home, /parent_name/);
  assert.match(home, /الاسم كما ورد في المصدر/);

  // والسجلّ يعرض الأب لا التصنيف مكانه
  assert.ok(reg.includes('الوكيل / الأب'), 'عمود الأب مفقود');
  assert.match(reg, /الاسم الأصلي كما ورد من المصدر/);
});

test('بطاقة الشركة واحدة بمجموع، وتحتها تفصيل ديناميكي', () => {
  const home = read('src/features/home/index.ts');
  assert.match(home, /مشتركو الشركة/);
  assert.match(home, /ownership: 'DIRECT_COMPANY'/);
  // التفصيل مبنيّ من المصفوفة العائدة لا من قائمة مكتوبة
  assert.ok(home.includes('parents.map('), 'التفصيل ليس مبنيّاً من المصفوفة');
  assert.match(home, /total_subscribers/);
});

test('السجلّ يُرشَّح بالعائدية على الخادم', () => {
  const s = read('src/features/installation/index.ts');
  assert.match(s, /\['ownership', 'p_ownership'\]/);
  assert.match(s, /key: 'ownership'/);
  assert.match(s, /page_installation_subscribers/);
});

test('الصفحة خارج المدى تُقال ولا تُقرأ صفراً', () => {
  const s = read('src/features/installation/index.ts');
  assert.match(s, /page\.outOfRange/);
  assert.match(s, /الصفحة خارج المدى/);
  assert.match(s, /المجموعة فيها \$\{count\(page\.total\)\}/);
});

test('الشاشات تمرّر إشارة الإلغاء إلى الشبكة', () => {
  const s = read('src/features/installation/index.ts');
  assert.match(s, /pageRpc<Row>\('page_installation_subscribers', args, view\.signal\)/);
});

test('الخطأ يُقرأ مهما كان شكل ما رُفض به', () => {
  // «[object Object]» ظهرت فعلاً على الشاشة المنشورة: الطبقة القديمة ترفض
  // بكائن عادي، وString() عليه لا تقول شيئاً إطلاقاً.
  const api = read('src/services/api.ts');
  const { messageOf } = evalTs(api.replace('function messageOf', 'export function messageOf'), ['messageOf']);
  assert.equal(messageOf(new Error('boom')), 'boom');
  assert.equal(messageOf('plain'), 'plain');
  assert.equal(messageOf({ message: 'من الخادم' }), 'من الخادم');
  assert.equal(messageOf({ error_description: 'انتهت الجلسة' }), 'انتهت الجلسة');
  assert.equal(messageOf({ hint: 'تلميح' }), 'تلميح');
  assert.match(messageOf({ code: 'PGRST301' }), /PGRST301/);
  assert.equal(messageOf({}), 'خطأ غير متوقّع');
  assert.equal(messageOf(null), 'خطأ غير متوقّع');
  // ولا يظهر «[object Object]» في أي حالة
  [{}, { a: 1 }, [], null, undefined, 0].forEach((e) => {
    assert.doesNotMatch(messageOf(e), /\[object/, `شكل غير مقروء: ${JSON.stringify(e)}`);
  });
});
