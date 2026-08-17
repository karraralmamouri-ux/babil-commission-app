-- إغلاق ثغرة TRUNCATE على app_settings.
--
-- لماذا. أُنشئ الجدول في 20260809190000 بسطر واحد:
--
--     grant select on table public.app_settings to authenticated;
--
-- بلا `revoke all` قبله. امتيازات Supabase الافتراضية تكون قد منحت ALL على
-- الجداول الجديدة لدور authenticated، فالمنح الصريح لم يُضف شيئاً وتركت
-- الامتيازات الباقية في مكانها. الحالة الفعلية على الإنتاج اليوم:
--
--     app_settings : authenticated = MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE
--
-- بينما بقية الجداول المالية SELECT فقط.
--
-- الخطورة. TRUNCATE لا يخضع لسياسات الصفوف، فسياسة القراءة الوحيدة على
-- الجدول لا تحميه. أي مستخدم مسجّل الدخول بأي دور — بما فيه viewer — يستطيع
-- إفراغ الجدول. وهو يحمل صفاً واحداً بمفتاح raw_import يحتوي:
--   • ربط الوكلاء بحسابات SaaS (aliases)
--   • نطاقات الكابينات: FDT ← الوكيل المالك
--   • قائمة الباقات المؤهِّلة
-- أي أن إفراغه يُسقط الأساس الذي يُحدَّد به **من يُدفع له** في أول استيراد
-- لاحق، ولا توجد نسخة أخرى في القاعدة.
--
-- هذا نفس العيب الذي عولج لجداول التنصيب في 20260815180000، وهو باقٍ هنا
-- لأن ذلك الإصلاح لم يشمل هذا الجدول.
--
-- إضافية بالكامل: لا بيانات تتغير، ولا جدول يُعدَّل أو يُحذف، ولا سياسة
-- تُمسّ. forward-only.

begin;

-- revoke all أولاً وليس قائمة أفعال: القائمة هي بالضبط ما ترك الثغرة أول مرة.
revoke all on table public.app_settings from authenticated;
grant select on table public.app_settings to authenticated;

-- anon وPUBLIC لا يملكان شيئاً على الإنتاج اليوم؛ السحب صريح كي لا يعيد
-- امتياز افتراضي مستقبلي فتحَ ما أُغلق هنا.
revoke all on table public.app_settings from anon;
revoke all on table public.app_settings from public;

-- ما لا تمسّه هذه المهاجرة عمداً:
--   • postgres (المالك) وservice_role يحتفظان بصلاحياتهما الكاملة. الأول مالك
--     الجدول، والثاني دور الخلفية الموثوق الذي تعمل به Edge Functions.
--   • RLS وسياسة القراءة الوحيدة تبقيان كما هما.
--   • مسار الكتابة الوحيد يبقى save_import_settings: وهي SECURITY DEFINER
--     مملوكة لـpostgres بـsearch_path مثبَّت، فتنفّذ بصلاحيات المالك ولا
--     تتأثر بسحب صلاحيات الجدول عن authenticated. الفحص قبل النشر يؤكد ذلك.
--   • لا صف يُقرأ أو يُكتب أو يُحذف. هذه مهاجرة صلاحيات بحتة.

commit;
