# Babil Commission App

لوحة عربية RTL لإدارة عمولات وكلاء خدمات الإنترنت في محافظة بابل. تدير الوكلاء ضمن `OLD ZONE` و`NEW ZONE`، وتفعيلات `P35` و`P45` و`P65`، وشرائح الأسعار، والاستحقاق، والصرف، والأرشيف الشهري.

> الحالة الحالية: نموذج أولي منشور. المصادقة وملفات المستخدمين مرتبطة بـSupabase، بينما بيانات العمولات والأرشيف وسجل التعديلات ما زالت محلية في المتصفح. راجع [حالة المشروع](docs/PROJECT_STATUS.md) و[تدقيق خط الأساس](docs/BASELINE_AUDIT.md) قبل أي تعديل.

## التشغيل الحالي

المشروع الحالي صفحة ثابتة واحدة ولا يحتاج build:

1. افتح `index.html` عبر خادم HTTP محلي، وليس عبر `file://`، لتقريب سلوك GitHub Pages.
2. استخدم مشروع Supabase المهيأ مسبقاً وحساب اختبار غير إنتاجي.
3. لا تعتمد على بيانات `localStorage` كتخزين مركزي أو نسخة احتياطية.

مثال باستخدام خادم متاح محلياً:

```text
python -m http.server 8080
```

ثم افتح `http://localhost:8080`.

## الاختبارات الحالية

تحتاج Node.js 20 أو أحدث، ولا توجد تبعيات npm في خط الأساس التوصيفي:

```text
npm test
```

تقرأ الاختبارات منطق JavaScript الفعلي داخل `index.html` ضمن بيئة معزولة بلا شبكة، لتثبيت نتائج الحساب الحالية قبل إعادة الهيكلة.

## النشر الحالي

يُنشر فرع `main` مباشرة بواسطة GitHub Pages. لا يوجد workflow مخصص داخل المستودع؛ يستخدم GitHub workflow ديناميكياً باسم `pages-build-deployment`.

لا تدفع مباشرة إلى `main`. استخدم فرعاً وPull Request، وتحقق من النسخة المنشورة بعد الدمج.

## متغيرات البيئة المستقبلية

راجع `.env.example`. الواجهة تحتاج فقط إلى URL وPublishable/Anon key. أي `service_role` يجب أن يبقى داخل Supabase Edge Functions ولا يصل إلى المتصفح أو GitHub.

## مكونات الطرف الثالث

تستخدم الصفحة نسخة محلية مثبتة من SheetJS CE لاستيراد Excel. راجع `THIRD_PARTY_NOTICES.md` وملف الترخيص داخل `assets/vendor/`. لا تستبدل ملف vendor دون تحديث الإصدار والبصمة واختبار round-trip.

## وثائق المشروع

- [سياق المشروع](docs/PROJECT_CONTEXT.md)
- [الحالة الحالية](docs/PROJECT_STATUS.md)
- [تدقيق خط الأساس](docs/BASELINE_AUDIT.md)
- [البنية](docs/ARCHITECTURE.md)
- [قاعدة البيانات](docs/DATABASE.md)
- [الأمان](docs/SECURITY.md)
- [القرارات](docs/DECISIONS.md)
- [خارطة الطريق](docs/ROADMAP.md)
- [سجل المخاطر](docs/RISK_REGISTER.md)
- [خطة الاختبار](docs/TEST_PLAN.md)
- [دليل التشغيل](docs/RUNBOOK.md)

## المساهمة

اقرأ `AGENTS.md` و`CONTRIBUTING.md` قبل بدء العمل. قواعد العمولة والأسعار متطلبات تجارية ولا يجوز تغييرها بافتراضات تقنية.
