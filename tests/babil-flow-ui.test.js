// BABIL FLOW — واجهة العرض.
//
// ما يُختبر هنا سلوكُ عرضٍ لا قاعدةُ عمل: التسمية، والحالة، والاتجاه، وفصل
// المحسوب عن المحجوب، وإخفاء ما لا صلاحية له. القاعدة المالية تُختبر في
// مجموعات القاعدة، ولا تُكرَّر هنا ولا تُشتق.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
const css = fs.readFileSync(path.join(root, 'assets', 'css', 'babil-flow.css'), 'utf8');

/**
 * كل ورقة أنماط تربطها الصفحة، لا الأولى وحدها.
 *
 * قراءة ورقةٍ واحدة تُسقط صنفاً معرَّفاً في ورقةٍ أخرى مربوطة فيبدو بلا
 * نمط. المرجع هنا ما تُحمِّله الصفحة فعلاً.
 */
const LINK_RE = new RegExp(String.raw`<link rel="stylesheet" href="./([^"]+)">`, "g");
const linkedCss = [...html.matchAll(LINK_RE)]
  .map((m) => fs.readFileSync(path.join(root, m[1]), 'utf8'))
  .join(String.fromCharCode(10));
const Reporting = require('../assets/js/reporting.js');
const CommissionVNext = require('../assets/js/commission-vnext.js');

/* ---------------------------------------------------------------------------
   العلامة
   ------------------------------------------------------------------------ */

test('العلامة معلنة بالاسم والوصف المعتمدين', () => {
  assert.match(html, /<title>BABIL FLOW — Reseller Financial Operations<\/title>/);
  assert.match(html, /BABIL FLOW/);
  assert.match(html, /Reseller Financial Operations/);
});

test('رموز العلامة الأربعة معرَّفة بدرجاتها المعتمدة', () => {
  const tokens = { '--navy': '#0B1930', '--gold': '#C9972B', '--cloud': '#F8FAFC', '--slate': '#64748B' };
  Object.entries(tokens).forEach(([name, value]) => {
    assert.match(css, new RegExp(`${name}:\\s*${value}`, 'i'), `${name} مفقود أو مختلف`);
  });
});

test('الألوان الدلالية الأربعة معرَّفة', () => {
  const tokens = { '--success': '#16A36A', '--warning': '#D98B18', '--critical': '#DC4C4C', '--info': '#3478F6' };
  Object.entries(tokens).forEach(([name, value]) => {
    assert.match(css, new RegExp(`${name}:\\s*${value}`, 'i'), `${name} مفقود`);
  });
});

test('الشعار مضمَّن ولا يُحمَّل من شبكة خارجية', () => {
  // العلامة رمز SVG داخل الصفحة: لا طلب خارجي، ولا فشل عند انقطاع الشبكة.
  assert.match(html, /<symbol id="bfMark"/);
  assert.match(html, /<symbol id="bfMarkLight"/);
  assert.doesNotMatch(html, /<img[^>]+src="https?:/);
});

test('لا خط ولا نمط يُجلب من خادم طرف ثالث', () => {
  // التتبّع والعطل يدخلان من هنا في تطبيق مالي مغلق.
  assert.doesNotMatch(html, /fonts\.googleapis|fonts\.gstatic|cdn\.jsdelivr|unpkg\.com|cdnjs/i);
  assert.doesNotMatch(css, /@import\s+url\(\s*['"]?https?:/i);
});

/* ---------------------------------------------------------------------------
   الاتجاه
   ------------------------------------------------------------------------ */

test('الصفحة عربية RTL في جذرها', () => {
  assert.match(html, /<html lang="ar" dir="rtl">/);
});

test('التخطيط منطقي لا مثبَّت بيمين ويسار', () => {
  // القاعدة: الشريط عمودٌ أول، والعمود الأول يقع عند بداية السطر — يمين في
  // العربية ويسار في الإنجليزية. لا إحداثيات مادّية في قواعد التخطيط.
  assert.match(css, /grid-template-columns: var\(--sidebar-w\) minmax\(0, 1fr\)/);
  assert.match(css, /\.sidebar \{\s*grid-column: 1;/);

  // inset-inline-end في RTL يعني اليسار. استعماله لتثبيت الدرج على اليمين
  // كان يترك الدرج المغلق ظاهراً في وسط الشاشة.
  const drawer = css.slice(css.indexOf('@media (max-width: 860px)'));
  assert.match(drawer, /\.sidebar \{[^}]*inset-inline-start: 0/);
  assert.doesNotMatch(drawer, /\.sidebar \{[^}]*inset-inline-end: 0/);
});

test('العمود المفتاحي يُحاذى إلى بداية السطر لا إلى يمين ثابت', () => {
  assert.match(css, /td:first-child, th:first-child \{ text-align: start; \}/);
});

/* ---------------------------------------------------------------------------
   حالة الدورة
   ------------------------------------------------------------------------ */

test('كل حالة فعلية تُنسب إلى مرحلة معروضة', () => {
  Reporting.CYCLE_FLOW.forEach((status) => {
    const stage = Reporting.cycleStage(status);
    assert.ok(stage, `${status} بلا مرحلة معروضة`);
    assert.ok(stage.label, `${status} بلا تسمية`);
  });
});

test('المراحل المعروضة خمس بالترتيب المعتمد', () => {
  assert.deepEqual(Reporting.CYCLE_STAGES.map((s) => s.label),
    ['مسودة', 'مراجعة', 'معتمدة', 'جاهزة للصرف', 'مغلقة']);
});

test('الحالة المجهولة لا تُنسب إلى مرحلة مخترَعة', () => {
  assert.equal(Reporting.cycleStage('SOMETHING_NEW'), null);
});

test('ما قبل الاعتماد تقديري، وما بعده ليس كذلك', () => {
  // هذا هو الحارس ضدّ أن يبدو الرقم المتوقَّع نهائياً.
  ['DRAFT', 'DATA_IMPORTED', 'UNDER_REVIEW', 'READY_TO_FINALIZE'].forEach((s) => {
    assert.equal(Reporting.isProjected(s), true, `${s} يجب أن يكون تقديرياً`);
  });
  ['FINALIZED', 'PARTIALLY_PAID', 'PAID', 'CLOSED'].forEach((s) => {
    assert.equal(Reporting.isProjected(s), false, `${s} ليس تقديرياً`);
  });
});

test('الرأس يعرض وسم «تقديري» للدورة غير المعتمدة وحدها', () => {
  assert.match(html, /projected-tag/);
  assert.match(html, /Reporting\.isProjected\(cycle\.status\)/);
  assert.match(html, /projected\?[^:]*تقديري/);
});

test('الحالة لا تُقال باللون وحده', () => {
  // لكل حالة نصّها ونقطتها؛ عمى الألوان لا يُسقط المعنى.
  Reporting.CYCLE_STAGES.forEach((s) => {
    assert.match(css, new RegExp(`\\.${s.css}\\b`), `${s.css} بلا نمط`);
  });
  assert.match(html, /<span class="dot" aria-hidden="true"><\/span>\$\{esc\(stage\.statusLabel\)\}/);
});

/* ---------------------------------------------------------------------------
   المال
   ------------------------------------------------------------------------ */

test('صيغة المبلغ واحدة في كل الشاشات', () => {
  assert.equal(Reporting.money(37059000), '37,059,000 د.ع');
  assert.equal(Reporting.money(0), '0 د.ع');
  assert.equal(Reporting.amount(1234567), '1,234,567');
});

test('الدينار بلا كسور', () => {
  assert.equal(Reporting.amount(1500.4), '1,500');
  assert.equal(Reporting.amount(1500.6), '1,501');
});

test('الأرقام المالية بعرض ثابت', () => {
  // بدون tabular-nums تتراقص المنازل فيتعذّر مسح العمود بصرياً.
  assert.match(css, /font-variant-numeric: tabular-nums/);
  assert.match(css, /\.money[^{]*\{[\s\S]{0,200}?font-variant-numeric: tabular-nums/);
});

test('المحسوب والمحجوب لا يُدمجان في رقم واحد', () => {
  assert.match(css, /\.split-money/);
  assert.match(css, /\.split-money \.released/);
  assert.match(css, /\.split-money \.blocked/);
  assert.match(html, /id="commissionBlocked"/);
  assert.match(html, /id="blockedTotal"/);
});

test('الحقل غير المحمَّل يبدأ بشرطة لا بصفر', () => {
  // الصفر يُقرأ «لا شيء موقوف» فيُغلق طابور مفتوح. الشرطة تقول «لم يُحمَّل».
  ['blockedTotal', 'commissionBlocked', 'installDue', 'installHeld', 'installPaid'].forEach((id) => {
    assert.match(html, new RegExp(`id="${id}">—<`), `${id} يبدأ بقيمة تُقرأ حقيقةً`);
  });
});

test('تعذُّر التقرير يترك الشرطة ولا يكتب صفراً', () => {
  assert.match(html, /function setExecUnavailable\(\)/);
  assert.match(html, /el\.textContent="—"/);
});

test('لا تسعير في المتصفح: الواجهة تقرأ تقرير الخادم', () => {
  assert.match(html, /report_management_summary/);
  assert.match(html, /report_commission_exception_impact/);
  // لا معدّلات ولا حدود شرائح مكتوبة في الواجهة
  assert.doesNotMatch(html, /\b(4000|4750|5500|6000|8000|11500)\s*\*/);
});

/* ---------------------------------------------------------------------------
   الشريحة والأحداث مفهومان منفصلان
   ------------------------------------------------------------------------ */

test('أساس الشريحة والأحداث المؤهَّلة يُعرضان منفصلين وبتفسيرهما', () => {
  assert.ok(CommissionVNext.METRICS.tierBasis.label);
  assert.ok(CommissionVNext.METRICS.tierBasis.hint);
  assert.ok(CommissionVNext.METRICS.billable.label);
  assert.ok(CommissionVNext.METRICS.billable.hint);
  assert.notEqual(CommissionVNext.METRICS.tierBasis.label, CommissionVNext.METRICS.billable.label);
});

/* ---------------------------------------------------------------------------
   الاستثناءات
   ------------------------------------------------------------------------ */

test('كل سبب استثناء يحمل جهةً وإجراءً', () => {
  ['UNKNOWN_FDT', 'UNKNOWN_AGENT', 'SOURCE_INCOMPLETE', 'UNKNOWN_PACKAGE'].forEach((code) => {
    const play = CommissionVNext.exceptionPlaybook(code);
    assert.ok(play.owner && play.owner !== '—', `${code} بلا جهة`);
    assert.ok(play.action, `${code} بلا إجراء`);
    assert.ok(play.target, `${code} بلا شاشة يُحسم فيها`);
  });
});

test('الكابينة المجهولة تقود إلى شاشة تصنيفها', () => {
  assert.equal(CommissionVNext.exceptionPlaybook('UNKNOWN_FDT').target, 'fdtOnboarding');
  assert.match(html, /function focusFdtOnboarding\(\)/);
  assert.match(html, /jumpToExceptionAction/);
});

test('لا استثناء يُحيل إلى المطوّر', () => {
  const forbidden = /مطوّر|المطور|developer|engineer/i;
  Object.entries(CommissionVNext.EXCEPTION_PLAYBOOK).forEach(([code, play]) => {
    assert.ok(!forbidden.test(play.action), `${code} يطلب تدخّلاً هندسياً`);
    assert.ok(!forbidden.test(play.owner), `${code} يُحمّل الهندسة المسؤولية`);
  });
});

/* ---------------------------------------------------------------------------
   الملاحة والصلاحيات
   ------------------------------------------------------------------------ */

// الملاحة انتقلت من ترميز index.html إلى src/app/shell.ts. التوكيدان أدناه
// يتبعانها إلى مصدرها الجديد بقوّتهما نفسها — لا يُضعَّفان ولا يُحذفان.
const shell = fs.readFileSync(path.join(root, 'src', 'app', 'shell.ts'), 'utf8');

test('معمارية الملاحة المعتمدة كاملة', () => {
  // الترتيب صار يتبع السؤال لا الجدول: نتيجة ← قرار ← بيانات ← نظام.
  // كان مرتَّباً بالمحرّكات (عمولات، تنصيب، مالية)، فلا يقول أيّ شاشةٍ
  // نتيجةٌ وأيّها قرار.
  ['النتائج المالية', 'البيانات', 'النظام']
    .forEach((label) => assert.match(shell, new RegExp(label), `${label} مفقود من الملاحة`));
  ['results', 'work', 'data', 'system']
    .forEach((key) => assert.match(shell, new RegExp(`key: '${key}'`), `${key} مفقود`));

  // مركز العمل بندٌ أوّل لا مجموعة: هو مدخل القرارات كلّها.
  assert.match(shell, /مركز العمل/);

  // وكل مجموعة تقود إلى شاشات مستقلّة لا إلى لوحة واحدة.
  const paths = [...shell.matchAll(/path:\s*'([^']+)'/g)]
    .map((m) => m[1])
    // مسارات السياق تُذكر في قائمةٍ منفصلة، ولا تُعدّ وجهات ملاحة.
    .filter((p) => !shell.slice(shell.indexOf('CONTEXTUAL_ROUTES')).includes(`'${p}'`));
  assert.equal(paths.length, new Set(paths).size, 'وجهتان متطابقتان في الملاحة');
});

test('ما خرج من الشريط لم يخرج من المُوجِّه', () => {
  // إخراج شاشةٍ من القائمة العامة لا يعني حذفها: تُبلَغ من سياقها. ولو
  // سقط مسارٌ من المُوجِّه لصار رابطاً عميقاً مكسوراً بلا أن يلاحظ أحد.
  const contextual = [...shell.slice(shell.indexOf('CONTEXTUAL_ROUTES'))
    .matchAll(/'(\/[^']+)'/g)].map((m) => m[1]);
  assert.ok(contextual.length >= 10, `expected contextual routes, found ${contextual.length}`);

  const featureDir = path.join(root, 'src', 'features');
  const sources = fs.readdirSync(featureDir, { recursive: true })
    .filter((f) => String(f).endsWith('.ts'))
    .map((f) => fs.readFileSync(path.join(featureDir, String(f)), 'utf8'));
  const patterns = new Set(sources.flatMap((s) =>
    [...s.matchAll(/pattern:\s*'([^']+)'/g)].map((m) => m[1])));

  for (const route of contextual) {
    assert.ok(patterns.has(route), `مسار سياقي غير مسجَّل في المُوجِّه: ${route}`);
  }
});

test('ما لا صلاحية له يُخفى لا يُعطَّل فقط', () => {
  // الإخفاء راحةٌ للمستخدم؛ والحارس الحقيقي على الخادم. كلاهما مطلوب.
  // الشاشات الجديدة تُرشَّح بالقدرة في الشريط وفي الموجِّه معاً.
  assert.match(shell, /capability: '[a-z.]+'/);
  assert.match(shell, /items\.filter\(\(i\) => !i\.capability \|\| can\(i\.capability\)\)/);
  const router = fs.readFileSync(path.join(root, 'src', 'app', 'router.ts'), 'utf8');
  assert.match(router, /route\.capability && !this\.options\.can\(route\.capability\)/);
  // والشاشات التي لم تُهاجَر بعد تحتفظ بحارسها القديم في index.html.
  assert.match(html, /data-permission="edit"/);
  assert.match(html, /data-permission="rates"/);
  assert.match(html, /function applyPermissions\(\)/);
});

test('إخفاء الزر لا يُغني عن حارس الخادم', () => {
  // الاستدعاءات المالية تمرّ بدوال RPC تفحص القدرة داخلها.
  // تسجيل الكابينات انتقل إلى التطبيق الجديد، فيُفحص حارسه حيث صار.
  const fdts = fs.readFileSync(path.join(root, 'src/features/master/fdts.ts'), 'utf8');
  assert.ok(fdts.includes(String.fromCharCode(39) + 'register_fdt' + String.fromCharCode(39)), 'حارس التسجيل مفقود');
  const commissions = fs.readFileSync(path.join(root, 'src/features/commissions/index.ts'), 'utf8');
  assert.ok(commissions.includes('recalculate_cycle_after_master_change'), 'إعادة الحساب لم تنتقل');
});

/* ---------------------------------------------------------------------------
   الشاشات السابقة: للقراءة التاريخية لا للكتابة
   ------------------------------------------------------------------------ */

test('لا كتابة باقية في الشاشات السابقة', () => {
  // السلطة المزدوجة هي أن تكتب شاشتان على الحقيقة نفسها. وعلاجها ليس إخفاء
  // إحداهما بل إيقاف كتابتها، فيبقى للرقم مصدرٌ واحد.
  const WRITES = [
    'import_installation_entitlements', 'import_installation_history',
    'publish_commission_month', 'record_installation_payment', 'save_import_settings',
    'record_commission_payment', 'set_user_permission', 'resolve_commission_exception',
    'calculate_commission_cycle', 'reopen_commission_cycle', 'close_commission_cycle',
    'export_commission_cycle', 'revalidate_commission_batch', 'post_commission_batch',
    'recalculate_cycle_after_master_change', 'register_fdt', 'register_fdt_bulk',
    'audit_installation_invoice', 'upsert_agent', 'upsert_package', 'update_user_profile',
    'open_commission_cycle',
  ];
  const found = WRITES.filter((name) => html.includes('rpc/' + name));
  assert.deepStrictEqual(found, [], 'كتابات باقية في الشاشات السابقة');

  // والقائمة أعلاه تُعدّ يدوياً، فلا يكفي أن تمرّ: كل نداءٍ باقٍ يجب أن
  // يبدو قراءةً باسمه. اسمٌ لا ينطبق عليه ذلك يسقط الاختبار حتى لو كان
  // بريئاً — ومراجعته أرخص من كتابةٍ تعود من حيث لا يُنتبَه.
  const called = [...html.matchAll(/rpc\/([a-z_]+)/g)].map((m) => m[1]);
  const notRead = [...new Set(called)].filter((name) =>
    !/^(report_|list_|page_)/.test(name)
    && !/(_profile|_summary|_detail|_financials|_eligibility|_capabilities|_state)$/.test(name));
  assert.deepStrictEqual(notRead, [], 'نداءٌ لا يبدو قراءة');

  // ودالّة الحافة لا تُستدعى من هناك إلا بالقراءة.
  const actions = [...html.matchAll(/callAdminUsers\('([a-z]+)'/g)].map((m) => m[1]);
  assert.deepStrictEqual([...new Set(actions)], ['list']);
});

test('أهداف اللمس تتبع نوع المؤشِّر لا عرض الشاشة', () => {
  // كانت قواعد اللمس داخل حدّ 720px، فكان اللوح ذو 768 يقع خارجها ويرث
  // مقاسات الفأرة: 22px في جدول المستخدمين على شاشةٍ تُلمس بالإصبع. والعرض
  // لم يكن يوماً هو السؤال — السؤال أإصبعٌ أم مؤشِّر.
  // نهايات الأسطر تختلف في هذا المستودع، فتُوحَّد قبل القصّ.
  const LF = String.fromCharCode(10);
  const CR = String.fromCharCode(13);
  const flat = css.split(CR + LF).join(LF);
  const block = flat.slice(flat.indexOf('@media (pointer: coarse)'));
  assert.ok(block.startsWith('@media (pointer: coarse)'), 'لا قاعدة مبنيّة على نوع المؤشِّر');

  const body = block.slice(0, block.indexOf(LF + '}' + LF, block.indexOf('{')) + 3);
  for (const selector of ['.btn', '.smallbtn', '.search', '.select']) {
    assert.ok(body.includes(selector), `هدف اللمس ${selector} خارج القاعدة`);
  }
  assert.match(body, /min-height:\s*44px/);

  // ولا تعود القاعدة إلى حدّ العرض: رقمٌ دون 44 داخل كتلة 720px يُسقط الاختبار.
  const narrow = flat.slice(flat.indexOf('@media (max-width: 720px)'));
  const narrowBody = narrow.slice(0, narrow.indexOf(LF + '}' + LF));
  const shortTargets = [...narrowBody.matchAll(/min-height:\s*(\d+)px/g)]
    .map((m) => Number(m[1])).filter((n) => n > 0 && n < 44);
  assert.deepStrictEqual(shortTargets, [], 'هدف لمسٍ دون 44px عاد إلى قاعدة العرض');
});

test('الشاشات السابقة تُعلن أنها للعرض التاريخي', () => {
  // رقمٌ صحيحٌ تاريخياً يُقرأ كأنه اليوم ما لم يُقل غير ذلك.
  assert.match(html, /id="legacyBanner"/);
  assert.match(html, /نسخة قديمة — للعرض التاريخي فقط/);
});

test('طيّ الشريط والمجموعات يُحفظ بأمان', () => {
  assert.match(html, /function toggleSidebarCollapsed\(force\)/);
  assert.match(html, /function toggleNavGroup\(key,force\)/);
  // التخزين المعطوب لا يجوز أن يمنع التشغيل
  assert.match(html, /function bfRead\(key,fallback\)\{try\{/);
  assert.match(html, /catch\(_\)\{return fallback\}/);
});

/* ---------------------------------------------------------------------------
   الحالات
   ------------------------------------------------------------------------ */

test('لكل شاشة حالات تحميل وفراغ وخطأ وانعدام صلاحية', () => {
  assert.match(html, /id="loadingState"/);
  assert.match(html, /id="emptyState"/);
  assert.match(html, /id="centralError"/);
  ['.loading-state', '.empty-state', '.error-state', '.no-permission', '.skeleton']
    .forEach((sel) => assert.match(css, new RegExp(sel.replace('.', '\\.')), `${sel} بلا نمط`));
});

/* ---------------------------------------------------------------------------
   إمكانية الوصول
   ------------------------------------------------------------------------ */

test('التركيز مرئي ورابط التخطّي موجود', () => {
  assert.match(css, /:focus-visible \{[^}]*outline: 2px solid/);
  assert.match(css, /\.skip-link/);
  assert.match(html, /class="skip-link"/);
});

test('الأزرار الأيقونية تحمل تسميةً لقارئ الشاشة', () => {
  const iconOnly = [...html.matchAll(/<button[^>]*>[\s]*[⚠↩⟨☰][\s]*<\/button>/g)];
  iconOnly.forEach((m) => assert.match(m[0], /aria-label=/, 'زر أيقوني بلا تسمية'));
  assert.match(html, /id="whAttention"[\s\S]{0,200}aria-label=/);
  assert.match(html, /id="logoutButton"[^>]*aria-label=/);
  assert.match(html, /id="sidebarToggle"[\s\S]{0,160}aria-label=/);
});

test('مساحة اللمس كافية على الجوّال', () => {
  // كان هذا الاختبار يثبّت 42 للزرّ و38 للصغير، فيحرس الرقم الخاطئ: كلاهما
  // دون 44، وهي أصغر مساحةٍ يُصيبها الإبهام دون خطأ. القاعدة صارت مبنيّة
  // على نوع المؤشِّر، ويحرسها اختبارٌ مستقلّ أعلاه.
  const coarse = css.slice(css.indexOf('@media (pointer: coarse)'));
  assert.match(coarse, /min-height:\s*44px/);
  assert.ok(coarse.includes('.btn') && coarse.includes('.smallbtn'));
});

test('الحركة تُحترم لمن يطلب تقليلها', () => {
  assert.match(css, /@media \(prefers-reduced-motion: reduce\)/);
});

test('الذهبي لا يكون نصاً على خلفية فاتحة', () => {
  // #C9972B على أبيض = 2.64:1، دون الحدّ بكثير. فهو يُستعمل نصاً على الكحلي
  // (6.64:1) أو حشواً أو حدّاً — والقاعدة تُقفل هنا حتى لا تُنقض لاحقاً سهواً.
  const goldText = [...css.matchAll(/([^{}]+)\{([^}]*color: var\(--gold\)[^}]*)\}/g)]
    .map((m) => ({ sel: m[1].trim(), body: m[2] }))
    // ما ليس لون نصّ لا يعنينا: الحدود والمخطَّطات والإطارات
    .filter((r) => /(^|;|\s)color: var\(--gold\)/.test(r.body));
  goldText.forEach((r) => {
    assert.match(r.sel, /sidebar|side-btn/,
      `الذهبي نصّاً خارج الشريط الكحلي: ${r.sel}`);
  });
});

test('كل لون دلالي له درجة حبر للنص على فاتح', () => {
  ['success', 'warning', 'critical', 'info'].forEach((name) => {
    assert.match(css, new RegExp(`--${name}-ink:`), `${name} بلا درجة نصّ`);
    assert.match(css, new RegExp(`--${name}-bg:`), `${name} بلا درجة خلفية`);
  });
});

/* ---------------------------------------------------------------------------
   الاستجابة
   ------------------------------------------------------------------------ */

test('نقاط القياس تغطي المكتب واللوحي والجوّال', () => {
  [1400, 1200, 960, 860, 720].forEach((w) =>
    assert.match(css, new RegExp(`@media \\(max-width: ${w}px\\)`), `نقطة ${w} مفقودة`));
});

test('عدد الأعمدة صنفٌ لا نمطٌ سطري', () => {
  // النمط السطري يتغلّب على استعلام الوسائط، فيبقى الصفّ أربعة أعمدة على 375px.
  assert.match(html, /class="cards cards-4"/);
  assert.doesNotMatch(html, /class="cards"[^>]*style="grid-template-columns/);
  const mobile = css.slice(css.indexOf('@media (max-width: 720px)'));
  assert.match(mobile, /\.cards, \.cards-4[^{]*\{ grid-template-columns: 1fr/);
});

test('الجدول العريض يصير بطاقات على الشاشة الضيّقة', () => {
  const mobile = css.slice(css.indexOf('@media (max-width: 720px)'));
  assert.match(mobile, /\.responsive-cards td::before \{\s*content: attr\(data-label\)/);
  assert.match(mobile, /\.responsive-cards table \{ min-width: 0/);
});

test('المحتوى العريض يمرّر داخل حاويته لا في جسد الصفحة', () => {
  assert.match(css, /\.table-wrap \{[^}]*overflow: auto/);
  assert.match(css, /\.sticky-table \{ overflow: auto; \}/);
});

/* ---------------------------------------------------------------------------
   نظافة الأنماط
   ------------------------------------------------------------------------ */

test('الأنماط في ملفها لا داخل الصفحة', () => {
  assert.match(html, /<link rel="stylesheet" href="\.\/assets\/css\/babil-flow\.css">/);
  assert.doesNotMatch(html, /<style>/);
});

test('كل صنف تستعمله الصفحة معرَّف في نظام التصميم', () => {
  // الأصناف المبنيّة داخل قوالب نصية تُستبعَد: شظاياها ليست أصنافاً.
  const literal = /^[a-zA-Z][\w-]*$/;
  const used = new Set();
  for (const m of html.matchAll(/class="([^"]+)"/g)) {
    m[1].split(/\s+/).forEach((c) => { if (literal.test(c)) used.add(c); });
  }
  const defined = new Set();
  for (const m of linkedCss.matchAll(/\.([a-zA-Z][\w-]*)/g)) defined.add(m[1]);
  const missing = [...used].filter((c) => !defined.has(c)).sort();
  assert.deepEqual(missing, [], `أصناف بلا نمط: ${missing.join(', ')}`);
});
