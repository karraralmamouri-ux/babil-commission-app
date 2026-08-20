# الخروج من الشاشات السابقة — الجرد الكامل

**BABIL FLOW · Reseller Financial Operations**

٢٠٢٦-٠٨-٢٠ · الأساس المجمَّد `v1.0.0` = `75f9b35` — لم يُمسّ.

---

## ١. الحكم

`index.html` صار **للقراءة التاريخية فقط**. لم تبقَ فيه كتابةٌ واحدة على
المال أو البيانات الرئيسية أو الصلاحيات، ويحرس ذلك اختبارٌ يسقط إن عادت.

الشاشة تُعلن ذلك عن نفسها بشريطٍ في أعلاها:
**«نسخة قديمة — للعرض التاريخي فقط. كل كتابة انتقلت إلى التطبيق.»**

---

## ٢. ما انتقل — ثمانية عشر مساراً

| كان في الشاشة السابقة | صار في |
|---|---|
| `import_installation_entitlements` | `/system/imports/new` |
| `import_installation_history` | `/system/imports/new` |
| `set_user_permission` | `/system/users/:id` |
| `update_user_profile` (الدور والتفعيل) | `/system/users/:id` |
| إنشاء حساب · كلمة المرور | `/system/users` و`/system/users/:id` |
| `resolve_commission_exception` | `/exceptions` و تبويب الاستثناءات |
| `calculate_commission_cycle` (حساب) | `/commissions/cycles/:id/review` |
| `calculate_commission_cycle` (اعتماد) | `/commissions/cycles/:id/review` |
| `close_commission_cycle` | `/commissions/cycles/:id/review` |
| `reopen_commission_cycle` | `/commissions/cycles/:id/review` |
| `recalculate_cycle_after_master_change` | `/commissions/cycles/:id/review` |
| `export_commission_cycle` | `/commissions/cycles/:id/review` |
| `revalidate_commission_batch` | `/finance/payment-batches/:id` |
| `post_commission_batch` | `/finance/payment-batches/:id` |
| `register_fdt` · `register_fdt_bulk` | `/master/fdts` |
| `audit_installation_invoice` | `/installation/invoices` |
| فتح دورة (لم يكن له مسار خادميّ) | `/commissions/cycles` |
| الوكلاء والباقات (لم يكن لهما مسار كتابة) | `/master/agents` و`/master/packages` |

---

## ٣. ما تقاعد ولم ينتقل — محرّك الشهر السابق

ثلاثة مسارات لا بديل لها لأن محرّك الدورات حلّ محلّ محرّك الشهر كلّه:

| المسار | لماذا لا بديل |
|---|---|
| `publish_commission_month` | الاعتماد صار بالدورة، لا بالشهر |
| `record_commission_payment` | الصرف صار بالدفعة، لا بالصفّ |
| `save_import_settings` | إعدادات قراءة الملف الخام تتبع استيراداً متقاعداً |

بياناته باقية: **دورتان و82 صفّاً** في `commission_months` و`commission_rows`.
تُقرأ ولا تُكتب. ومحرّكان يكتبان المال نفسه ينتهيان إلى رقمين مختلفين، وهذا
هو سبب التقاعد لا سواه.

---

## ٤. ما بقي في الشاشة السابقة — كلّه قراءة

عشرة نداءات، كلّها استعلام:

`report_management_summary` · `report_commission_exception_impact` ·
`report_commission_cycle_detail` · `report_agent_statement` ·
`report_audit_trail` · `report_open_exceptions` · `agent_financial_profile` ·
`installation_financials` · `installation_entitlement_eligibility` ·
`my_capabilities`

ونداءٌ واحد لدالّة الحافة: `list`.

ونقاط المصادقة — الدخول والخروج وتغيير المستخدم كلمة مرور نفسه — وهي
ليست كتابةً على بيانات العمل.

> **ملاحظة:** `save()` في الشاشة السابقة ما زال يكتب في `localStorage`.
> لا يصل إلى الخادم، ولا سبيل لتصعيد ذلك إلى القاعدة بعد تقاعد
> `publish_commission_month`. أثره محصور في متصفّح صاحبه.

---

## ٥. السلطة المزدوجة على `profiles`

كانت دالّة الحافة `admin-users` تكتب `role` و`is_active` بمفتاح خدمة، بحارسٍ
أضعف من حارس الدالّة: تمنع الإداريّ من نزع صلاحية **نفسه** فقط. فكان بإمكان
إداريٍّ أن ينزع صلاحية الإداريّ الأخير غيره ويُقفل النظام على الجميع.

صار المسار واحداً:

- **الدور والتفعيل والاسم** → `update_user_profile`: يفحص `permission.manage`،
  ويشترط سبباً مكتوباً، ويعدّ الإداريين الفعّالين كلّهم قبل أن يسمح.
- **إنشاء الحساب وكلمة المرور** → دالّة الحافة وحدها، لأن نظام المصادقة لا
  يُكتب إلا بصلاحية خدمة. والمفتاح يبقى على الخادم؛ المتصفّح يرسل رمز جلسة
  صاحب الطلب لا أكثر.

ودالّة الحافة تردّ الآن برفضٍ صريح إن طُلب منها تغيير الدور أو التفعيل،
ويحرس ذلك اختبار.

---

## ٦. ما تحقّقتُ منه في المتصفّح

بجسرٍ مُصطنَع (بيانات مُصطنَعة، بلا جلسة وبلا بيانات إنتاج):

| الفحص | النتيجة |
|---|---|
| الوكلاء والباقات تُرسم وتُحسب مؤشّراتها | ✅ |
| «تحرير» يملأ النموذج بقيم الصفّ | ✅ |
| الباقة الواردة وغير المسجَّلة تُعرض بعدد أحداثها | ✅ |
| اعتمادُ استيرادٍ بلا معاينة | **مرفوض قبل الشبكة** ✅ |
| حفظُ صلاحيةٍ بلا سبب | **مرفوض قبل الشبكة** ✅ |
| ترحيلُ دفعةٍ بلا مرجع | **مرفوض قبل الشبكة** ✅ |
| الاعتماد وعليه حاجب | الزرّ معطَّل والسبب معروض ✅ |
| دورة معتمدة | لا حساب ولا اعتماد · الإقفال وإعادة الفتح ظاهران ✅ |
| دفعة مُرحَّلة | لا لوحة ترحيل أصلاً ✅ |
| `[object Object]` أو `؟؟؟` | لا شيء ✅ |

**ما لم يُتحقَّق منه:** الشاشات بحسابٍ حقيقي وبيانات إنتاج. الدخول يحتاج
كلمة مرور، ولا أُدخلها.
