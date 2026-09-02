-- استيراد أحداث التفعيل المُجزَّأ (20261104090000).
--
-- الملف الحقيقي Activations Report_Aug-2026.xlsx فيه 29,427 حدثاً، وكان
-- «اعتمد الاستيراد» يعود بـ statement timeout ولا يترك دفعةً يُستأنف منها.
-- زمن الاستيراد نفسه تحت مهلة الثماني ثوانٍ يُقاس في
-- tests/sql/saas-activation-large-import.sh — بالدور المُصادَق عليه لا
-- بـpostgres. هذا الملف يُثبت أن الدلالات لم تتغيّر بتغيّر الطريق:
--
--   · العدّ: مقبول ومكرّر ومرفوض وسببه، بنفس أولوية الحلقة القديمة.
--   · إزالة التكرار بمعرّف الحدث وحده — لا بالمشترك أبداً (D-02).
--   · ملفٌّ واحد = دفعةٌ منطقيةٌ واحدة مهما بلغ عدد أجزائه.
--   · إعادة التشغيل: نفس الجزء يُعاد فلا يُعدّ مرّتين ولا يُقرأ محتواه ثانيةً.
--   · لا إنهاءَ لدفعةٍ منقوصة، ولا صفَّ تدقيقٍ نهائيٍّ لها.
--   · الجسر يتقدّم فعلاً على مرشّحين أكثر من نافذته الواحدة.
--
-- كل شيء داخل معاملةٍ تُلغى. معزول بنطاق تسمية sc-.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '   ok ' || p_label else 'FAILED: ' || p_label end;
$$;

create or replace function pg_temp.must_fail_with(
  p_sql text, p_label text, p_needle text)
returns text language plpgsql as $$
begin
  execute p_sql;
  return 'FAILED: ' || p_label || ' — مرّ وكان يجب أن يُرفض';
exception when others then
  if pg_catalog.strpos(sqlerrm, p_needle) > 0 then
    return '   ok ' || p_label;
  end if;
  return 'FAILED: ' || p_label || ' — رُفض بسبب آخر: ' || sqlerrm;
end;
$$;

begin;

insert into auth.users (id, email) values
  ('5c000000-0000-0000-0000-0000000000a1', 'sc-admin@fixture.invalid')
on conflict (id) do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('5c000000-0000-0000-0000-0000000000a1', 'SC Admin', 'sc-admin@fixture.invalid', 'admin', true)
on conflict (id) do update set role = 'admin', is_active = true;

select set_config('request.jwt.claim.sub', '5c000000-0000-0000-0000-0000000000a1', true);

create temporary table sc_before on commit drop as
select
  (select count(*) from public.installation_entitlements) as entitlements,
  (select count(*) from public.installation_payments) as payments,
  (select coalesce(sum(amount), 0) from public.financial_ledger) as ledger_total;

select '   == saas activation chunked intake ==';

-- ===========================================================================
-- ١. العدّ: نفس التصنيفات ونفس أولويّتها بعد أن صار الاستيعاب مجموعياً.
--
-- الحلقة القديمة كانت تقيّم قيم INSERT قبل أن يصل الصفّ إلى الفهرس الفريد،
-- فصفٌّ مشوّهٌ ومكرّرٌ معاً كان MALFORMED_ROW لا مكرّراً. الفحص المسبق يحفظ
-- هذا الترتيب حرفياً، والصفّ العاشر أدناه هو ما يُثبته.
-- ===========================================================================

select public.import_saas_activation_events(
  'mix.xlsx', 'sc-mix-1', 'saas-import.js',
  jsonb_build_array(
    jsonb_build_object('saas_event_id', 'SC-EV-1', 'username', 'sc-user-1'),
    jsonb_build_object('saas_event_id', 'SC-EV-2', 'username', 'sc-user-2'),
    -- نفس المشترك بحدثٍ آخر: صالحٌ ومقصود، لا تكرار.
    jsonb_build_object('saas_event_id', 'SC-EV-3', 'username', 'sc-user-2'),
    -- نفس معرّف الحدث: هذا وحده هو التكرار.
    jsonb_build_object('saas_event_id', 'SC-EV-1', 'username', 'sc-user-1'),
    jsonb_build_object('saas_event_id', '',        'username', 'sc-user-4'),
    jsonb_build_object('saas_event_id', '   ',     'username', 'sc-user-5'),
    jsonb_build_object('saas_event_id', 'SC-EV-7', 'username', ''),
    jsonb_build_object('saas_event_id', 'SC-EV-8', 'username', 'sc-user-8',
                       'event_created_at', 'not-a-date'),
    jsonb_build_object('saas_event_id', 'SC-EV-9', 'username', 'sc-user-9',
                       'activations_count', 'x'),
    -- مشوّهٌ ومكرّرٌ معاً: يبقى مشوّهاً، كما كان قبل الاستيعاب المجموعي.
    jsonb_build_object('saas_event_id', 'SC-EV-1', 'username', 'sc-user-1',
                       'price', '')
  ),
  '5c000000-0000-0000-0000-0000000000c1'::uuid
) as mix \gset

select pg_temp.ok(
  (:'mix'::jsonb -> 'batch' ->> 'source_rows')::int = 10
  and (:'mix'::jsonb -> 'batch' ->> 'accepted')::int = 3
  and (:'mix'::jsonb -> 'batch' ->> 'duplicates')::int = 1
  and (:'mix'::jsonb -> 'batch' ->> 'rejected')::int = 6,
  '١ · عشرة صفوف ⇒ مقبول 3، مكرّر 1، مرفوض 6 — لا واحد زائد ولا ناقص');

select pg_temp.ok(
  (select count(*) from jsonb_array_elements(:'mix'::jsonb -> 'batch' -> 'rejects') r
   where r ->> 'reason' = 'MISSING_EVENT_ID') = 2
  and (select count(*) from jsonb_array_elements(:'mix'::jsonb -> 'batch' -> 'rejects') r
   where r ->> 'reason' = 'MISSING_USERNAME') = 1
  and (select count(*) from jsonb_array_elements(:'mix'::jsonb -> 'batch' -> 'rejects') r
   where r ->> 'reason' = 'MALFORMED_ROW') = 3,
  '  · وكل مرفوضٍ يعود بسببه: معرّف ناقص ×2، اسم ناقص ×1، تحويل فاشل ×3');

select pg_temp.ok(
  (select count(*) from jsonb_array_elements(:'mix'::jsonb -> 'batch' -> 'rejects') r
   where (r ->> 'row')::int = 10 and r ->> 'reason' = 'MALFORMED_ROW') = 1,
  '  · والمشوّه المكرّر مشوّهٌ لا مكرّر — أولوية الحلقة القديمة محفوظة');

select pg_temp.ok(
  (select count(*) from public.saas_activation_events where saas_event_id = 'SC-EV-1') = 1
  and (select count(*) from public.saas_activation_events
       where username_key = 'sc-user-2') = 2,
  '  · التكرار بالحدث لا بالمشترك: حدثان لاسمٍ واحدٍ يُقبلان معاً (D-02)');

-- ===========================================================================
-- ٢. ملفٌّ واحد بأجزاء: دفعةٌ منطقيةٌ واحدة، وإجماليّها هو إجماليّ الملف.
-- ===========================================================================

select public.import_saas_activation_events(
  'big.xlsx', 'sc-chunk-1', 'saas-import.js',
  jsonb_build_array(
    jsonb_build_object('saas_event_id', 'SC-CH-1', 'username', 'sc-ch-1'),
    jsonb_build_object('saas_event_id', 'SC-CH-2', 'username', 'sc-ch-2'),
    jsonb_build_object('saas_event_id', 'SC-CH-3', 'username', 'sc-ch-3')
  ),
  '5c000000-0000-0000-0000-0000000000c2'::uuid,
  null, null, null, 6, false, 0
) as part1 \gset

select (:'part1'::jsonb -> 'batch' ->> 'batch_id') as sc_batch \gset

select pg_temp.ok(
  (:'part1'::jsonb -> 'batch' ->> 'status') = 'draft'
  and (:'part1'::jsonb -> 'batch' -> 'batch_totals' ->> 'source_rows')::int = 3
  and (:'part1'::jsonb -> 'batch' ->> 'finalized')::boolean = false,
  '٢ · الجزء الأول يترك الدفعة مفتوحةً على 3 من 6 — لا يقفلها');

select pg_temp.ok(
  (select count(*) from public.audit_logs
   where entity_id = :'sc_batch'::uuid
     and action = 'saas.activation_events.imported') = 0,
  '  · ولا صفَّ تدقيقٍ يقول «استُورد» ما دام الملف ناقصاً');

select pg_temp.must_fail_with(
  format($q$select public.import_saas_activation_events(
    'big.xlsx', 'sc-chunk-1', 'saas-import.js',
    jsonb_build_array(jsonb_build_object('saas_event_id','SC-CH-X','username','sc-ch-x')),
    gen_random_uuid(), null, null, %L::uuid, 6, true, 3)$q$, :'sc_batch'),
  '  · وإنهاءٌ قبل اكتمال الصفوف المصرَّح بها يسقط صراحةً',
  'finalization requested before all rows were received');

select public.import_saas_activation_events(
  'big.xlsx', 'sc-chunk-1', 'saas-import.js',
  jsonb_build_array(
    jsonb_build_object('saas_event_id', 'SC-CH-4', 'username', 'sc-ch-4'),
    jsonb_build_object('saas_event_id', 'SC-CH-5', 'username', 'sc-ch-5'),
    jsonb_build_object('saas_event_id', 'SC-CH-6', 'username', 'sc-ch-6')
  ),
  '5c000000-0000-0000-0000-0000000000c3'::uuid,
  null, null, :'sc_batch'::uuid, 6, true, 3
) as part2 \gset

select pg_temp.ok(
  (:'part2'::jsonb -> 'batch' ->> 'status') = 'imported'
  and (:'part2'::jsonb -> 'batch' -> 'batch_totals' ->> 'source_rows')::int = 6
  and (:'part2'::jsonb -> 'batch' -> 'batch_totals' ->> 'accepted')::int = 6,
  '  · والجزء الأخير يُنهيها على 6 من 6 — إجماليُّ الملف لا الجزء');

select pg_temp.ok(
  (select count(*) from public.saas_import_batches
   where source_checksum = 'sc-chunk-1' and source_kind = 'ACTIVATION_EVENTS') = 1
  and (select count(*) from public.saas_activation_events
       where import_batch_id = :'sc_batch'::uuid) = 6,
  '  · ملفٌّ واحدٌ بجزأين يبقى دفعةً منطقيةً واحدةً تحمل صفوفه كلها');

select pg_temp.ok(
  (select count(*) from public.audit_logs
   where entity_id = :'sc_batch'::uuid
     and action = 'saas.activation_events.imported') = 1
  and (select count(*) from public.audit_logs
       where entity_id = :'sc_batch'::uuid
         and action = 'saas.activation_events.chunk_received') = 1,
  '  · وصفُّ تدقيقٍ نهائيٌّ واحدٌ للملف كله، لا واحدٌ لكل جزء');

-- ===========================================================================
-- ٣. إعادة التشغيل: تحديث الصفحة أثناء الرفع يُعيد الملف من أوّله.
--
-- الأجزاء المُستقبَلة سلفاً لا تُعدّ ثانيةً ولا يُقرأ محتواها ثانيةً — ولو
-- وصلت بمحتوىً مختلفٍ تماماً في نفس الموضع.
-- ===========================================================================

select public.import_saas_activation_events(
  'restart.xlsx', 'sc-restart-1', 'saas-import.js',
  jsonb_build_array(
    jsonb_build_object('saas_event_id', 'SC-RS-1', 'username', 'sc-rs-1'),
    jsonb_build_object('saas_event_id', 'SC-RS-2', 'username', 'sc-rs-2')
  ),
  gen_random_uuid(), null, null, null, 4, false, 0
) as rs1 \gset

select (:'rs1'::jsonb -> 'batch' ->> 'batch_id') as rs_batch \gset

-- إعادة إرسال نفس الموضع بمعرّف طلبٍ جديد وبمحتوىً مختلف: لا شيء يتغيّر.
select public.import_saas_activation_events(
  'restart.xlsx', 'sc-restart-1', 'saas-import.js',
  jsonb_build_array(
    jsonb_build_object('saas_event_id', 'SC-RS-IMPOSTOR-1', 'username', 'sc-rs-x'),
    jsonb_build_object('saas_event_id', 'SC-RS-IMPOSTOR-2', 'username', 'sc-rs-y')
  ),
  gen_random_uuid(), null, null, null, 4, false, 0
) as rs2 \gset

select pg_temp.ok(
  (:'rs2'::jsonb -> 'batch' ->> 'source_rows')::int = 0
  and (:'rs2'::jsonb -> 'batch' ->> 'accepted')::int = 0
  and (:'rs2'::jsonb -> 'batch' -> 'batch_totals' ->> 'source_rows')::int = 2,
  '٣ · موضعٌ استُقبل سلفاً لا يُعدّ ثانيةً — source_rows لا يتضخّم بالإعادة');

select pg_temp.ok(
  (select count(*) from public.saas_activation_events
   where saas_event_id like 'SC-RS-IMPOSTOR-%') = 0,
  '  · ولا يُقرأ محتواه ثانيةً: محتوىً مختلفٌ في موضعٍ مُستقبَلٍ لا يدخل');

select pg_temp.ok(
  (select count(*) from public.saas_import_batches
   where source_checksum = 'sc-restart-1') = 1
  and (select status from public.saas_import_batches
       where source_checksum = 'sc-restart-1') = 'draft',
  '  · والرفع من أوّله لا يُنشئ دفعةً ثانيةً للملف نفسه — يستأنف الأولى');

-- تراكبٌ جزئي: [1,3) نصفه مُستقبَلٌ ونصفه جديد.
select public.import_saas_activation_events(
  'restart.xlsx', 'sc-restart-1', 'saas-import.js',
  jsonb_build_array(
    jsonb_build_object('saas_event_id', 'SC-RS-IMPOSTOR-3', 'username', 'sc-rs-z'),
    jsonb_build_object('saas_event_id', 'SC-RS-3', 'username', 'sc-rs-3')
  ),
  gen_random_uuid(), null, null, :'rs_batch'::uuid, 4, false, 1
) as rs3 \gset

select pg_temp.ok(
  (:'rs3'::jsonb -> 'batch' ->> 'source_rows')::int = 1
  and (:'rs3'::jsonb -> 'batch' ->> 'accepted')::int = 1
  and (select count(*) from public.saas_activation_events
       where saas_event_id = 'SC-RS-IMPOSTOR-3') = 0,
  '  · وتراكبٌ جزئيّ يُحتسب جديدَه وحده، ويترك المُستقبَل على حاله');

-- ===========================================================================
-- ٤. إعادة الطلب وهوية الملف: كما كانتا قبل التجزئة تماماً.
-- ===========================================================================

select public.import_saas_activation_events(
  'mix.xlsx', 'sc-mix-1', 'saas-import.js',
  jsonb_build_array(jsonb_build_object('saas_event_id', 'SC-EV-1', 'username', 'sc-user-1')),
  '5c000000-0000-0000-0000-0000000000c1'::uuid
) as replay \gset

select pg_temp.ok(
  (:'replay'::jsonb ->> 'replayed')::boolean = true
  and (select count(*) from public.saas_activation_events
       where saas_event_id like 'SC-EV-%') = 3,
  '٤ · نفس معرّف الطلب إعادةٌ للنتيجة الأصلية، لا استيرادٌ ثانٍ');

select pg_temp.must_fail_with(
  $q$select public.import_saas_activation_events(
    'mix-renamed.xlsx', 'sc-mix-1', 'saas-import.js',
    jsonb_build_array(jsonb_build_object('saas_event_id','SC-EV-99','username','sc-user-99')),
    gen_random_uuid())$q$,
  '  · ونفس بصمة الملف بطلبٍ جديد بعد الإنهاء مرفوضةٌ صراحةً',
  'was already imported as batch');

select pg_temp.must_fail_with(
  $q$select public.import_saas_activation_events(
    'other-name.xlsx', 'sc-restart-1', 'saas-import.js',
    jsonb_build_array(jsonb_build_object('saas_event_id','SC-RS-9','username','sc-rs-9')),
    gen_random_uuid(), null, null, null, 4, false, 3)$q$,
  '  · ودفعةٌ مفتوحةٌ لا تُلحق بها صفوفُ ملفٍّ باسمٍ آخر',
  'different file name');

select pg_temp.must_fail_with(
  $q$select public.import_saas_activation_events(
    'open.xlsx', 'sc-open-nocount', 'saas-import.js',
    jsonb_build_array(jsonb_build_object('saas_event_id','SC-NC-1','username','sc-nc-1')),
    gen_random_uuid(), null, null, null, null, false, 0)$q$,
  '  · وفتحُ دفعةٍ للإلحاق بلا عددٍ مُعلَنٍ موجَبٍ مرفوضٌ عند حدود الخادم',
  'expected_rows is required');

-- ===========================================================================
-- ٥. الجسر: التغطية الكاملة لدفعةٍ مرشّحوها أكثر من نافذةٍ واحدة.
--
-- الممنوع لا يُسجَّل فيبقى مرشّحاً. فلو أخذ المسح أوّل p_limit مرشّحاً دائماً،
-- لبقي أوّلُ خمسةٍ ممنوعين يحتلّون النافذة إلى الأبد ولما بلغ المسحُ السادس
-- منهم. المؤشّر هو ما يجعل التغطية حتميّةً لا احتمالية.
-- ===========================================================================

select public.import_saas_activation_events(
  'cand.xlsx', 'sc-cand-1', 'saas-import.js',
  (select jsonb_agg(jsonb_build_object(
     'saas_event_id', 'SC-CAND-' || lpad(i::text, 2, '0'),
     'username', 'sc-cand-' || lpad(i::text, 2, '0')) order by i)
   from generate_series(1, 12) i),
  gen_random_uuid()
) as cand \gset

select (:'cand'::jsonb -> 'batch' ->> 'batch_id') as cand_batch \gset

select public.bridge_saas_activations_to_enrollments(
  :'cand_batch'::uuid, 5, gen_random_uuid(), null) as sw1 \gset

select pg_temp.ok(
  (:'sw1'::jsonb #>> '{result,considered}')::int = 5
  and (:'sw1'::jsonb #>> '{result,enrolled}')::int = 0
  and (:'sw1'::jsonb #>> '{result,blocked}')::int = 5
  and (:'sw1'::jsonb #>> '{result,remaining}')::int = 7
  and (:'sw1'::jsonb #>> '{result,exhausted}')::boolean = false
  and (:'sw1'::jsonb #>> '{result,last_username_key}') = 'sc-cand-05',
  '٥ · المسحة الأولى تنظر في 5 وتقول صراحةً إن 7 بقوا بعدها');

select public.bridge_saas_activations_to_enrollments(
  :'cand_batch'::uuid, 5, gen_random_uuid(), null) as sw_repeat \gset

select pg_temp.ok(
  (:'sw_repeat'::jsonb #>> '{result,last_username_key}') = 'sc-cand-05'
  and (:'sw_repeat'::jsonb #>> '{result,remaining}')::int = 7,
  '  · وإعادة المسحة نفسها بلا مؤشّر لا تُقدّم شيئاً — الممنوع يحتلّ نافذته');

select public.bridge_saas_activations_to_enrollments(
  :'cand_batch'::uuid, 5, gen_random_uuid(), 'sc-cand-05') as sw2 \gset

select public.bridge_saas_activations_to_enrollments(
  :'cand_batch'::uuid, 5, gen_random_uuid(), 'sc-cand-10') as sw3 \gset

select pg_temp.ok(
  (:'sw2'::jsonb #>> '{result,considered}')::int = 5
  and (:'sw2'::jsonb #>> '{result,remaining}')::int = 2
  and (:'sw3'::jsonb #>> '{result,considered}')::int = 2
  and (:'sw3'::jsonb #>> '{result,remaining}')::int = 0
  and (:'sw3'::jsonb #>> '{result,exhausted}')::boolean = true,
  '  · والمؤشّر يُغطّي الاثني عشر كلهم في ثلاث مسحاتٍ حتميّة');

select pg_temp.ok(
  (:'sw1'::jsonb #>> '{result,reasons,SOURCE_INCOMPLETE}')::int = 5
  and (:'sw2'::jsonb #>> '{result,reasons,SOURCE_INCOMPLETE}')::int = 5,
  '  · وكل ممنوعٍ يعود بسببه معدوداً — لا تسجيلَ أعمى ولا سببَ مفقود');

select pg_temp.ok(
  (select count(*) from public.installation_enrollments
   where subscriber_id like 'sc-cand-%') = 0,
  '  · ولا مرشّحٌ واحدٌ سُجّل: البوابة وحدها تقرّر، والمصدر غير مُعلَن الاكتمال');

-- ===========================================================================
-- ٦. الاستيراد الخام يبقى تاريخاً خاماً: لا مال، ولا استحقاق.
-- ===========================================================================

select pg_temp.ok(
  (select entitlements from sc_before) = (select count(*) from public.installation_entitlements)
  and (select payments from sc_before) = (select count(*) from public.installation_payments)
  and (select ledger_total from sc_before) = (select coalesce(sum(amount), 0) from public.financial_ledger),
  '٦ · لا استحقاق ولا دفعة ولا قيدٌ مالي: الاستيراد يكتب التاريخ الخام وحده');

rollback;
