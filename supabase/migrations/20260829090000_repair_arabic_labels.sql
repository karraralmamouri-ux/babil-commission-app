-- إصلاح التسميات العربية التي فُقدت في طريق النشر.
--
-- العَرَض الذي بلغنا: المستخدم يرى «؟؟؟» مكان اسم الصلاحية. والسبب ليس في
-- الواجهة: البيانات نفسها فاسدة في الإنتاج. كل تسمية عربية زرعتها مهاجرةٌ
-- وصلت مستبدَلةً بعلامات استفهام.
--
-- السبب الجذري. سكربت النشر كان يبني جسم الطلب هكذا:
--     BODY=$(node -e '... JSON.stringify(readFileSync(file)) ...')
-- فيمرّ النصّ بـstdout ثم بالتقاط الصدفة، وويندوز يستبدل كل محرف غير
-- لاتيني بـ'?' في تلك الرحلة. عولج مسار النشر في مرحلة سابقة، لكن ما
-- فسد قبله بقي فاسداً في قاعدة الإنتاج.
--
-- المدى، مقيساً لا مُقدَّراً — مسحُ 264 عموداً نصّياً:
--   permission_capabilities.label_ar          44 من 44
--   installation_hold_reasons.label_ar        10 من 10
--   installation_stage_definitions.display_name_ar  5 من 5
--   role_templates.label_ar                    4 من 4
--   commission_schemes.name_ar                 1 من 1
--   installation_fee_schemes.name_ar           1 من 1
--                                       المجموع 65
--
-- والعربية التي أدخلها المستخدمون عبر التطبيق سليمة تماماً (أسماء الوكلاء
-- مثلاً)، وهذا وحده يُثبت أن الطريق هو السبب لا الترميز في القاعدة.
--
-- القيم المستعادة مأخوذة من ملفّات المهاجرة في المستودع: هي المصدر الوحيد
-- الذي كُتب صحيحاً. لا اختراع ولا ترجمة جديدة — استعادةُ ما كان.
--
-- هذه تسميات عرض فقط. لا مفتاح قدرة يتغيّر، ولا صلاحية تُمنَح أو تُنزَع،
-- ولا صفّ مالي يُمَسّ.

begin;

-- ---------------------------------------------------------------------------
-- الحارس يُضيَّق ولا يُضعَّف.
--
-- trg_protect_published_stages يمنع أي تعديل على مراحل نسخة منشورة. غرضه
-- حماية الشروط المالية: المبلغ، والمتبقّي المتوقَّع، والترتيب، والرمز،
-- والفئات المؤهِّلة، واشتراط الفاتورة، والنهائية. وهذه تبقى محميّة تماماً.
--
-- لكنه كان يمنع كذلك تصحيح اسم العرض، وهو ليس شرطاً مالياً بل تسمية. وأثر
-- ذلك أن تسميةً فاسدة تصير غير قابلة للإصلاح إلا بتعطيل الحارس — وتعطيله
-- أخطر بكثير من تضييقه.
--
-- فالتضييق هنا يحفظ المقصد كاملاً: كل عمود مالي يبقى ثابتاً في النسخة
-- المنشورة، والتسمية وحدها تُصحَّح.
-- ---------------------------------------------------------------------------

create or replace function public.protect_published_stage_definitions()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
declare v_status text;
begin
  select status into v_status from public.installation_scheme_versions
  where id = coalesce(new.scheme_version_id, old.scheme_version_id);

  if v_status is distinct from 'DRAFT' then
    -- الإدراج والحذف ممنوعان دائماً على نسخة منشورة.
    if tg_op <> 'UPDATE' then
      raise exception 'Stage definitions of a published version are immutable'
        using errcode = '42501';
    end if;
    -- وفي التعديل: كل شرط مالي يجب أن يبقى كما هو.
    if new.scheme_version_id is distinct from old.scheme_version_id
       or new.sequence is distinct from old.sequence
       or new.code is distinct from old.code
       or new.amount is distinct from old.amount
       or new.expected_remaining is distinct from old.expected_remaining
       or new.qualifying_categories is distinct from old.qualifying_categories
       or new.requires_invoice is distinct from old.requires_invoice
       or new.is_terminal is distinct from old.is_terminal then
      raise exception 'Financial terms of a published stage are immutable'
        using errcode = '42501';
    end if;
  end if;
  return coalesce(new, old);
end;
$fn$;

update public.permission_capabilities set label_ar = 'عرض المشتركين' where key = 'subscriber.view';
update public.permission_capabilities set label_ar = 'تعديل المشتركين' where key = 'subscriber.edit';
update public.permission_capabilities set label_ar = 'مطابقة الهوية' where key = 'subscriber.match';
update public.permission_capabilities set label_ar = 'تصحيح العائدية' where key = 'subscriber.correct_attribution';
update public.permission_capabilities set label_ar = 'نقل المشترك' where key = 'subscriber.transfer';
update public.permission_capabilities set label_ar = 'استيراد ملفات SaaS' where key = 'saas.import';
update public.permission_capabilities set label_ar = 'مراجعة الاستيراد' where key = 'saas.review';
update public.permission_capabilities set label_ar = 'عرض أجور التنصيب' where key = 'installation.view';
update public.permission_capabilities set label_ar = 'تسجيل تنصيب جديد' where key = 'installation.enroll';
update public.permission_capabilities set label_ar = 'وضع تعليق' where key = 'installation.hold';
update public.permission_capabilities set label_ar = 'رفع تعليق' where key = 'installation.release_hold';
update public.permission_capabilities set label_ar = 'مراجعة التنصيب' where key = 'installation.review';
update public.permission_capabilities set label_ar = 'عرض الفواتير' where key = 'invoice.view';
update public.permission_capabilities set label_ar = 'تدقيق فاتورة' where key = 'invoice.verify';
update public.permission_capabilities set label_ar = 'رفض فاتورة' where key = 'invoice.reject';
update public.permission_capabilities set label_ar = 'عرض الدفعات' where key = 'payment.view';
update public.permission_capabilities set label_ar = 'تحضير دفعة' where key = 'payment.prepare';
update public.permission_capabilities set label_ar = 'تنفيذ الدفع' where key = 'payment.execute';
update public.permission_capabilities set label_ar = 'تصحيح مالي' where key = 'payment.correct';
update public.permission_capabilities set label_ar = 'عكس حركة مالية' where key = 'payment.reverse';
update public.permission_capabilities set label_ar = 'عرض الدورات' where key = 'cycle.view';
update public.permission_capabilities set label_ar = 'إدارة الدورات' where key = 'cycle.manage';
update public.permission_capabilities set label_ar = 'إقفال دورة' where key = 'cycle.close';
update public.permission_capabilities set label_ar = 'إعادة فتح دورة' where key = 'cycle.reopen';
update public.permission_capabilities set label_ar = 'عرض الوكلاء' where key = 'agent.view';
update public.permission_capabilities set label_ar = 'إدارة الوكلاء' where key = 'agent.manage';
update public.permission_capabilities set label_ar = 'إدارة الكابينات' where key = 'fdt.manage';
update public.permission_capabilities set label_ar = 'إدارة الباقات' where key = 'package.manage';
update public.permission_capabilities set label_ar = 'إدارة مخططات الأجور' where key = 'scheme.manage';
update public.permission_capabilities set label_ar = 'عرض التقارير' where key = 'report.view';
update public.permission_capabilities set label_ar = 'تصدير التقارير' where key = 'report.export';
update public.permission_capabilities set label_ar = 'عرض سجل التدقيق' where key = 'audit.view';
update public.permission_capabilities set label_ar = 'عرض المستخدمين' where key = 'user.view';
update public.permission_capabilities set label_ar = 'إدارة المستخدمين' where key = 'user.manage';
update public.permission_capabilities set label_ar = 'إدارة الصلاحيات' where key = 'permission.manage';
update public.permission_capabilities set label_ar = 'عرض العمولات' where key = 'commission.view';
update public.permission_capabilities set label_ar = 'إدارة دورة العمولة' where key = 'commission.manage_cycle';
update public.permission_capabilities set label_ar = 'تهيئة مخطط العمولة' where key = 'commission.configure';
update public.permission_capabilities set label_ar = 'اعتماد دورة العمولة' where key = 'commission.finalize';
update public.permission_capabilities set label_ar = 'تحضير دفع العمولة' where key = 'commission.prepare_payment';
update public.permission_capabilities set label_ar = 'تنفيذ دفع العمولة' where key = 'commission.execute_payment';
update public.permission_capabilities set label_ar = 'إعادة فتح دورة' where key = 'commission.reopen';
update public.permission_capabilities set label_ar = 'مراجعة الاستثناءات' where key = 'commission.review_exception';
update public.permission_capabilities set label_ar = 'قراءة أودو' where key = 'odoo.read';
update public.installation_hold_reasons set label_ar = 'فاتورة ناقصة' where code = 'MISSING_INVOICE';
update public.installation_hold_reasons set label_ar = 'عدم تطابق مالي' where code = 'FINANCIAL_MISMATCH';
update public.installation_hold_reasons set label_ar = 'تكرار' where code = 'DUPLICATE';
update public.installation_hold_reasons set label_ar = 'مشترك غير مطابَق' where code = 'UNMATCHED_SUBSCRIBER';
update public.installation_hold_reasons set label_ar = 'تعارض هوية' where code = 'IDENTITY_CONFLICT';
update public.installation_hold_reasons set label_ar = 'أب غير معروف' where code = 'UNKNOWN_PARENT';
update public.installation_hold_reasons set label_ar = 'باقة غير معروفة' where code = 'UNKNOWN_PACKAGE';
update public.installation_hold_reasons set label_ar = 'مصدر غير مكتمل' where code = 'SOURCE_INCOMPLETE';
update public.installation_hold_reasons set label_ar = 'مدفوع سلفاً' where code = 'ALREADY_PAID';
update public.installation_hold_reasons set label_ar = 'مرحلة غير صالحة' where code = 'INVALID_STAGE';
update public.installation_stage_definitions set display_name_ar = 'القسط الأول' where code = 'P1';
update public.installation_stage_definitions set display_name_ar = 'القسط الثاني' where code = 'P2';
update public.installation_stage_definitions set display_name_ar = 'القسط الثالث' where code = 'P3';
update public.installation_stage_definitions set display_name_ar = 'القسط الرابع' where code = 'P4';
update public.installation_stage_definitions set display_name_ar = 'مكتمل' where code = 'DONE';
update public.role_templates set label_ar = 'مدير' where key = 'admin';
update public.role_templates set label_ar = 'محاسب' where key = 'accountant';
update public.role_templates set label_ar = 'مراقب' where key = 'monitor';
update public.role_templates set label_ar = 'مشاهد' where key = 'viewer';
update public.commission_schemes set name_ar = 'عمولات الوكلاء القياسية';
update public.installation_fee_schemes set name_ar = 'أجور التنصيب القياسية';
-- حارس: لا يبقى صفٌّ فاسد بعد هذه المهاجرة.
do $guard$
declare v_bad integer;
begin
  select
    (select count(*) from public.permission_capabilities where octet_length(label_ar) = length(label_ar))
  + (select count(*) from public.installation_hold_reasons where octet_length(label_ar) = length(label_ar))
  + (select count(*) from public.installation_stage_definitions where octet_length(display_name_ar) = length(display_name_ar))
  + (select count(*) from public.role_templates where octet_length(label_ar) = length(label_ar))
  into v_bad;
  if v_bad > 0 then
    raise exception '% label(s) are still not valid Arabic — the repair did not take', v_bad
      using errcode = '22000';
  end if;
end
$guard$;

commit;
