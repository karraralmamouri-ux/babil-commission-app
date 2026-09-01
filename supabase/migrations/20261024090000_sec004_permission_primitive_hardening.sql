-- SEC-004: تدقيق شامل لكل ٢١٠ دالّة SECURITY DEFINER الفعّالة اليوم (٨٩
-- هجرة)، عبر has_function_privilege الفعلي — لا نصّاً بحثاً عن "grant/revoke"
-- (١١ هجرة تمنح/تسحب عبر حلقة `do $$ foreach ... loop execute format(...)`
-- ديناميكية، يفوتها أي grep نصّي). النتيجة: الانضباط هنا استثنائي بالفعل —
-- ALTER DEFAULT PRIVILEGES مرّتين مبكراً (20260804230000، 20260809190000)
-- يعني كل دالّة أُنشئت بعدها بلا PUBLIC افتراضياً أصلاً، لا أنها "نُسيت
-- فبقيت مفتوحة". من بين ٢١٠ دالّة، لا واحدة تحمل PUBLIC أو anon فعلياً.
-- فلا "revoke جماعي" هنا — القاعدة نفسها التي ينصّ عليها الطلب: لا سحبٌ
-- أعمى حين لا خللَ فعلياً موجوداً.
--
-- ما وُجد فعلاً، ضيّقاً ومحدَّداً:
--
--   effective_permission(uuid,text,text,text) وexplain_permission(uuid,
--   text,text,text): كلتاهما SECURITY DEFINER، ممنوحتان لـauthenticated
--   (20260820090000:505-518)، وكلتاهما تأخذان p_user_id تعسفياً بلا أي
--   تحقّق أنه auth.uid() الطالب نفسه. كل مستدعٍ شرعي داخل النظام يستدعيهما
--   بوصفه SECURITY DEFINER آخر (has_capability وrequire_capability
--   وmy_capabilities وpermission_administrators_remaining) — فتُنفَّذ باسم
--   مالك الدالّة (postgres) لا الطالب الأصلي، فتبقى تعمل رغم سحب المنحة من
--   authenticated (Postgres لا يعيد فحص EXECUTE لاستدعاء داخلي كهذا).
--   المستدعي الخارجي الوحيد الآخر هو supabase/functions/odoo-lookup الذي
--   يستدعي effective_permission بمفتاح service_role (يحمل صلاحياته الكاملة
--   بمعزل عن منح authenticated) وبـp_user_id مشتقّ من التوكن المُتحقَّق
--   خادمياً لا من مُدخل عميل — فهو لا يمرّر أبداً هوية غير هوية الطالب
--   نفسه. لا مستدعٍ شرعي واحد يحتاج المرور بهما مباشرة من العميل بهوية
--   غيره. فالمنحة الحالية لـauthenticated تسمح اليوم لأي مستخدم (حتى viewer)
--   بالاستعلام مباشرة عبر PostgREST RPC عن قدرات أي مستخدم آخر بالاسم
--   (effective_permission)، أو — الأخطر — عن كامل تفصيل صلاحياته
--   (explain_permission: القالب، الموروث، المنح والمنع الصريحين بأسبابهما
--   وتواريخ انتهائهما) — تسريب بيانات داخلية حسّاسة لا تخدمه أي واجهة عميل
--   قط (بحثٌ في src/** لم يُظهر استدعاءً واحداً لأيّهما). يُسحَب التفويض
--   المباشر من authenticated لكلتيهما، وتبقيان قابلتين للاستدعاء الداخلي.
--
--   protect_activation_correction() وprotect_voided_import_batch(): دالّتا
--   trigger لم تُمنَحا ولم تُسحَبا قط في تاريخ الهجرات كله — الوحيدتان من
--   بين ١٧ دالّة trigger بلا هذا السطر الصريح الذي يحمله كل نظير آخر لهما.
--   عملياً مُغلَقتان أصلاً بفعل ALTER DEFAULT PRIVILEGES (لا تحتاجان استدعاءً
--   مباشراً، فقط عبر آلية trigger بامتياز مالك الجدول)، فهذا استكمال توثيقي
--   دفاعي يطابق النمط، لا إغلاق ثغرة فعلية.
--
--   current_commission_cycle_id() (بلا فحص قدرة داخلي، ممنوحة لـauthenticated،
--   مستدعاة من src/domain/cycle.ts) رُوجعت ولم تُمَس: تعيد uuid دورة واحدة
--   فقط (لا مبلغاً ولا بيانات مستخدم)، وهي مؤشِّر تنقّل واجهة لا بيانات
--   داخلية أو مالية — منحها لـauthenticated (لا anon) مقصودة وكافية.
--
-- الفحص الآلي أدناه (permission-primitive-hardening.sql) لا يكتفي بقائمة
-- اليوم: يفحص aclexplode(coalesce(proacl, acldefault('f', proowner))) —
-- المعادلة الصحيحة لما يحدث حين لا سطر grant/revoke صريح موجود إطلاقاً —
-- عبر كل دالّة SECURITY DEFINER في public، فيرصد أي دالّة مستقبلية تُنشأ بلا
-- إغلاق صريح كما لو كانت مفحوصة يدوياً.

begin;

revoke execute on function public.effective_permission(uuid, text, text, text)
  from authenticated;
revoke execute on function public.explain_permission(uuid, text, text, text)
  from authenticated;

revoke execute on function public.protect_activation_correction()
  from public, anon, authenticated;
revoke execute on function public.protect_voided_import_batch()
  from public, anon, authenticated;

commit;
