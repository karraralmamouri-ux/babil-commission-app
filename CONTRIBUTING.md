# المساهمة في المشروع

## سير العمل

1. حدّث `main` وافحص أن شجرة العمل نظيفة.
2. أنشئ فرعاً محدود الغرض مثل `feat/payment-ledger` أو `fix/period-ordering`.
3. افصل تغييرات التوثيق، وإعادة الهيكلة، والسلوك، وقاعدة البيانات قدر الإمكان.
4. نفّذ الاختبارات المذكورة في `docs/TEST_PLAN.md` وسجل النتائج.
5. حدّث `PROJECT_STATUS.md` و`DECISIONS.md` و`CHANGELOG.md` عند انطباقها.
6. افتح Pull Request يتضمن الخطر، طريقة الاختبار، وخطة الرجوع.

## رسائل commit

استخدم رسائل واضحة على نمط Conventional Commits:

```text
docs: establish persistent project context
test: capture commission tier boundaries
refactor: extract commission calculator
fix: order financial periods across years
feat: record payments as immutable transactions
```

## متطلبات Pull Request

- وصف المشكلة والهدف.
- نطاق الملفات المتغيرة.
- تأثير البيانات أو migration إن وجد.
- نتائج الاختبارات والبناء.
- صور قبل/بعد للتغييرات المرئية.
- أثر الأمان والصلاحيات.
- خطة الرجوع أو الاسترجاع.
- أسئلة أو قرارات معلقة.

## المحظورات

- لا أسرار أو بيانات تشغيلية حقيقية في Git.
- لا تعديل مباشر لتاريخ Git أو `main`.
- لا migration إنتاجية دون نسخة احتياطية وتجربة Staging.
- لا تغيير لأسعار أو قواعد العمولة دون قرار تجاري موثق.
