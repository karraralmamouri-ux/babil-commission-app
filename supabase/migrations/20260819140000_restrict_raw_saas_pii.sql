-- تضييق قراءة التاريخ الخام إلى الحد الذي يحتاجه العمل.
--
-- العيب. المهاجرة السابقة منحت authenticated قراءةً على الجداول العشرة كلها
-- بسياسة using (true). عشرة من أحد عشر جدولاً بيانات مرجعية لا ضرر في قراءتها،
-- لكن جدولَي التاريخ الخام يحملان phone وnational_id وcard_owner، فصار أي
-- مستخدم مسجَّل قادراً على سحبها كاملة عبر PostgREST بطلب واحد.
--
-- لم تُكشف بيانات فعلاً: الجدولان فارغان في الإنتاج (0 و0) ولم يجرِ أي استيراد
-- خام بعد. الثغرة بنيوية وتُغلق قبل أول إدخال، لا بعده.
--
-- الإصلاح. الجدولان الخامّان يصيران للمدير وحده، وتُفتح للبقية رؤيتان لا
-- تحملان حقول الهوية الحسّاسة. الرؤية تعمل بصلاحيات مالكها، فتبقى القراءة
-- التشغيلية عاملة دون منح الجدول نفسه.
--
-- forward-only. لا بيانات تتغيّر، ولا عمود يُحذف: الحقول تبقى محفوظة للمراجعة
-- المصرّح بها، وإنما لا تُقدَّم في قراءة عامة.

begin;

-- 1. التاريخ الخام: قراءة المدير فقط.
drop policy if exists saas_user_snapshots_select on public.saas_user_snapshots;
create policy saas_user_snapshots_select on public.saas_user_snapshots
  for select to authenticated
  using (public.current_app_role() = 'admin');

drop policy if exists saas_activation_events_select on public.saas_activation_events;
create policy saas_activation_events_select on public.saas_activation_events
  for select to authenticated
  using (public.current_app_role() = 'admin');

-- 2. رؤية الأحداث للعمل: كل ما يلزم التحليل، بلا حقول الهوية.
--    national_id وcard وcard_owner وcomment خارجها عمداً.
create or replace view public.saas_activation_events_safe as
select
  e.id, e.import_batch_id, e.saas_event_id, e.transaction_id,
  e.saas_user_id, e.username, e.username_key,
  e.event_created_at, e.profile_name,
  e.old_expiration, e.new_expiration, e.activations_count,
  e.raw_parent, e.canceled,
  e.price, e.user_price, e.total_price, e.tax_amount, e.tax_rate,
  e.contract_id, e.group_name,
  e.fdt_code, e.fat_code, e.port_code,
  e.source_sheet, e.created_at
from public.saas_activation_events e;

-- 3. الرؤيتان تعملان بصلاحيات المالك، فتصلان إلى الجدول رغم تضييق سياسته.
--    هذا مقصود: البوابة هي مجموعة الأعمدة المعروضة، لا الصف.
revoke all on table public.saas_activation_events_safe from authenticated, anon, public;
grant select on table public.saas_activation_events_safe to authenticated;

revoke all on table public.saas_user_current from authenticated, anon, public;
grant select on table public.saas_user_current to authenticated;

commit;
