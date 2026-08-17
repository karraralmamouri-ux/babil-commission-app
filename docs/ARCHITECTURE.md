# البنية المعمارية

## الحالة الحالية

```text
GitHub Pages / index.html
├── HTML + CSS + JavaScript
├── Supabase Auth + profiles
├── Edge Function: admin-users (المصدر غير موجود في Git)
└── localStorage
    ├── بيانات العمولات
    ├── الأشهر والأرشيف
    └── سجل التعديلات
```

لا توجد طبقة بيانات مركزية للعمولات، ولا فصل واضح بين domain وواجهة المستخدم.

## البنية الانتقالية

تقسيم الملف دون تغيير السلوك:

```text
index.html
assets/
├── css/
├── js/
│   ├── config
│   ├── auth
│   ├── permissions
│   ├── commissions
│   ├── payments
│   ├── periods
│   ├── users
│   ├── audit
│   ├── import-export
│   ├── ui
│   └── main
└── vendor/
```

كل خطوة انتقال يجب أن تحافظ على GitHub Pages ونتائج الاختبارات التوصيفية.

## البنية المستهدفة

```text
Browser / GitHub Pages
├── Vite + TypeScript + RTL UI
├── Supabase SDK (publishable key only)
└── Feature modules
    ├── auth and profiles
    ├── agents
    ├── periods and rates
    ├── commissions
    ├── payment ledger
    ├── audit
    └── import/export

Supabase
├── Postgres + constraints
├── RLS policies
├── transactional RPCs
├── Auth
├── Edge Functions
└── backups and logs
```

## حدود المسؤوليات

- `domain`: حسابات خالصة لا تقرأ DOM ولا الشبكة.
- `services`: الوصول إلى Supabase والاستيراد والتصدير.
- `features`: حالات الاستخدام والتنسيق بين domain والخدمات.
- `components`: العرض والتفاعل فقط.
- `supabase/migrations`: المصدر القابل لإعادة إنشاء المخطط والسياسات.
- `supabase/functions`: مصدر العمليات الإدارية الخادمية.
- المعاينة المركزية في `index.html` مسار pilot للقراءة فقط: تجلب الأشهر والصفوف بجلسة المستخدم وRLS، تحولها إلى نموذج العرض الحالي، ولا تكتب إلى Supabase أو `localStorage`.

## تدفق العملية المالية المستهدف

```text
إدخال/استيراد
→ تحقق محلي مبدئي
→ تحقق خادمي وصلاحية RLS/RPC
→ كتابة transaction
→ إنشاء audit event
→ إعادة النتيجة والإصدار
→ تحديث الواجهة
```

لا تعتمد العملية المالية على زر حفظ عام أو على `localStorage`.

## البنية المستهدفة — Reseller Financial Operations

هذا الملف يصف البنية القائمة. التصميم المستهدف لتطوير المنتج إلى نظام عمليات مالية
كامل للوكلاء موثَّق منفصلاً، ولم يُنفَّذ منه شيء بعد:

- [المخطط العام](product/reseller-financial-operations-blueprint.md)
- [قواعد أجور التنصيب](product/installation-fees-business-rules.md)
- [آلة الحالات المالية](product/financial-state-machine.md)
- [خريطة الشاشات المستهدفة](product/navigation-and-screen-map-vnext.md)
- [نموذج النطاق المالي](engineering/financial-domain-model-vnext.md)
- [محرك الإعدادات المُصدَّرة](engineering/configuration-engine-architecture.md)
- [نموذج الصلاحيات والنطاقات](engineering/permission-and-scope-model.md)
- [عقد الاستيراد والمطابقة](engineering/saas-import-matching-contract.md)
- [ضوابط الصرف](engineering/finance-payment-controls.md)
- [الترحيل التاريخي والقطع](engineering/historical-migration-and-cutover.md)
- [خارطة الترحيل](engineering/migration-roadmap-vnext.md)
- [الحالة الحالية مقابل المستهدفة](engineering/current-vs-target-state.md)
- [المخاطر والقرارات المفتوحة](engineering/risk-and-open-decisions.md)
