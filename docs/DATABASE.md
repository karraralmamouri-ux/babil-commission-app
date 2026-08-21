# قاعدة البيانات

تتضمن هذه الوثيقة المخطط الحالي المؤكد، ثم التصميم المستهدف الذي يبقى خاضعاً للقرارات التجارية.

## المخطط الحالي المؤكد

المخطط الحالي محفوظ في migrations وقابل لإعادة البناء على بيئة فارغة:

- `profiles` للأدوار والحالة النشطة.
- `commission_months` و`commission_rows` للنموذج المطبع المستخدم في البيانات المركزية.
- `commission_agents` نموذج قديم فارغ يحتاج قرار إزالة منفصلاً.
- `audit_logs` و`commission_audit_logs` نموذجان متداخلان وفارغان حالياً.
- جميع الجداول تستخدم RLS.
- تعديل profiles مباشر ممنوع، والقراءة للصف الذاتي أو المدير.

أُعيد إنشاء المخطط على Staging من migrations، وطابق الإنتاج في الجداول والأعمدة والقيود والفهارس والدوال والتريغرز والسياسات والمنح. تفاصيل البيئة والاختبار في `docs/STAGING.md`.

## التصميم المستهدف

## مبادئ

- UUID ثابت لكل وكيل وسجل.
- الشهر يمثل بتاريخ مثل أول يوم من الشهر، لا بنص `MM/YYYY`.
- المبالغ تحفظ كأعداد صحيحة `bigint` إذا تأكد عدم وجود كسور.
- الكميات والمبالغ غير سالبة بقيود قاعدة البيانات.
- الأسعار المستخدمة تحفظ لكل فترة ولا تتأثر بتغيير المستقبل.
- الدفعات سجل معاملات، وليست قيمة تراكمية قابلة للكتابة فوقها.
- العمليات المهمة تسجل مركزياً.

## الجداول المقترحة

### profiles

`id`, `full_name`, `email`, `role`, `is_active`, timestamps. يرتبط `id` بـ`auth.users`.

### agents

`id`, `code`, `name`, `zone`, `is_active`, `created_by`, timestamps. يحتاج قراراً حول تفرد `code` وسياسة نقل المنطقة.

### commission_periods

`id`, `period_start`, `status`, `version`, `created_by`, `approved_by`, `approved_at`, `locked_at`, timestamps. قيد فريد على `period_start`.

الحالات المقترحة: `draft`, `submitted`, `approved`, `locked`.

### commission_rate_tiers

`id`, `period_id`, `tier_code`, `min_quantity`, `max_quantity`, `p35_rate`, `p45_rate`, `p65_rate`, `created_by`, timestamps.

`max_quantity` يكون `NULL` للشريحة المفتوحة بدلاً من `Infinity`.

### commission_entries

`id`, `period_id`, `agent_id`, كميات P35/P45/P65، `tier_mode`, `selected_tier_id`, `amount_due`, `calculation_snapshot`, `version`, حقول المنشئ والمعدل، timestamps.

قيد فريد على `(period_id, agent_id)`.

### payments

`id`, `commission_entry_id`, `amount`, `payment_date`, `reference`, `notes`, `status`, حقول الإنشاء والإلغاء، timestamps.

إلغاء الدفعة ينشئ حالة/عملية عكسية موثقة ولا يحذف التاريخ.

### audit_events

`id`, `actor_id`, `action`, `entity_type`, `entity_id`, `before_data`, `after_data`, `request_id`, `created_at`.

### import_batches / import_rows

دفعات الاستيراد، بصمة الملف، حالة المعاينة والاعتماد، الأخطاء، التعارضات، ونتيجة كل صف.

## invariants مطلوبة

- لا أكثر من سجل عمولة للوكيل في الفترة نفسها.
- مجموع الدفعات الفعالة لا يتجاوز المستحق إلا بعملية خادمية مصرح بها إن قرر العمل ذلك.
- الفترة المقفلة لا تعدل سجلاتها أو أسعارها مباشرة.
- الشريحة المختارة تنتمي إلى الفترة نفسها.
- كل كتابة تحمل المستخدم والتوقيت.
- الاستيراد idempotent بواسطة بصمة و`migration_id`.

## مسار انتقالي قيد التحقق

المهاجرة `20260804230000_add_atomic_financial_rpcs.sql` تبقي الجداول الحالية وتضيف حقول audit منظمة و`request_id` فريداً لكل مستخدم. وتقترح دالتين قبل ربط الواجهة:

- `update_commission_row`: للمدير فقط، مع قفل الصف وكشف التعارض.
- `record_commission_payment`: للمدير والمحاسب، وتحسب المستحق من شرائح الشهر خادمياً وتمنع تجاوزه.

تكتب الدالتان `before_data` و`after_data` داخل المعاملة نفسها. نجح تحقق هذه البنية على Staging في 56 مطالبة، وطُبقت على الإنتاج بعد نسخة ومطابقة كاملة. تبقى غير مستخدمة من الواجهة إلى أن يكتمل جرد `localStorage` والـpilot.

المهاجرة `20260809190000_add_central_month_workflow.sql` تضيف مسار اعتماد الشهر التالي:

- حقول اعتماد الشهر وحالة `draft/approved`.
- هوية مجموعة التير وحساب `parent` والمالك وأساس الكمية في `commission_rows`.
- جدول `app_settings` للقراءة المشتركة مع كتابة إدارية عبر RPC فقط.
- `publish_commission_month`: عملية إدارية ذرية وidempotent تتحقق خادمياً من التير والمستحق، تحفظ الصرف الموجود، وترفض حذف صف له دفعة أو تخفيض المستحق تحت المدفوع.
- `commission_months.is_visible`: تحفظ الفترات السابقة كمخفية عند الإطلاق النظيف بدلاً من حذفها، وتكون الفترات الجديدة أو المعاد اعتمادها ظاهرة.
- `save_import_settings`: يحفظ إعدادات الاستيراد المشتركة ويسجل قبل/بعد وrequest ID.

طُبقت هذه المهاجرة على Staging ثم الإنتاج في 2026-08-09. بقيت فترتا الإنتاج السابقتان و82 صفاً محفوظة، وأصبحت الفترتان مخفيتين حتى يعيد الأدمن اعتمادهما صراحةً.

## migrations

توضع الملفات في `supabase/migrations/` بترتيب زمني. كل migration تشمل القيود والفهارس وRLS والـgrants اللازمة، وتختبر على Staging قبل الإنتاج.

### المبلغ المؤشّر لاستثناءات الكابينات

`commission_exceptions` لا يخزن `indicative_amount`. هذا مقصود: المبلغ المؤشّر قراءة مشتقة من `indicative_rates(cycle_id)` وربط `saas_activation_events.profile_name` مع `package_code`. عقدا `current_unknown_fdt_decisions` و`current_unknown_fdt_events` في migration 67 يطبقان هذا الاشتقاق ولا ينشئان التزاماً مالياً أو يغيران نتيجة دورة.
