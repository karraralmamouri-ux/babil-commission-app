# Navigation and Screen Map — vNext

**Not implemented.** Target information architecture, for evaluation.

---

## 1. Current navigation

**FACT.** One sidebar, one flat list (`index.html` lines 203–232 and the nav block):

```
العرض والمتابعة   ملخص العمولات · تفاصيل الوكلاء والكابينات · سجل العمليات · أجور التنصيب
التقارير          تصدير تقرير العمولات · تقرير Excel متكامل · مقارنة الأشهر
تجهيز الشهر       فتح وضع تجهيز الشهر · استيراد الملف الخام · حفظ · اعتماد · الأشهر ·
                  الشهر التالي · أسعار العمولات والتير · ربط الوكلاء والكابينات
إدارة النظام      تحديث البيانات المركزية · إدارة الأرشيف · المستخدمون والصلاحيات · نسخة احتياطية
```

**Observation.** Installation Fees is a single leaf next to commission views, and the whole
installation workflow — import, historical import, invoice audit, payment review, exports —
is compressed into one screen's button row. That was proportionate when the domain was a
dashboard. It is not proportionate now that the domain owns 5,693 subscribers, 17,117 payment
events and a payment workflow.

---

## 2. Target navigation

```
الرئيسية
  └── نظرة عامة تنفيذية

عمولات الوكلاء
  ├── نظرة عامة
  ├── الوكلاء والكابينات
  ├── الاستحقاقات
  ├── الصرف
  └── الأرشيف

أجور التنصيب
  ├── مركز التحكم
  ├── المشتركون
  ├── دورة الشهر
  ├── المطابقة والتدقيق
  ├── الفواتير
  ├── جاهز للصرف
  ├── الموقوفون
  ├── الدفعات
  ├── الاستيراد / المزامنة
  └── الأرشيف

بيانات رئيسية
  ├── الوكلاء
  ├── FDTs
  ├── Packages / Services
  └── الخطط المالية

التقارير

النظام
  ├── المستخدمون والصلاحيات
  ├── سجل العمليات
  └── الإعدادات
```

The two financial domains become siblings rather than one hosting the other. Master data
leaves the workflow screens — an agent alias is reference data, not a step in preparing a
month.

---

## 3. Screens that carry the new model

### 3.1 مركز التحكم — Installation control centre

Not a KPI wall. Each number is a queue with a count and a link.

```
تحتاج مراجعة  19      ◄ 14 اختلال محاسبي · 5 متبقٍ فارغ
فاتورة مفقودة  —
غير مطابق      —
موقوف          —
جاهز للصرف     2,196
مصروف          —
```

**Rule.** Every number drills down to the actual rows. A count with no drill-down is
decoration and should not ship.

### 3.2 المشتركون — registry

Filterable list over the merged view. Columns: subscriber · agent · FDT · stage · eligibility ·
warnings · historical payments · as-of.

**FACT.** This screen exists in embryo today: the merged dashboard rows and working filters
landed in `f31705b`/`94b1873` and correctly show 5,693 rows with per-reseller filtering.

### 3.3 Subscriber detail — case management

Tabs: نظرة عامة · التفعيلات · الفواتير · الدفعات · الإيقاف · التاريخ · التدقيق

Timeline:

```
إنشاء المستخدم
Loan-3                       ← لا ينشئ استحقاقاً
تفعيل مدفوع (P-35000)        ← الحدث المؤهِّل
تأكيد التنصيب
تحديد الوكيل
P1 مستحق → P1 مصروف
تصحيح الوكيل                 ← قبل/بعد/سبب/منفّذ
إيقاف → رفع الإيقاف
P2 مصروف
```

The timeline is the audit trail made legible. It should be generated from the ledger and
audit tables, never maintained separately.

### 3.4 دورة الشهر

One cycle, its state, and what is blocking it from advancing.

### 3.5 الدفعات — batches

`Draft → Reviewed → Posted → Paid`, with server-side revalidation shown explicitly at
posting: which lines passed, which were rejected and why.

### 3.6 Agent financial profile

Both domains on one page, calculations kept apart:

| Commissions | Installation Fees |
|---|---|
| current cycle · total · paid · remaining · tier · unique-user snapshot · FDT breakdown | subscribers · P1–P4 · ready · blocked · paid · remaining · FDT breakdown · exceptions |

---

## 4. Executive overview

Answers, in order: Where is the money? · How much is owed? · How much was paid? · How much
remains? · Which agent? · What is blocked, why, and who must act?

Every figure links to its rows.

---

## 5. Migration of navigation

Presentation last (Phase 9). Adding screens over a model that cannot answer their questions
produces convincing screens that are wrong.
