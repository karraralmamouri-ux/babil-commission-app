-- جسر التفعيل الخام إلى الحالة الرسمية، وتقدّم المراحل بالدفع.
--
-- الفجوة التي يسدّها هذا الملف (INS-013 · INS-014 · INS-015):
--
--   1. المشترك المعروف من ملف التفعيل الخام وحده لم يكن يصل أبداً إلى
--      installation_subscriber_state. و materialize_installation_entitlements
--      يقرأ من installation_subscribers + installation_subscriber_state
--      حصراً، فلا استحقاق له مهما تكرّر تفعيله. المنتج الوحيد للحالة كان
--      الاستيراد التاريخي بعمود Remaining — فصار على المشغّل أن يصنع عموداً
--      شهرياً بيده. هذا هو سبب المطلب: لا عمود Remaining شهرياً.
--
--   2. لم يكن ثمّة مسار واحد يُقدّم المرحلة. installation_subscriber_state و
--      installation_payment_history لهما كاتب واحد فقط هو الاستيراد التاريخي،
--      و record_installation_payment لا يمسّ أياً منهما، و next_stage_for_version
--      كودٌ لا يصله أحد. أي أنّ P1 → P2 → P3 → P4 → DONE لم يكن يحدث إطلاقاً،
--      وكان المشترك يبقى عند مرحلته إلى الأبد، لا يحميه من إعادة الصرف إلا
--      ضوابط الفواتير.
--
-- المعالجة أصغر جسرٍ ممكن، بلا محرّك تنصيبٍ موازٍ: نقطتا اختناقٍ قائمتان
-- سلفاً، تُعلَّق على كلٍّ منهما دالةُ تشغيلٍ واحدة.
--
--   installation_enrollments  ← البوابة الوحيدة للتسجيل الجديد. كل مسارٍ
--     يُنشئ تسجيلاً (فردياً أو جماعياً) يمرّ بها، و enroll_new_installation
--     يكون قد استوفى evaluate_enrollment_gate قبلها. فمن التسجيل تُفتح
--     الحالة الرسمية: المتبقي الافتتاحي من الإصدار المنشور لا من المُرسِل.
--
--   installation_entitlements ← تحوّل الاستحقاق إلى «مدفوع» هو حدث الصرف
--     الوحيد، يمرّ به الصرف الفردي والدفعة معاً. وعليه سلفاً حارس
--     guard_installation_payment قبل التحديث؛ فالتقدّم يُعلَّق بعده مباشرة:
--     المرحلة السابقة تُتحقَّق أولاً، ثم تُسجَّل نتيجتها. مرّةً واحدة، لأن
--     installation_payment_history مفتاحها (مشترك، مرحلة).
--
-- ما لا يفعله هذا الملف عمداً:
--   • لا يُعدّل materialize_installation_entitlements ولا يضيف إليه حاجزاً.
--     سؤال «هل تحتاج كل مرحلةٍ حدثَ تفعيلٍ في شهرها؟» غير محسوم؛ سُجِّل في
--     docs/BUSINESS_DECISIONS_REQUIRED.md (DEC-007). إضافة الحاجز تحجب مالاً
--     عن مشتركين قائمين بناءً على قاعدةٍ غير مُثبَتة، فلم تُضَف.
--   • لا يمسّ الاستيراد التاريخي: import_installation_history باقٍ كما هو
--     للتحويل الابتدائي والإصلاح.
--   • لا يكتب في installation_entitlements ولا financial_ledger ولا أي جدول
--     عمولات. الصرف يبقى محكوماً بضوابطه: فاتورة مُتحقَّقة، وتعليق، وهوية،
--     وعائدية. اشتقاق الاستحقاق لا يمنح سلطةَ دفع (INS-016).
--
-- إضافي بالكامل، forward-only: لا حذف ولا تعديل لأي جدول أو دالة منشورة.

begin;

-- ---------------------------------------------------------------------------
-- 1. فتح الحالة الرسمية من التسجيل.
--
-- المتبقي الافتتاحي يأتي من installation_stage_definitions.expected_remaining
-- للإصدار المنشور المرتبط بالتسجيل — تهيئة، لا رقم في الكود، ولا رقم من
-- العميل. وإن لم يطابق المخطَّطُ سلّمَ المتبقي المنشور فلا تُخمَّن حالة مالية:
-- يُترك المشترك بلا حالة ويظهر أنه بلا استحقاق، وهو الفشل الآمن.
--
-- ولا تُلمَس حالةٌ قائمة أبداً: المشترك التاريخي يستأنف من مرحلته هو، ولا
-- يُعاد أحدٌ إلى P1 (INS-012).
-- ---------------------------------------------------------------------------

create or replace function public.ensure_installation_state_for_enrollment(
  p_enrollment_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_enr public.installation_enrollments%rowtype;
  v_actor uuid;
  v_reseller text;
  v_remaining bigint;
  v_stage text;
  v_sub_uuid uuid;
  v_created integer := 0;
begin
  select * into v_enr from public.installation_enrollments where id = p_enrollment_id;
  if not found then
    return false;
  end if;

  -- التاريخي يُبنى من الحالة لا العكس؛ اشتقاق حالةٍ منه دوران.
  if v_enr.origin <> 'NEW_INSTALLATION' then
    return false;
  end if;

  v_actor := coalesce(auth.uid(), v_enr.enrolled_by);
  if v_actor is null then
    return false;
  end if;

  -- الوكيل من سجل الوكلاء، وإلا الاسم المحفوظ وقت التسجيل. لا فراغ:
  -- installation_subscribers.reseller not null، ولا يُخمَّن وكيل.
  select a.official_name into v_reseller
  from public.agents a where a.id = v_enr.effective_agent_id;
  v_reseller := nullif(pg_catalog.btrim(
    coalesce(v_reseller, v_enr.agent_name_at_enrollment, '')), '');
  if v_reseller is null then
    return false;
  end if;

  select d.expected_remaining into v_remaining
  from public.installation_stage_definitions d
  where d.scheme_version_id = v_enr.scheme_version_id
    and d.code = v_enr.current_stage_code;

  if v_remaining is null then
    return false;
  end if;

  v_stage := public.installation_stage_for_remaining(v_remaining);
  if v_stage is null or v_stage is distinct from v_enr.current_stage_code then
    return false;
  end if;

  insert into public.installation_subscribers (
    subscriber_id, reseller, fdt, start_date, total_amount, notes, created_by
  ) values (
    v_enr.subscriber_id, v_reseller, v_enr.fdt_code, v_enr.enrolled_at::date,
    v_remaining, 'raw_activation_bridge', v_actor
  )
  on conflict on constraint installation_subscribers_identity_key do nothing;

  select id into v_sub_uuid from public.installation_subscribers
  where subscriber_key = pg_catalog.lower(pg_catalog.btrim(v_enr.subscriber_id));
  if v_sub_uuid is null then
    return false;
  end if;

  -- الافتتاح: لم يُستلم شيء بعد، فالمجموع هو المتبقي والهوية المحاسبية قائمة.
  insert into public.installation_subscriber_state (
    subscriber_uuid, as_of_date, remaining, received_total, total_amount,
    current_stage, resolution, payment_eligible, batch_id, updated_by
  ) values (
    v_sub_uuid, v_enr.enrolled_at::date, v_remaining, 0, v_remaining,
    v_stage, 'resolved', v_stage in ('P1','P2','P3','P4'), null, v_actor
  )
  on conflict (subscriber_uuid) do nothing;

  get diagnostics v_created = row_count;
  return v_created > 0;
end;
$fn$;

comment on function public.ensure_installation_state_for_enrollment(uuid) is
  'يفتح حالة تنصيب رسمية لتسجيلٍ جديد من الإصدار المنشور. لا يمسّ حالة قائمة.';

create or replace function public.trg_enrollment_opens_installation_state()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  perform public.ensure_installation_state_for_enrollment(new.id);
  return null;
end;
$fn$;

drop trigger if exists trg_installation_enrollment_opens_state
  on public.installation_enrollments;
create trigger trg_installation_enrollment_opens_state
  after insert on public.installation_enrollments
  for each row execute function public.trg_enrollment_opens_installation_state();

-- ---------------------------------------------------------------------------
-- 2. التقدّم بالدفع — مرّة واحدة، مهما تكرّر الطلب أو الملف أو المتصفّح.
--
-- التوقيت مقصود: بعد التحديث لا قبله، وعلى installation_entitlements لا على
-- installation_payments. لأن guard_installation_payment حارسٌ قبل التحديث
-- على الجدول نفسه، ومن شروطه STAGE_OUT_OF_SEQUENCE: مرحلة الاستحقاق يجب أن
-- تُطابق مرحلة التسجيل. فلو قُدِّمت المرحلة عند إدراج الدفعة لَرفض الحارسُ
-- الدفعةَ التي قدّمتها للتوّ. الترتيب الصحيح: يتحقّق الحارس من المرحلة
-- الجارية أولاً، ثم تُسجَّل نتيجتها هنا.
--
-- والشرط أدناه توأمُ شرط الحارس حرفياً، فلا يتقدّم أحدٌ إلا بصرفٍ أُجيز.
--
-- الواقعة تُسجَّل أولاً في installation_payment_history، ومفتاحها الفريد
-- (مشترك، مرحلة) هو المانع نفسه: إن لم يُدرَج صف فالمرحلة مسجَّلة سلفاً ولا
-- تقدّم ثانٍ. وهذا يغطّي ما لا يغطّيه مفتاح installation_payments الفريد
-- (استحقاق واحد لكل دفعة): استحقاقان لنفس (المشترك، المرحلة) في شهرين.
--
-- والحالة تُقفَل قبل التسجيل، فمحاولتان متزامنتان تتسلسلان ولا تُنتجان
-- تقدّمين.
-- ---------------------------------------------------------------------------

create or replace function public.trg_payment_advances_installation_state()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := coalesce(new.paid_by, auth.uid());
  v_state public.installation_subscriber_state%rowtype;
  v_sub_uuid uuid;
  v_paid_on date;
  v_recorded integer := 0;
  v_new_remaining bigint;
  v_new_stage text;
begin
  if new.stage not in ('P1','P2','P3','P4') or coalesce(new.paid_amount, 0) <= 0
     or v_actor is null then
    return null;
  end if;

  select id into v_sub_uuid from public.installation_subscribers
  where subscriber_key = pg_catalog.lower(pg_catalog.btrim(new.subscriber_id));
  if v_sub_uuid is null then
    -- استحقاق من الاستيراد المباشر بلا سجل مشترك: لا حالة لتتقدّم.
    return null;
  end if;

  select p.payment_date into v_paid_on from public.installation_payments p
  where p.entitlement_id = new.id;
  v_paid_on := coalesce(v_paid_on, new.paid_at::date, current_date);

  select * into v_state from public.installation_subscriber_state
  where subscriber_uuid = v_sub_uuid
  for update;

  insert into public.installation_payment_history (
    subscriber_uuid, stage, amount, payment_date, created_by
  ) values (
    v_sub_uuid, new.stage, new.paid_amount, v_paid_on, v_actor
  )
  on conflict on constraint installation_history_identity_key do nothing;
  get diagnostics v_recorded = row_count;

  if v_recorded = 0 then
    return null;
  end if;

  -- الحالة إمّا غائبة، أو تجاوزت هذه المرحلة سلفاً، أو متبقّيها غير معروف.
  -- في الثلاث لا يُخمَّن تقدّم: الواقعة سُجّلت، والحالة تُترك كما هي.
  if v_state.subscriber_uuid is null
     or v_state.remaining is null
     or v_state.current_stage is distinct from new.stage then
    return null;
  end if;

  v_new_remaining := v_state.remaining - new.paid_amount;
  if v_new_remaining < 0 then
    return null;
  end if;
  v_new_stage := public.installation_stage_for_remaining(v_new_remaining);
  if v_new_stage is null then
    return null;
  end if;

  -- received_total الفارغ يبقى فارغاً: ملؤه هنا يكسر هوية
  -- (المجموع − المستلَم = المتبقي) على صفٍّ ناقصٍ من الملف التاريخي.
  update public.installation_subscriber_state
  set remaining = v_new_remaining,
      received_total = case when received_total is null
                            then null else received_total + new.paid_amount end,
      current_stage = v_new_stage,
      payment_eligible = (resolution = 'resolved'
                          and v_new_stage in ('P1','P2','P3','P4')),
      as_of_date = greatest(as_of_date, v_paid_on),
      updated_by = v_actor,
      updated_at = now()
  where subscriber_uuid = v_sub_uuid;

  -- التسجيل ليس محرّكاً موازياً: مرحلته تتبع الحالة الرسمية، لا تنافسها.
  -- وهذا هو ما كان مفقوداً: بلا تقديمها يبقى STAGE_OUT_OF_SEQUENCE مانعاً
  -- كلَّ دفعةٍ تالية إلى الأبد.
  update public.installation_enrollments
  set current_stage_code = v_new_stage,
      status = case when v_new_stage = 'DONE' then 'COMPLETED' else status end
  where subscriber_id = new.subscriber_id
    and status <> 'CANCELLED';

  -- request_id يُترك فارغاً عمداً: حرّاس الإعادة في الدوال المالية تقرأ
  -- (actor_id, request_id) بصفٍّ واحد، وصفٌّ ثانٍ بنفس المعرّف يُفشلها.
  insert into public.audit_logs (
    actor_id, action, entity_type, entity_id, field, old_value, new_value, extra
  ) values (
    v_actor, 'installation.stage.advanced', 'installation_subscriber', v_sub_uuid,
    'current_stage', new.stage, v_new_stage,
    'period=' || new.period || ' remaining=' || v_new_remaining::text
  );

  return null;
end;
$fn$;

drop trigger if exists trg_installation_payment_advances_state
  on public.installation_entitlements;
create trigger trg_installation_payment_advances_state
  after update on public.installation_entitlements
  for each row
  when (new.payment_status = 'paid' and old.payment_status is distinct from 'paid')
  execute function public.trg_payment_advances_installation_state();

-- ---------------------------------------------------------------------------
-- 3. التسجيلات الجديدة القائمة قبل هذا الملف.
--
-- مَن سُجِّل بتفعيلٍ مؤهِّل ولم تُفتح له حالة كان سيبقى محروماً إلى الأبد،
-- لأن الجسر لم يكن موجوداً يوم تسجيله. الفتح هنا هو الفتح نفسه الذي كان
-- سيحدث لحظتها، بنفس الدالة الواحدة — لا مسّ لأي حالة قائمة ولا لأي مبلغ
-- تاريخي.
-- ---------------------------------------------------------------------------

do $$
declare
  v_id uuid;
begin
  for v_id in
    select e.id
    from public.installation_enrollments e
    left join public.installation_subscribers s
      on s.subscriber_key = pg_catalog.lower(pg_catalog.btrim(e.subscriber_id))
    left join public.installation_subscriber_state st
      on st.subscriber_uuid = s.id
    where e.origin = 'NEW_INSTALLATION'
      and st.subscriber_uuid is null
    order by e.enrolled_at
  loop
    perform public.ensure_installation_state_for_enrollment(v_id);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. الصلاحيات. دوال التشغيل لا تُستدعى من الواجهة.
-- ---------------------------------------------------------------------------

revoke execute on function public.ensure_installation_state_for_enrollment(uuid)
  from public, anon, authenticated;
revoke execute on function public.trg_enrollment_opens_installation_state()
  from public, anon, authenticated;
revoke execute on function public.trg_payment_advances_installation_state()
  from public, anon, authenticated;

commit;
