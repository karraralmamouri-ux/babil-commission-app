-- شهرُ النتيجة صفةُ مصدرها، لا دعوى مُشغِّلها.
--
-- كان المشغّل يكتب الشهر بيده ويختار الملف بيده، فيقعان في يدَين مستقلّتين.
-- ولا شيء يمنع أن يُحسب ملفُ تموز على أنه آب: الحساب يصحّ عدداً ويكذب
-- نسبةً، ثم يُعتمَد فيُثبِّت مراحل شهرٍ على شهرٍ آخر. وذلك خطأٌ لا يظهر في
-- أيّ مجموع — كل الأرقام سليمة، والشهر وحده خاطئ.
--
-- فصار الشهر يُشتقّ من أحداث الدفعة نفسها، وتُبرهنه القاعدة عند كل كتابة:
--
--   • **الاقتران الخاطئ يُرفض.** الشهر المكتوب يجب أن يساوي الشهر المشتقّ.
--   • **المصدر المختلط يُرفض.** ملفٌ يحمل شهرَين ليس ملفَ شهر.
--   • **الشهر غير القابل للبرهان يُرفض.** حدثٌ واحدٌ بلا تاريخ يكفي: ما لا
--     تاريخ له قد يكون من شهرٍ آخر، والسكوت عنه تخمين.
--
-- والحارس زنادٌ على `installation_calculation_runs` لا فحصٌ داخل دالّة
-- واحدة: أيّ مسارٍ يكتب تشغيلةً — اليوم أو غداً — يمرّ به. الفحص داخل الدالّة
-- يحرس نداءها وحده، والزناد يحرس الجدول.
--
-- والاشتقاق بتوقيت العمل (`business_timezone`) كما تُشتقّ نوافذ الدورات
-- تماماً: حدثٌ في 2026-07-31 الساعة 23:30 ببغداد هو تمّوز، لا آب.
--
-- إضافيّ بالكامل، forward-only. لا جدولَ يُمَس، ولا صيغةَ عمولةٍ تتغيّر،
-- ولا مبلغَ مرحلةٍ يتغيّر، ولا صفَّ تاريخيّ يُعاد كتابته.

begin;

-- ---------------------------------------------------------------------------
-- ١ · وقائع شهر الدفعة — داخليّة، بلا فحص صلاحية.
--
-- يستدعيها الزناد، والزناد يعمل بحقّ الكاتب أيّاً كان. ففحص القدرة هنا
-- يمنع كاتباً مُصرَّحاً له، لا مهاجماً. القدرة تُفحص في عقد القراءة أدناه.
--
-- تُحسب على كلّ أحداث الدفعة بلا استثناء: الملغى منها والمرفوض والدَّين.
-- شهرُ الملف صفةُ الملف، لا صفةُ ما استُحقّ منه.
-- ---------------------------------------------------------------------------

create or replace function public.saas_batch_period_facts(p_batch_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_batch public.saas_import_batches%rowtype;
  v_tz text := public.business_timezone();
  v_total bigint := 0;
  v_dated bigint := 0;
  v_months text[] := array[]::text[];
begin
  select * into v_batch from public.saas_import_batches where id = p_batch_id;
  if not found then
    return jsonb_build_object('batch_id', p_batch_id, 'status', 'BATCH_NOT_FOUND',
                              'period', null, 'events', 0, 'dated', 0,
                              'months', '[]'::jsonb);
  end if;

  select count(*), count(e.event_created_at),
         coalesce(array_agg(distinct pg_catalog.to_char(
           e.event_created_at at time zone v_tz, 'YYYY-MM'))
           filter (where e.event_created_at is not null), array[]::text[])
  into v_total, v_dated, v_months
  from public.saas_activation_events e
  where e.import_batch_id = p_batch_id;

  return jsonb_build_object(
    'batch_id', p_batch_id,
    'source_kind', v_batch.source_kind,
    'source_filename', v_batch.source_filename,
    'batch_status', v_batch.status,
    'events', v_total,
    'dated', v_dated,
    'months', pg_catalog.to_jsonb(v_months),
    'period', case when pg_catalog.array_length(v_months, 1) = 1
                    and v_dated = v_total and v_total > 0
                   then v_months[1] end,
    'status', case
      when v_batch.source_kind <> 'ACTIVATION_EVENTS' then 'NOT_ACTIVATION_EVENTS'
      when v_total = 0 then 'NO_EVENTS'
      -- حدثٌ واحدٌ بلا تاريخ يُسقط البرهان كلّه: بقيّةُ الملف قد تكون تمّوز
      -- وهو من آب، ولا شيء في الملف يقول. الرفض هنا أرخص من شهرٍ خاطئ.
      when v_dated < v_total then 'PERIOD_NOT_PROVABLE'
      when pg_catalog.array_length(v_months, 1) > 1 then 'MIXED_MONTH_SOURCE'
      else 'OK' end);
end;
$fn$;

comment on function public.saas_batch_period_facts(uuid) is
  'وقائع شهر دفعة الاستيراد كما تشهد بها أحداثها. داخليّة للزناد — لا تُمنح لأحد.';

revoke execute on function public.saas_batch_period_facts(uuid) from public;
revoke execute on function public.saas_batch_period_facts(uuid) from anon;
revoke execute on function public.saas_batch_period_facts(uuid) from authenticated;

-- ---------------------------------------------------------------------------
-- ٢ · عقد القراءة: الشاشة تسأل الخادم عن الشهر ولا تشتقّه بنفسها.
--
-- الرقم الذي يقترحه المتصفّح يقترحه المتصفّح. هذا يشتقّه الخادم، وتعيده
-- الشاشة كما هو، ويُعاد برهانُه عند الكتابة. فلا يَنشأ شهرٌ في المتصفّح.
-- ---------------------------------------------------------------------------

create or replace function public.saas_batch_period(p_batch_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
begin
  perform public.require_capability('installation.view');
  return public.saas_batch_period_facts(p_batch_id);
end;
$fn$;

comment on function public.saas_batch_period(uuid) is
  'الشهر المشتقّ من أحداث دفعة الاستيراد، وحالةُ برهانه: OK · MIXED_MONTH_SOURCE · PERIOD_NOT_PROVABLE · NO_EVENTS.';

revoke execute on function public.saas_batch_period(uuid) from public;
revoke execute on function public.saas_batch_period(uuid) from anon;
grant execute on function public.saas_batch_period(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- ٣ · الحارس.
--
-- لا تُكتب تشغيلةُ شهرٍ إلا وشهرُها مُبرهَنٌ من مصدرها. يُعاد الفحص عند كل
-- كتابة لا عند الإنشاء فقط: الدفعة قد تنمو بعد أوّل حساب (رفعٌ مجزّأ
-- يُستأنف، أو ملحقٌ لاحق)، فتصير مختلطةً وقد بُنيت نتيجتها على شهرٍ واحد.
-- إعادةُ الحساب حينئذٍ تسقط، وكذلك الاعتماد — وهو المطلوب: لا يُعتمَد مالٌ
-- شهرُه غير مُبرهَن.
--
-- ويُستثنى تعديلُ تشغيلةٍ معتمَدة: حصانتُها زنادٌ آخر، وهو أولى بالكلام.
-- ---------------------------------------------------------------------------

create or replace function public.guard_calculation_run_period()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v jsonb;
  v_status text;
  v_derived text;
begin
  if tg_op = 'UPDATE' and old.status = 'APPROVED' then
    return new;
  end if;

  v := public.saas_batch_period_facts(new.source_batch_id);
  v_status := v ->> 'status';
  v_derived := v ->> 'period';

  if v_status = 'BATCH_NOT_FOUND' then
    raise exception 'Import batch % was not found', new.source_batch_id
      using errcode = 'P0002';
  elsif v_status = 'NOT_ACTIVATION_EVENTS' then
    raise exception 'Only an activation-events source can be calculated (batch % is %)',
      new.source_batch_id, v ->> 'source_kind' using errcode = '22023';
  elsif v_status = 'NO_EVENTS' then
    raise exception 'Batch % carries no activation event, so its month cannot be derived',
      new.source_batch_id using errcode = '22023';
  elsif v_status = 'PERIOD_NOT_PROVABLE' then
    raise exception
      'PERIOD_NOT_PROVABLE: % of % events in batch % carry no usable date, so the month is not provable',
      (v ->> 'events')::bigint - (v ->> 'dated')::bigint, v ->> 'events', new.source_batch_id
      using errcode = '22023';
  elsif v_status = 'MIXED_MONTH_SOURCE' then
    raise exception
      'MIXED_MONTH_SOURCE: batch % spans several months (%), so it is not a monthly source',
      new.source_batch_id,
      (select pg_catalog.string_agg(m, ', ')
       from pg_catalog.jsonb_array_elements_text(v -> 'months') as t(m))
      using errcode = '22023';
  elsif v_status <> 'OK' then
    raise exception 'Batch % has an unexpected period status %', new.source_batch_id, v_status
      using errcode = '22023';
  end if;

  if new.period is distinct from v_derived then
    raise exception
      'WRONG_MONTH_PAIRING: batch % is a % source but the result was filed under %',
      new.source_batch_id, v_derived, new.period
      using errcode = '22023';
  end if;

  return new;
end;
$fn$;

comment on function public.guard_calculation_run_period() is
  'شهرُ التشغيلة يجب أن يساويَ الشهرَ المشتقّ من أحداث مصدرها، وأن يكون مُبرهَناً.';

revoke execute on function public.guard_calculation_run_period() from public;
revoke execute on function public.guard_calculation_run_period() from anon;
revoke execute on function public.guard_calculation_run_period() from authenticated;

drop trigger if exists trg_guard_calculation_run_period
  on public.installation_calculation_runs;
create trigger trg_guard_calculation_run_period
  before insert or update on public.installation_calculation_runs
  for each row execute function public.guard_calculation_run_period();

-- ---------------------------------------------------------------------------
-- ٤ · Loan-3 وإملاءاته: خدمةُ دَينٍ لا تؤهِّل، بأيّ هجاء.
--
-- `packages.code` مطابقةٌ حرفية، و«LONA 3» ليست «Loan-3». فهجاءٌ غير مسجَّل
-- يسقط إلى `UNKNOWN_PACKAGE` — وهو مانعٌ أيضاً، فلا مال يُصرف في الحالتين.
-- لكنّ السببَ المعروض يكذب: يقول «باقة غير معروفة» وهي معروفةٌ تماماً،
-- ومعروفٌ أنها لا تؤهِّل أبداً.
--
-- فتُسجَّل الإملاءات المرصودة صراحةً بدلالتها الصحيحة. وهذا **تصنيفٌ لا
-- محرّكُ قواعدٍ ثانٍ**: لا مطابقةَ تقريبية ولا تطبيعَ حروفٍ في أيّ دالّة —
-- صفوفُ بياناتٍ يراها المدقِّق ويُعدّلها المدير من شاشة الباقات.
--
-- ولا أثرَ ماليّ لهذا: DEBT_SERVICE مانعٌ في محرّكَي العمولة والتنصيب معاً،
-- و`guard_debt_service_never_qualifies` يجعل إسنادَ سعرٍ مؤهِّلٍ لها مستحيلاً
-- بنيويّاً. الانتقال من UNKNOWN إلى DEBT_SERVICE يُشدِّد ولا يُرخي.
--
-- و`do nothing` عند التعارض: تصنيفُ مديرٍ قائمٍ لا يُداس.
-- و«Loan-3» نفسها مذكورة هنا صراحةً: هجاؤها الأصلي لم يكن حقيقةَ ترحيلٍ
-- قط، بل صفّاً تبذره دالّةُ الإعداد `seed_raw_import_reference`. فقاعدةٌ لم
-- تُشغَّل عليها تلك الدالّة كانت تقرأ «Loan-3» باقةً مجهولة. لا مالَ تحرّك
-- بذلك — المجهول مانعٌ أيضاً — لكنّ التصنيف صار الآن حقيقةَ ترحيلٍ في كل
-- بيئة، لا أثراً جانبياً لخطوةِ إعدادٍ يدوية.
-- ---------------------------------------------------------------------------

insert into public.packages (code, name, semantic_category, notes) values
  ('Loan-3', 'Loan-3', 'DEBT_SERVICE', 'debt service, never a paid activation'),
  ('LONA 3', 'LONA 3', 'DEBT_SERVICE', 'Loan-3 spelling variant observed in source files'),
  ('LONA-3', 'LONA-3', 'DEBT_SERVICE', 'Loan-3 spelling variant observed in source files'),
  ('Lona 3', 'Lona 3', 'DEBT_SERVICE', 'Loan-3 spelling variant observed in source files'),
  ('Loan 3', 'Loan 3', 'DEBT_SERVICE', 'Loan-3 spelling variant observed in source files'),
  ('LOAN-3', 'LOAN-3', 'DEBT_SERVICE', 'Loan-3 spelling variant observed in source files')
on conflict (code) do nothing;

commit;
