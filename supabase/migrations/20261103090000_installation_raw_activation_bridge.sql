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
--      كودٌ لا يصله أحد. أي أنّ P1 → P2 → P3 → P4 → DONE لم يكن يحدث إطلاقاً.
--
--   3. ولا مسار من الاستيراد الخام إلى التسجيل أصلاً: enroll_new_installation
--      ليس له مستدعٍ واحد في الواجهة كلها. فالتسجيل — وهو باب الحالة الرسمية —
--      كان بلا باب.
--
-- المعالجة أصغر جسرٍ ممكن، بلا محرّك تنصيبٍ موازٍ: ثلاث نقاط اختناقٍ قائمة
-- سلفاً، ومسحٌ جماعيٌّ واحد يمرّ بالبوابة القائمة نفسها.
--
--   saas_activation_events   ← المسح الجماعي يقرأ منه المرشّحين، ويُقيّم لكلٍّ
--     منهم evaluate_enrollment_gate كما هي، ولا يُسجِّل إلا من أجازته. ومَن
--     مُنع يعود بأسبابه نصاً ليُراجَع. لا تسجيل أعمى، ولا تجاوز للبوابة.
--
--   installation_enrollments ← البوابة الوحيدة للتسجيل الجديد. فمن التسجيل
--     تُفتح الحالة الرسمية: المتبقي الافتتاحي من الإصدار المجمَّد لا من المُرسِل،
--     ومصالَحاً مع ما دُفع فعلاً قبل اليوم إن وُجد.
--
--   installation_payments    ← إدراج الدفعة هو أول كتابةٍ في مسار الصرف، قبل
--     تحويل الاستحقاق إلى «مدفوع» وقبل القيد المالي وقبل تدقيق النجاح. فحارس
--     «المرحلة تُدفع مرّة واحدة» يُعلَّق هنا قبل الإدراج: يكتب واقعة
--     installation_payment_history، ومفتاحها (مشترك، مرحلة) يرفع الاستثناء إن
--     كانت المرحلة مدفوعة سلفاً — فتسقط المعاملة كلها قبل أن يُصرف قرش.
--
--   installation_entitlements ← تحوّل الاستحقاق إلى «مدفوع» هو حدث الصرف
--     الوحيد. وعليه سلفاً guard_installation_payment قبل التحديث؛ فالتقدّم
--     يُعلَّق بعده مباشرة: المرحلة السابقة تُتحقَّق أولاً، ثم تُسجَّل نتيجتها.
--
-- ما لا يفعله هذا الملف عمداً:
--   • لا يُعدّل materialize_installation_entitlements ولا يضيف إليه حاجزاً.
--     سؤال «هل تحتاج كل مرحلةٍ حدثَ تفعيلٍ في شهرها؟» غير محسوم؛ سُجِّل في
--     docs/BUSINESS_DECISIONS_REQUIRED.md (DEC-007). إضافة الحاجز تحجب مالاً
--     عن مشتركين قائمين بناءً على قاعدةٍ غير مُثبَتة، فلم تُضَف.
--   • لا يمسّ الاستيراد التاريخي: import_installation_history باقٍ كما هو
--     للتحويل الابتدائي والإصلاح.
--   • لا ينشئ محرّك مراحل ثانياً: التقدّم يقرأ stage_amount_for_version و
--     next_stage_for_version و stage_for_remaining_in_version من إصدار
--     التسجيل المجمَّد. الدالة التاريخية installation_stage_for_remaining
--     لم تعد سلطةً، بل صارت فحص «هل يقبل التخزينُ هذا الإصدار؟» فحسب.
--
-- إضافي بالكامل، forward-only: لا حذف ولا تعديل لأي جدول أو دالة منشورة.

begin;

-- ---------------------------------------------------------------------------
-- 0. الإصدار الحاكم لمشتركٍ بعينه.
--
-- التسجيل يُجمِّد إصداره وقت التسجيل، ومالُ المشترك محسوبٌ عليه. فهو السلطة.
-- ومَن لا تسجيل له (استحقاق قديم من الاستيراد المباشر) يُقاس على الإصدار
-- المنشور الساري — وهو ما كان enroll_new_installation ليختاره له لو سُجِّل.
-- ---------------------------------------------------------------------------

create or replace function public.installation_scheme_version_for_subscriber(
  p_subscriber_id text
)
returns uuid
language sql
stable
security definer
set search_path = ''
as $fn$
  select coalesce(
    (select e.scheme_version_id from public.installation_enrollments e
     where e.subscriber_id = p_subscriber_id and e.status <> 'CANCELLED'
     order by e.enrolled_at desc limit 1),
    (select v.id
     from public.installation_scheme_versions v
     join public.installation_fee_schemes s on s.id = v.scheme_id
     where v.status = 'PUBLISHED' and s.is_active
       and (v.effective_from is null or v.effective_from <= current_date)
       and (v.effective_to is null or v.effective_to >= current_date)
     order by v.effective_from desc nulls last, v.version desc
     limit 1)
  );
$fn$;

comment on function public.installation_scheme_version_for_subscriber(text) is
  'إصدار مخطط التنصيب الحاكم لمشترك: المجمَّد في تسجيله، وإلا المنشور الساري.';

-- ---------------------------------------------------------------------------
-- 1. فتح الحالة الرسمية من التسجيل — مصالَحةً مع المال المدفوع سلفاً.
--
-- المتبقي الافتتاحي يأتي من installation_stage_definitions.expected_remaining
-- للإصدار المجمَّد في التسجيل — تهيئة، لا رقم في الكود، ولا رقم من العميل.
--
-- والأهمّ: التسجيل قد يكون أقدم من هذا الملف، وقد تكون له استحقاقات مدفوعة
-- وقيود مالية قائمة. فتحُه على المرحلة الافتتاحية عندئذٍ يعيده إلى P1 ويجعل
-- مرحلةً مدفوعةً مستحقّةً ثانيةً — أي دفعاً مزدوجاً. فالفتح هنا يقرأ الوقائع
-- المالية القائمة أولاً ويشتقّ منها الموضع:
--
--   • لا مدفوعات        → المرحلة الافتتاحية كما هي.
--   • مدفوعات متّسقة    → الموضع التالي لها، والمستلَم مجموعُها.
--   • مدفوعات متضاربة   → لا تخمين: حالة صريحة غير محسومة، بلا مرحلة ولا
--                          أهلية صرف، وسببُها مكتوب في warnings.
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
  v_open_stage text;
  v_open_remaining bigint;
  v_sub_uuid uuid;
  v_paid record;
  v_expected_prefix text[];
  v_stage text;
  v_remaining bigint;
  v_received bigint := 0;
  v_as_of date;
  v_review text;
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

  -- السلّم من الإصدار المجمَّد: أول مرحلةٍ غير منتهية هي الافتتاح، لا
  -- current_stage_code — فذاك قد يكون تقدّم أو تخلّف عن الواقع المالي.
  select d.code, d.expected_remaining into v_open_stage, v_open_remaining
  from public.installation_stage_definitions d
  where d.scheme_version_id = v_enr.scheme_version_id and not d.is_terminal
  order by d.sequence limit 1;

  if v_open_stage is null or v_open_remaining is null then
    return false;
  end if;

  insert into public.installation_subscribers (
    subscriber_id, reseller, fdt, start_date, total_amount, notes, created_by
  ) values (
    v_enr.subscriber_id, v_reseller, v_enr.fdt_code, v_enr.enrolled_at::date,
    v_open_remaining, 'raw_activation_bridge', v_actor
  )
  on conflict on constraint installation_subscribers_identity_key do nothing;

  select id into v_sub_uuid from public.installation_subscribers
  where subscriber_key = pg_catalog.lower(pg_catalog.btrim(v_enr.subscriber_id));
  if v_sub_uuid is null then
    return false;
  end if;

  -- الوقائع المالية القائمة لهذا المشترك: استحقاق مدفوعٌ له دفعة مسجّلة،
  -- وواقعة تاريخٍ سابقة. المصدران يُوحَّدان بالمرحلة، فلا تُحتسب مرّتين.
  with settled as (
    select e.stage, e.paid_amount as amount, p.payment_date
    from public.installation_entitlements e
    join public.installation_payments p on p.entitlement_id = e.id
    where e.subscriber_id = v_enr.subscriber_id
      and e.payment_status = 'paid'
      and e.stage <> 'DONE'
    union
    select h.stage, h.amount, h.payment_date
    from public.installation_payment_history h
    where h.subscriber_uuid = v_sub_uuid
  )
  select count(*)::integer as n,
         count(distinct stage)::integer as distinct_stages,
         coalesce(sum(amount), 0)::bigint as total,
         max(payment_date) as last_date,
         coalesce(array_agg(distinct stage order by stage), '{}'::text[]) as stages
  into v_paid
  from settled;

  -- السلّم المتوقَّع: بادئة متّصلة من الإصدار المجمَّد بطول ما دُفع.
  select coalesce(array_agg(d.code order by d.code), '{}'::text[])
  into v_expected_prefix
  from (
    select code from public.installation_stage_definitions
    where scheme_version_id = v_enr.scheme_version_id and not is_terminal
    order by sequence limit v_paid.distinct_stages
  ) d;

  v_review := null;

  if v_paid.n = 0 then
    v_stage := v_open_stage;
    v_remaining := v_open_remaining;
    v_received := 0;
    v_as_of := v_enr.enrolled_at::date;
  elsif v_paid.n <> v_paid.distinct_stages then
    v_review := 'DUPLICATE_STAGE_PAYMENTS';
  elsif v_paid.stages is distinct from v_expected_prefix then
    v_review := 'NON_CONTIGUOUS_PAID_STAGES';
  else
    v_received := v_paid.total;
    v_remaining := v_open_remaining - v_received;
    v_as_of := coalesce(v_paid.last_date, v_enr.enrolled_at::date);
    v_stage := public.stage_for_remaining_in_version(
      v_enr.scheme_version_id, v_remaining);

    if v_remaining < 0 then
      v_review := 'PAID_EXCEEDS_SCHEME_TOTAL';
    elsif v_stage is null then
      v_review := 'REMAINING_HAS_NO_STAGE_IN_SCHEME';
    elsif public.installation_stage_for_remaining(v_remaining) is distinct from v_stage
       or (v_stage <> 'DONE' and v_stage not in ('P1','P2','P3','P4')) then
      -- قيود التخزين تعرف سلّم V1 وحده. إصدارٌ يخالفه لا يمكن تمثيله، ولا
      -- يُخمَّن له موضع. انظر التعليق أسفل القسم 3.
      v_review := 'SCHEME_NOT_REPRESENTABLE_IN_STORAGE';
    end if;
  end if;

  if v_review is not null then
    -- حالة صريحة للمراجعة: لا مرحلة، لا متبقٍّ مخمَّن، ولا أهلية صرف.
    -- materialize_installation_entitlements يستبعدها لأن متبقّيها غير معروف.
    insert into public.installation_subscriber_state (
      subscriber_uuid, as_of_date, remaining, received_total, total_amount,
      current_stage, resolution, payment_eligible, warnings, batch_id, updated_by
    ) values (
      v_sub_uuid, coalesce(v_paid.last_date, v_enr.enrolled_at::date),
      null, null, null, null, 'unresolved', false,
      array['NEEDS_REVIEW:' || v_review], null, v_actor
    )
    on conflict (subscriber_uuid) do nothing;

    get diagnostics v_created = row_count;
    return v_created > 0;
  end if;

  insert into public.installation_subscriber_state (
    subscriber_uuid, as_of_date, remaining, received_total, total_amount,
    current_stage, resolution, payment_eligible, batch_id, updated_by
  ) values (
    v_sub_uuid, v_as_of, v_remaining, v_received, v_open_remaining,
    v_stage, 'resolved', v_stage in ('P1','P2','P3','P4'), null, v_actor
  )
  on conflict (subscriber_uuid) do nothing;

  get diagnostics v_created = row_count;
  if v_created = 0 then
    return false;
  end if;

  -- الوقائع المدفوعة قبل هذا الملف تُثبَّت في سجلّ الوقائع، وإلا بقي حارس
  -- «مرّة واحدة» جاهلاً بها فأجاز دفعها ثانية.
  insert into public.installation_payment_history (
    subscriber_uuid, stage, amount, payment_date, created_by
  )
  select distinct on (e.stage)
         v_sub_uuid, e.stage, e.paid_amount, p.payment_date, v_actor
  from public.installation_entitlements e
  join public.installation_payments p on p.entitlement_id = e.id
  where e.subscriber_id = v_enr.subscriber_id
    and e.payment_status = 'paid'
    and e.stage in ('P1','P2','P3','P4')
    and e.paid_amount > 0
  order by e.stage, p.payment_date, p.created_at
  on conflict on constraint installation_history_identity_key do nothing;

  -- ومرحلة التسجيل تتبع الحالة الرسمية، وإلا منع STAGE_OUT_OF_SEQUENCE كل
  -- دفعةٍ تالية لمشتركٍ صُولح موضعه للتوّ.
  if v_enr.current_stage_code is distinct from v_stage then
    update public.installation_enrollments
    set current_stage_code = v_stage,
        status = case when v_stage = 'DONE' then 'COMPLETED' else status end
    where id = v_enr.id;
  end if;

  return true;
end;
$fn$;

comment on function public.ensure_installation_state_for_enrollment(uuid) is
  'يفتح حالة تنصيب رسمية لتسجيلٍ جديد من الإصدار المجمَّد، مصالَحةً مع ما دُفع سلفاً. لا يمسّ حالة قائمة.';

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
-- 2. المرحلة تُدفع مرّة واحدة — عبر كل الفترات وكل المسارات.
--
-- installation_payments.unique(entitlement_id) يحمي الاستحقاق الواحد لا
-- المشترك: هوية الاستحقاق (فترة، مشترك، مرحلة)، فيمكن أن يوجد P1 لنفس
-- المشترك في تموز وفي آب، ويُدفع كلاهما. مالياً هذا صرفٌ مزدوج.
--
-- الحارس هنا يُعلَّق قبل إدراج الدفعة لأن ذلك أول كتابةٍ في
-- record_installation_payment: قبله لا شيء، وبعده مباشرةً يأتي تحويل
-- الاستحقاق إلى «مدفوع» ثم financial_ledger ثم تدقيق النجاح. فرفعُ الاستثناء
-- هنا يُسقط المعاملة كلها قبل أيٍّ منها.
--
-- والمانع هو المفتاح الفريد نفسه لا فحصٌ سابقٌ للكتابة: محاولتان متزامنتان
-- على استحقاقين مختلفين لنفس (المشترك، المرحلة) تتسلسلان على الفهرس، فتنجح
-- واحدة وترفع الأخرى unique_violation. لا سباق.
--
-- ومَن لا سجلّ مشترك له (استحقاق من الاستيراد المباشر) لا هوية له تُحمى:
-- يمرّ كما كان يمرّ قبل هذا الملف، ولا يُخترع له مشترك.
-- ---------------------------------------------------------------------------

create or replace function public.guard_installation_stage_paid_once()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_ent public.installation_entitlements%rowtype;
  v_sub_uuid uuid;
  v_actor uuid := coalesce(auth.uid(), new.created_by);
begin
  select * into v_ent from public.installation_entitlements
  where id = new.entitlement_id;
  if not found or v_ent.stage not in ('P1','P2','P3','P4') then
    return new;
  end if;

  select id into v_sub_uuid from public.installation_subscribers
  where subscriber_key = pg_catalog.lower(pg_catalog.btrim(v_ent.subscriber_id));
  if v_sub_uuid is null then
    return new;
  end if;

  begin
    insert into public.installation_payment_history (
      subscriber_uuid, stage, amount, payment_date, created_by
    ) values (
      v_sub_uuid, v_ent.stage, new.amount,
      coalesce(new.payment_date, current_date), coalesce(v_actor, new.created_by)
    );
  exception
    when unique_violation then
      raise exception
        'STAGE_ALREADY_PAID: المرحلة % مدفوعة سلفاً للمشترك % — لا تُدفع مرّتين',
        v_ent.stage, v_ent.subscriber_id
        using errcode = '23505';
  end;

  return new;
end;
$fn$;

comment on function public.guard_installation_stage_paid_once() is
  'يمنع دفع المرحلة نفسها للمشترك نفسه مرّتين عبر كل الفترات، قبل أي كتابة مالية.';

drop trigger if exists trg_installation_stage_paid_once
  on public.installation_payments;
create trigger trg_installation_stage_paid_once
  before insert on public.installation_payments
  for each row execute function public.guard_installation_stage_paid_once();

-- ---------------------------------------------------------------------------
-- 3. التقدّم بالدفع — على سلّم الإصدار المجمَّد، لا على السلّم التاريخي.
--
-- التوقيت مقصود: بعد التحديث لا قبله، وعلى installation_entitlements لا على
-- installation_payments. لأن guard_installation_payment حارسٌ قبل التحديث
-- على الجدول نفسه، ومن شروطه STAGE_OUT_OF_SEQUENCE: مرحلة الاستحقاق يجب أن
-- تُطابق مرحلة التسجيل. فلو قُدِّمت المرحلة عند إدراج الدفعة لَرفض الحارسُ
-- الدفعةَ التي قدّمتها للتوّ. الترتيب الصحيح: يتحقّق الحارس من المرحلة
-- الجارية أولاً، ثم تُسجَّل نتيجتها هنا.
--
-- والسلطة هنا هي installation_scheme_version_for_subscriber: المبلغ من
-- stage_amount_for_version، والمرحلة التالية من next_stage_for_version،
-- والموضع من stage_for_remaining_in_version. لا سلّم مكتوب في الكود.
--
-- قيدٌ يجب أن يُقال صراحةً: التخزين نفسه يعرف سلّم V1 وحده.
--   installation_state_stage_matches_remaining
--   installation_entitlements_stage_matches_remaining
--   installation_entitlements_amount_matches_stage
-- تستدعي installation_stage_for_remaining و installation_amount_for_stage
-- الثابتتين، و *_stage_check تُعدّد 'P1'..'P4','DONE' حرفياً. فإصدارٌ بسلّمٍ
-- مختلف لا يمكن تخزين حالته أصلاً. لذلك لا يُدّعى هنا دعمٌ كامل للإصدارات:
-- يُقرأ الإصدار المجمَّد، ويُرفَض صراحةً وذرّياً ما لا يقبله التخزين
-- (SCHEME_NOT_REPRESENTABLE_IN_STORAGE)، ولا يُسكت عنه ولا يُستبدل بالسلّم
-- التاريخي بصمت. تحرير القيود إلى سلّمٍ معلَّم بالإصدار عملٌ مستقلّ.
--
-- وكل مخالفةٍ هنا ترفع استثناءً فتُسقط المعاملة. لا واقعةٌ تُسجَّل ثم يُصمت
-- عن عدم التقدّم: الواقعة كُتبت في القسم 2 قبل الدفعة، فإسقاط المعاملة
-- يمحوها معها.
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
  v_version uuid;
  v_paid_on date;
  v_expected_amount bigint;
  v_new_remaining bigint;
  v_new_stage text;
  v_next_stage text;
begin
  if new.stage not in ('P1','P2','P3','P4') or coalesce(new.paid_amount, 0) <= 0
     or v_actor is null then
    return null;
  end if;

  select id into v_sub_uuid from public.installation_subscribers
  where subscriber_key = pg_catalog.lower(pg_catalog.btrim(new.subscriber_id));
  if v_sub_uuid is null then
    -- استحقاق من الاستيراد المباشر بلا سجل مشترك: لا هوية ولا حالة تتقدّم.
    -- المسار القديم كما كان، وحارس القسم 2 تركه يمرّ للسبب نفسه.
    return null;
  end if;

  select * into v_state from public.installation_subscriber_state
  where subscriber_uuid = v_sub_uuid
  for update;

  if v_state.subscriber_uuid is null then
    -- مشتركٌ بلا حالة رسمية: لا موضع ليتقدّم. صرفٌ على المسار القديم.
    return null;
  end if;

  v_version := public.installation_scheme_version_for_subscriber(new.subscriber_id);
  if v_version is null then
    raise exception
      'INSTALLATION_SCHEME_UNRESOLVED: لا إصدار مخطط حاكم للمشترك %',
      new.subscriber_id using errcode = 'P0002';
  end if;

  select p.payment_date into v_paid_on from public.installation_payments p
  where p.entitlement_id = new.id;
  v_paid_on := coalesce(v_paid_on, new.paid_at::date, current_date);

  if v_state.remaining is null or v_state.current_stage is distinct from new.stage then
    raise exception
      'INSTALLATION_STATE_OUT_OF_SYNC: الحالة عند % والاستحقاق عند % للمشترك %',
      coalesce(v_state.current_stage, '—'), new.stage, new.subscriber_id
      using errcode = '23514';
  end if;

  v_expected_amount := public.stage_amount_for_version(v_version, new.stage);
  if v_expected_amount is null or v_expected_amount <> new.paid_amount then
    raise exception
      'INSTALLATION_AMOUNT_NOT_IN_SCHEME: المرحلة % بمبلغ % والإصدار يقول %',
      new.stage, new.paid_amount, coalesce(v_expected_amount, -1)
      using errcode = '23514';
  end if;

  v_new_remaining := v_state.remaining - new.paid_amount;
  if v_new_remaining < 0 then
    raise exception
      'INSTALLATION_REMAINING_UNDERFLOW: المتبقي % لا يحتمل %',
      v_state.remaining, new.paid_amount using errcode = '23514';
  end if;

  v_new_stage := public.stage_for_remaining_in_version(v_version, v_new_remaining);
  v_next_stage := public.next_stage_for_version(v_version, new.stage);
  if v_new_stage is null or v_new_stage is distinct from v_next_stage then
    raise exception
      'INSTALLATION_SCHEME_LADDER_MISMATCH: متبقٍّ % يقابل % والتالي بعد % هو %',
      v_new_remaining, coalesce(v_new_stage, '—'), new.stage, coalesce(v_next_stage, '—')
      using errcode = '23514';
  end if;

  -- ما لا يقبله التخزين لا يُخزَّن بسلّمٍ آخر بصمت.
  if public.installation_stage_for_remaining(v_new_remaining) is distinct from v_new_stage then
    raise exception
      'SCHEME_NOT_REPRESENTABLE_IN_STORAGE: الإصدار % يضع % عند متبقٍّ % وقيود التخزين تخالفه',
      v_version, v_new_stage, v_new_remaining using errcode = '23514';
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
-- 4. الجسر الجماعي: من ملف التفعيل الخام إلى التسجيل، بالبوابة نفسها.
--
-- المشغّل يرفع ملف التفعيل، ثم يُشغّل هذا المسح. لا عمود Remaining، ولا
-- استدعاء تسجيلٍ فرديّ بيده.
--
-- ولا تسجيل أعمى: لكل مرشّح تُقيَّم evaluate_enrollment_gate كما هي — بكل
-- شروطها: باقة مؤهِّلة، مصدرٌ معلَن الاكتمال، هوية محسومة، أبٌ مُحَلّ، تصنيف
-- «جديد». مَن أجازته البوابة يُسجَّل، ومَن مُنع يعود باسمه وأسبابه نصاً.
--
-- والمسح قابل لإعادة التشغيل بطبيعته: الهوية والتصنيف واكتمال المصدر تُحسَم
-- عادةً بعد الرفع لا معه، فأكثر الصفوف تُمنع في التشغيلة الأولى بحق، ثم
-- تُسجَّل في تشغيلةٍ لاحقة. ALREADY_ENROLLED يمنع الازدواج.
-- ---------------------------------------------------------------------------

create or replace function public.bridge_saas_activations_to_enrollments(
  p_batch_id uuid default null,
  p_limit integer default 500,
  p_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_existing public.audit_logs%rowtype;
  v_cand record;
  v_gate jsonb;
  v_considered integer := 0;
  v_enrolled integer := 0;
  v_blocked jsonb := '[]'::jsonb;
  v_reasons jsonb := '{}'::jsonb;
  v_key text;
  v_result jsonb;
begin
  perform public.require_capability('installation.enroll');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 5000 then
    raise exception 'limit must be between 1 and 5000' using errcode = '22023';
  end if;

  select * into v_existing from public.audit_logs
  where actor_id = v_actor and request_id = p_request_id;
  if found then
    if v_existing.action <> 'installation.enrollment.bulk_bridged' then
      raise exception 'request_id was already used for another operation'
        using errcode = '23505';
    end if;
    return jsonb_build_object('result', v_existing.after_data, 'replayed', true);
  end if;

  for v_cand in
    select distinct on (e.username_key)
           e.username_key, e.saas_event_id
    from public.saas_activation_events e
    where (p_batch_id is null or e.import_batch_id = p_batch_id)
      and coalesce(e.canceled, false) = false
      and not exists (
        select 1 from public.installation_enrollments en
        where en.subscriber_id = e.username_key)
    order by e.username_key, e.event_created_at, e.saas_event_id
    limit p_limit
  loop
    v_considered := v_considered + 1;
    v_gate := public.evaluate_enrollment_gate(v_cand.username_key, v_cand.saas_event_id);

    if (v_gate ->> 'allowed')::boolean then
      begin
        perform public.enroll_new_installation(
          v_cand.username_key, v_cand.saas_event_id, null,
          public.uuid_from_parts(p_request_id, pg_catalog.md5(v_cand.username_key)::uuid));
        v_enrolled := v_enrolled + 1;
      exception
        when others then
          v_blocked := v_blocked || jsonb_build_object(
            'username_key', v_cand.username_key,
            'event_id', v_cand.saas_event_id,
            'blockers', jsonb_build_array('ENROLL_FAILED'),
            'detail', sqlerrm);
      end;
    else
      v_blocked := v_blocked || jsonb_build_object(
        'username_key', v_cand.username_key,
        'event_id', v_cand.saas_event_id,
        'blockers', v_gate -> 'blockers');
    end if;
  end loop;

  -- تجميع الأسباب: المشغّل يحتاج «١٤٠ بلا تصنيف» لا مئةَ سطرٍ متطابق.
  for v_key in
    select jsonb_array_elements_text(b -> 'blockers')
    from jsonb_array_elements(v_blocked) as t(b)
  loop
    v_reasons := jsonb_set(v_reasons, array[v_key],
      to_jsonb(coalesce((v_reasons ->> v_key)::integer, 0) + 1));
  end loop;

  v_result := jsonb_build_object(
    'batch_id', p_batch_id,
    'considered', v_considered,
    'enrolled', v_enrolled,
    'blocked', jsonb_array_length(v_blocked),
    'reasons', v_reasons,
    'blocked_rows', v_blocked
  );

  insert into public.audit_logs (
    actor_id, action, entity_type, entity_id, after_data, request_id, extra
  ) values (
    v_actor, 'installation.enrollment.bulk_bridged', 'saas_import_batch', p_batch_id,
    v_result, p_request_id,
    'enrolled=' || v_enrolled::text || ' blocked=' || jsonb_array_length(v_blocked)::text
  );

  return jsonb_build_object('result', v_result, 'replayed', false);
end;
$fn$;

comment on function public.bridge_saas_activations_to_enrollments(uuid, integer, uuid) is
  'مسح جماعي: يُسجّل من ملف التفعيل الخام كل مَن أجازته بوابة التسجيل، ويُعيد الممنوعين بأسبابهم. قابل لإعادة التشغيل.';

-- ---------------------------------------------------------------------------
-- 5. التسجيلات الجديدة القائمة قبل هذا الملف.
--
-- مَن سُجِّل بتفعيلٍ مؤهِّل ولم تُفتح له حالة كان سيبقى محروماً إلى الأبد،
-- لأن الجسر لم يكن موجوداً يوم تسجيله. الفتح هنا هو الفتح نفسه الذي كان
-- سيحدث لحظتها، بنفس الدالة الواحدة — وهي التي تُصالح المدفوع سلفاً، فلا
-- يُعاد أحدٌ إلى P1 ولا يُمسّ أي مبلغ تاريخي.
-- ---------------------------------------------------------------------------

-- أولاً: كل مرحلةٍ دُفعت فعلاً قبل اليوم تُثبَّت في سجلّ الوقائع. الصرف عبر
-- record_installation_payment لم يكن يكتب فيه إطلاقاً، فحارس «مرّة واحدة»
-- كان سيجهل كل ما دُفع قبل هذا الملف ويُجيز دفعه ثانية في فترةٍ أخرى.
-- on conflict do nothing: واقعة الاستيراد التاريخي أسبق ولا تُستبدل.

do $$
begin
  insert into public.installation_payment_history (
    subscriber_uuid, stage, amount, payment_date, batch_id, created_by
  )
  select distinct on (s.id, e.stage)
         s.id, e.stage, e.paid_amount, p.payment_date, e.batch_id, p.created_by
  from public.installation_entitlements e
  join public.installation_payments p on p.entitlement_id = e.id
  join public.installation_subscribers s
    on s.subscriber_key = pg_catalog.lower(pg_catalog.btrim(e.subscriber_id))
  where e.payment_status = 'paid'
    and e.stage in ('P1','P2','P3','P4')
    and e.paid_amount > 0
  order by s.id, e.stage, p.payment_date, p.created_at
  on conflict on constraint installation_history_identity_key do nothing;
end;
$$;

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
-- 6. الصلاحيات. دوال التشغيل لا تُستدعى من الواجهة؛ والمسح الجماعي يُستدعى
--    منها لكنه يفحص القدرة بنفسه أولاً.
-- ---------------------------------------------------------------------------

revoke execute on function public.ensure_installation_state_for_enrollment(uuid)
  from public, anon, authenticated;
revoke execute on function public.trg_enrollment_opens_installation_state()
  from public, anon, authenticated;
revoke execute on function public.trg_payment_advances_installation_state()
  from public, anon, authenticated;
revoke execute on function public.guard_installation_stage_paid_once()
  from public, anon, authenticated;
revoke execute on function public.installation_scheme_version_for_subscriber(text)
  from public, anon;

revoke execute on function public.bridge_saas_activations_to_enrollments(uuid, integer, uuid)
  from public, anon;
grant execute on function public.bridge_saas_activations_to_enrollments(uuid, integer, uuid)
  to authenticated;

commit;
