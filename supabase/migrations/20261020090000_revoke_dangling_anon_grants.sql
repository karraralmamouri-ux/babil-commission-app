-- تدقيق أمني: جرد كل الدوال في public، وفحص من يملك EXECUTE فعلياً (لا
-- افتراضاً) عبر has_function_privilege — لا الثقة بأن كل دالة أُغلقت لمجرد
-- أن أغلبها فعلت. القاعدة موزَّعة على ١١ ملف هجرة يستعمل كلٌّ منها حلقة
-- `do $$ foreach f in array [...] loop revoke...grant... end loop $$` جماعية
-- (مثال: 20260822120000:371-388 لطبقة التقارير، و20260827090000:73-76
-- لدوال نافذة الدورة) — فكثيرٌ مما بدا "بلا سطر revoke صريح" عند بحثٍ نصّي
-- ساذج تبيَّن أنه مغطّى ضمن إحدى هذه الحلقات الديناميكية، وقرارُ من كتبها أن
-- authenticated يبقى مخوَّلاً. لذلك اقتصر هذا الملف على ما تحقَّق أنه سهوٌ
-- كاملٌ لا قرار وراءه في أي مكان: لا `revoke` ولا `grant` قط لهاتين
-- الدالّتين في تاريخ الهجرات كله، فبقيتا على منحة EXECUTE الافتراضية التي
-- يمنحها CREATE FUNCTION تلقائياً لـPUBLIC — سهوٌ من طراز 20261017090000
-- (publish_commission_month) نفسه.
--
--   assert_cycle_correctable(uuid): security definer، تتجاوز RLS على
--   commission_cycles، ولا تتحقق من auth.uid() ولا أي قدرة. أي طرفٍ غير
--   مصادَق يستطيع اليوم استدعاءها مباشرة عبر PostgREST RPC ليحصل على: وجود
--   cycle_id بعينه من عدمه (رسالة الخطأ تفصح)، وحالته المالية الفعلية
--   (FINALIZED/PAID/PARTIALLY_PAID/CLOSED تظهر صراحة في نص خطأ آخر).
--   استدعاءاتها الثلاثة كلها (20260923090000:510,605,693) من دوال
--   security definer أخرى تتحقق من القدرة قبل الوصول إليها — لم تكن مقصودة
--   كنقطة دخول مباشرة أصلاً، فتُغلَق بالكامل: لا public ولا anon ولا
--   authenticated. مطابقةٌ لنمط الإغلاق الكامل الذي تحمله دوالّ مساعدة
--   داخلية أخرى مثل installation_amount_for_stage.
--
--   flag_overlapping_batches_for_revalidation(): دالّة trigger لا RPC؛
--   استدعاؤها المباشر خارج سياق trigger يفشل لغياب NEW/OLD، فالمخاطرة
--   العملية معدومة، لكن إغلاقها الكامل لا يكلف شيئاً ويطابق النمط نفسه.
--
-- ما لم يُغلَق هنا بالكامل، عمداً: ٢٤ دالّة أخرى ظهرت في الفحص الأول بلا فحص
-- قدرة ظاهر داخلها، لكن تبيَّن أن كل واحدة منها إما مذكورة صراحة في إحدى حلقات
-- المنح الجماعية أعلاه (قرارٌ موثَّق، لا يُنقَض هنا)، أو أن إحدى الدوال
-- الأخرى تستدعيها مباشرةً كـ`authenticated` (مثال ملموس: commission_payout
-- test:209 يستدعي commission_cycle_financials مباشرة، وهي مذكورة صراحة في
-- حلقة 20260822120000:375). محاولة تخمين أي الباقي آمنٌ إغلاقه بلا نفس
-- التحقق التفصيلي قرارٌ يفوق نطاق "سهوٌ تقني مؤكَّد" الذي يبرر هذا الملف.
--
-- فجوة ثانية، أضيق وأوضح: أربع دوال (business_timezone، cycle_window_start،
-- cycle_window_end، commission_version_for_cycle) — 20260827090000:73-76,376 —
-- تحمل `grant ... to authenticated` صريحاً (قرارٌ مقصود، لا يُمَس هنا) لكن بلا
-- `revoke ... from public, anon` المرافق الذي يحمله كل نظير آخر لها في هذا
-- المشروع (قارن حلقة 20260822120000:371-388: كل عنصر فيها يحصل السطرين معاً).
-- بحثٌ في كل ملفات الهجرة لهذه الأربعة تحديداً لم يُظهر أي `revoke` قط — نصف
-- البويلربليت المعتاد كُتب ونصفه سقط سهواً. هذه لا تُغلَق بالكامل (authenticated
-- تبقى كما قُصد)، بل يُستكمَل لها الشطر الناقص فقط.

begin;

revoke execute on function public.assert_cycle_correctable(uuid)
  from public, anon, authenticated;
revoke execute on function public.flag_overlapping_batches_for_revalidation()
  from public, anon, authenticated;

revoke execute on function public.business_timezone()
  from public, anon;
revoke execute on function public.cycle_window_start(date)
  from public, anon;
revoke execute on function public.cycle_window_end(date)
  from public, anon;
revoke execute on function public.commission_version_for_cycle(uuid)
  from public, anon;

commit;
