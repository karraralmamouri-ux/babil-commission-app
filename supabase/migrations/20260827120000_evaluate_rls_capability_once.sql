-- تقييم صلاحية الصف مرة واحدة لا مرة لكل صف.
--
-- العيب، مقيساً على الإنتاج لا مُستنتَجاً:
--
--   select count(*) from commission_exceptions where status = 'OPEN'
--   Execution Time: 16,426 ms
--   Buffers: shared hit=364,134        ← 2.9 غيغابايت لجدول حجمه 19 ميغابايت
--   Filter: has_capability('commission.view')
--
-- السياسة تستدعي has_capability لكل صف. الدالة STABLE وتقرأ جداول الصلاحيات،
-- فكل صف من 22,727 صفاً يُعيد تنفيذ الاستعلام كاملاً. النتيجة ست عشرة ثانية
-- لعدٍّ بسيط — وهذه هي شاشة الاستثناءات نفسها التي يُفترض أن يُدار منها
-- إغلاق الشهر.
--
-- الوسيطات في كل سياسة ثوابت نصّية، لا تعتمد على أي عمود من الصف. فالنتيجة
-- واحدة لكل الصفوف بالضرورة، وتقييمها مرة واحدة ليس تخفيفاً للحراسة بل
-- إزالة تكرار لا معنى له. لفّها في استعلام قياسي يجعل المخطِّط يحسبها
-- InitPlan مرة واحدة قبل المسح.
--
-- ما لا يتغيّر: الدالة نفسها، والقدرة المطلوبة نفسها، والنتيجة نفسها. من لا
-- يملك القدرة لا يرى صفاً واحداً قبل هذا التغيير ولا بعده.
--
-- الاستثناء الوحيد: user_permission_overrides تجمع شرطاً يعتمد على الصف
-- (user_id = auth.uid()) مع نداء ثابت. الأول يبقى لكل صف لأنه كذلك فعلاً،
-- والثاني وحده يُلَفّ.
--
-- forward-only. لا صف بيانات يُمَس.

begin;

-- ---------------------------------------------------------------------------
-- نطاق العمولة
-- ---------------------------------------------------------------------------

drop policy if exists commission_exceptions_select on public.commission_exceptions;
create policy commission_exceptions_select on public.commission_exceptions
  for select using ((select public.has_capability('commission.view')));

drop policy if exists commission_event_entitlements_select on public.commission_event_entitlements;
create policy commission_event_entitlements_select on public.commission_event_entitlements
  for select using ((select public.has_capability('commission.view')));

drop policy if exists commission_cycle_snapshots_select on public.commission_cycle_snapshots;
create policy commission_cycle_snapshots_select on public.commission_cycle_snapshots
  for select using ((select public.has_capability('commission.view')));

drop policy if exists commission_cycles_select on public.commission_cycles;
create policy commission_cycles_select on public.commission_cycles
  for select using ((select public.has_capability('commission.view')));

drop policy if exists commission_package_rates_select on public.commission_package_rates;
create policy commission_package_rates_select on public.commission_package_rates
  for select using ((select public.has_capability('commission.view')));

drop policy if exists commission_tier_definitions_select on public.commission_tier_definitions;
create policy commission_tier_definitions_select on public.commission_tier_definitions
  for select using ((select public.has_capability('commission.view')));

drop policy if exists commission_schemes_select on public.commission_schemes;
create policy commission_schemes_select on public.commission_schemes
  for select using ((select public.has_capability('commission.view')));

drop policy if exists commission_scheme_versions_select on public.commission_scheme_versions;
create policy commission_scheme_versions_select on public.commission_scheme_versions
  for select using ((select public.has_capability('commission.view')));

drop policy if exists commission_payment_batches_select on public.commission_payment_batches;
create policy commission_payment_batches_select on public.commission_payment_batches
  for select using ((select public.has_capability('commission.view')));

drop policy if exists commission_payment_batch_items_select on public.commission_payment_batch_items;
create policy commission_payment_batch_items_select on public.commission_payment_batch_items
  for select using ((select public.has_capability('commission.view')));

-- ---------------------------------------------------------------------------
-- نطاق التنصيب
-- ---------------------------------------------------------------------------

drop policy if exists installation_enrollments_select on public.installation_enrollments;
create policy installation_enrollments_select on public.installation_enrollments
  for select using ((select public.has_capability('installation.view')));

drop policy if exists installation_holds_select on public.installation_holds;
create policy installation_holds_select on public.installation_holds
  for select using ((select public.has_capability('installation.view')));

drop policy if exists installation_invoices_select on public.installation_invoices;
create policy installation_invoices_select on public.installation_invoices
  for select using ((select public.has_capability('invoice.view')));

drop policy if exists installation_cycles_select on public.installation_cycles;
create policy installation_cycles_select on public.installation_cycles
  for select using ((select public.has_capability('cycle.view')));

drop policy if exists installation_payment_batches_select on public.installation_payment_batches;
create policy installation_payment_batches_select on public.installation_payment_batches
  for select using ((select public.has_capability('payment.view')));

drop policy if exists installation_payment_batch_items_select on public.installation_payment_batch_items;
create policy installation_payment_batch_items_select on public.installation_payment_batch_items
  for select using ((select public.has_capability('payment.view')));

-- ---------------------------------------------------------------------------
-- بقيّة النطاقات
-- ---------------------------------------------------------------------------

drop policy if exists import_completeness_declarations_select on public.import_completeness_declarations;
create policy import_completeness_declarations_select on public.import_completeness_declarations
  for select using ((select public.has_capability('saas.review')));

drop policy if exists integration_settings_select on public.integration_settings;
create policy integration_settings_select on public.integration_settings
  for select using ((select public.has_capability('invoice.view')));

-- الشرط الأول يعتمد على الصف فعلاً فيبقى لكل صف؛ الثاني وحده يُلَفّ.
drop policy if exists user_permission_overrides_select on public.user_permission_overrides;
create policy user_permission_overrides_select on public.user_permission_overrides
  for select using (
    user_id = (select auth.uid())
    or (select public.has_capability('permission.manage')));

commit;
