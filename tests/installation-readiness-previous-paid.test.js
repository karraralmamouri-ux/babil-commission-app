// الجاهزية: «مدفوع سابقاً» بجانب «المستحق الآن» — من مصدرين على الخادم، لا
// حساباً من العميل ولا تخميناً. الشاشة كانت تعرض المستحق والمتبقّي والحاجب
// دون أن تقول كم دُفع لهذا المشترك من قبل.
//
// اكتشافٌ مُصحَّح أثناء تدقيق db-regression: الاكتفاء بـ
// installation_entitlements وحده كان يُعيد صفراً لكل مشترك من القاعدة
// التاريخية (وهي بالضبط من يظهر في هذه الشاشة) — تاريخه في
// installation_payment_history، جدولٍ منفصل تماماً يربطه subscriber_uuid لا
// نص المعرّف. previous_paid يجب أن يجمع المصدرين معاً.
//
// الخطر المحروس: أن يمسّ هذا الحقل الإضافي شرط الجاهزية نفسه (is_ready
// وblockers) — وهو عرضٌ فقط، فلا يجوز أن يغيّر من يُعدّ جاهزاً.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');

const migration = read('supabase/migrations/20260930090000_installation_readiness_previous_paid.sql');
const payoutUi = read('src/features/installation/payout.ts');
const baseline = read('supabase/migrations/20260909090000_blocker_categories.sql');

/* ---------------------------------------------------------------------------
   الحساب: مجموع مصدرين مطابَقين بالمشترك، على صفحة النتائج فقط
   ------------------------------------------------------------------------ */

test('previous_paid مجموعٌ من installation_entitlements المدفوع فعلاً', () => {
  assert.match(migration, /coalesce\(sum\(e\.paid_amount\), 0\)/);
  assert.match(migration, /from public\.installation_entitlements e/);
  assert.match(migration, /where e\.subscriber_id = p\.subscriber_id/);
  assert.match(migration, /and e\.payment_status = 'paid'\)/);
});

test('previous_paid يضيف ما دُفع قبل النظام الدوري من installation_payment_history', () => {
  // الجدولان لا يتقاطعان لنفس المرحلة؛ الجمع بينهما هو الرقم الصحيح، لا
  // الاكتفاء بأيّهما وحده.
  assert.match(migration, /\+ \(select coalesce\(sum\(h\.amount\), 0\) from public\.installation_payment_history h/);
  assert.match(migration, /where h\.subscriber_uuid = p\.subscriber_uuid\) as previous_paid/);
  // subscriber_uuid يُحمَل من base نفسها لا استعلاماً إضافياً خارج الصفحة.
  assert.match(migration, /select\s+s\.id as subscriber_uuid, s\.subscriber_id/);
});

test('الحساب يقع على صفحة النتائج المُرجَعة فقط — لا على كامل المرشّحين قبل التصفح', () => {
  // نفس درس 20260920090000: نداءٌ لكل مرشّح قبل التصفح تجاوز مهلة الخادم.
  const pageCte = migration.slice(migration.indexOf('page as ('), migration.indexOf('select p.subscriber_id'));
  assert.match(pageCte, /limit v_lim offset v_off/);
  const finalSelect = migration.slice(migration.indexOf('select p.subscriber_id'), migration.indexOf('into v_total, v_rows'));
  assert.match(finalSelect, /from page p/);
  assert.doesNotMatch(finalSelect, /from filtered f/);
});

test('فهرسٌ يخدم البحث بالمشترك ضمن المدفوع فقط — لا فحصاً كاملاً للجدول', () => {
  assert.match(migration, /create index if not exists installation_entitlements_subscriber_paid_idx/);
  assert.match(migration, /where payment_status = 'paid'/);
});

/* ---------------------------------------------------------------------------
   لا مساس بمنطق الجاهزية — نفس CTEs الحاكمة للحجب والفرز، حرفاً بحرف
   ------------------------------------------------------------------------ */

test('منطق الحجب (judged/kept/filtered) لم يتغيّر حرفاً واحداً', () => {
  const END = 'where p_only_ready is null or k.is_ready = p_only_ready';
  const FN = 'create or replace function public.page_payout_candidate_lines(';
  const extract = (src) => {
    // كلا الملفّين يعرّفان أكثر من دالّة؛ لا بدّ من التضييق إلى
    // page_payout_candidate_lines نفسها قبل البحث عن judged.
    const fnStart = src.indexOf(FN);
    assert.ok(fnStart >= 0, 'الدالّة غير موجودة');
    const from = src.indexOf('judged as (', fnStart);
    const to = src.indexOf(END, from) + END.length;
    assert.ok(from >= 0 && to > from, 'الحدّان غير موجودين');
    return src.slice(from, to).replace(/\s+/g, ' ').trim();
  };
  // الفارق الوحيد المسموح بعد هذه النقطة: إضافة page CTE للصرف قبل الإرجاع
  // — لا تعديل على judged أو kept أو filtered أنفسها.
  assert.equal(extract(migration), extract(baseline));
});

test('توقيع الدالّة والقدرة المطلوبة لم يتغيّرا', () => {
  assert.match(migration, /create or replace function public\.page_payout_candidate_lines\(/);
  assert.match(migration, /perform public\.require_capability\('installation\.view'\);/);
  assert.match(migration, /revoke execute on function public\.page_payout_candidate_lines\(text,text,boolean,integer,integer,text,text\)\s*\n\s*from public, anon;/);
});

/* ---------------------------------------------------------------------------
   الواجهة: الأعمدة الجديدة تُعرض، ولا تُبنى أعمدة الجاهزية الحالية
   ------------------------------------------------------------------------ */

test('سطور الصرف تعرض المدفوع سابقاً والمتبقّي وحالتي الفاتورة والتعليق', () => {
  assert.match(payoutUi, /num\(r, 'previous_paid'\)/);
  assert.match(payoutUi, /money\(num\(r, 'remaining'\)\)/);
  assert.match(payoutUi, /r\['invoice_ok'\] === true \? chip\('مدقَّقة', 'success'\) : chip\('غير مدقَّقة', 'warning'\)/);
  assert.match(payoutUi, /r\['held'\] === true \? chip\('معلَّق', 'critical'\) : chip\('لا تعليق', 'success'\)/);
});

test('الأعمدة الجديدة عرضٌ من حقول موجودة — لا حساب جديد على العميل', () => {
  // previous_paid يأتي من الخادم مباشرةً؛ والمتبقّي وinvoice_ok وheld كانت
  // موجودة في استجابة page_payout_candidate_lines أصلاً ولم تكن تُعرض.
  assert.doesNotMatch(payoutUi, /previous_paid\s*[-+*/]/);
});

test('عمودا الحالة والحاجب لا يزالان قائمين بلا تعديل', () => {
  assert.match(payoutUi, /r\['is_ready'\] === true \? chip\('جاهز', 'success'\) : chip\('محجوب', 'critical'\)/);
  assert.match(payoutUi, /const list = \(r\['blockers'\] \|\| \[\]\) as string\[\];/);
});
