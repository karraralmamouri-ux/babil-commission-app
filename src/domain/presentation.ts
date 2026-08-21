/** تنسيق العرض فقط؛ القيم الخام تبقى في العقود والتصدير والتفاصيل التقنية. */
const PACKAGE_LABELS: Record<string, string> = {
  'P-35000': 'P35', 'P-45000': 'P45', 'P-65000': 'P65',
};

const STATUS_LABELS: Record<string, string> = {
  OPEN: 'مفتوح', RESOLVED: 'مُعالَج', WAIVED: 'مُتجاوَز',
  UNDER_REVIEW: 'قيد المراجعة', READY_TO_FINALIZE: 'جاهزة للاعتماد',
  FINALIZED: 'معتمدة', PARTIALLY_PAID: 'مدفوعة جزئياً', PAID: 'مدفوعة',
  UNKNOWN: 'غير مثبت', PARTIAL: 'جزئي', COMPLETE: 'مكتمل',
  NEEDS_REVIEW: 'تحتاج مراجعة', NEW: 'جديد', EXISTING: 'قائم',
};

const REASON_LABELS: Record<string, string> = {
  UNKNOWN_FDT: 'كابينة تحتاج تصنيف', UNKNOWN_AGENT: 'وكيل غير معروف',
  UNKNOWN_PACKAGE: 'باقة تحتاج تصنيف', SOURCE_INCOMPLETE: 'مصدر غير مكتمل',
  IDENTITY_CONFLICT: 'هوية تحتاج حسم', UNRESOLVED_OWNERSHIP: 'ملكية تحتاج حسم',
  UNKNOWN_SOURCE_COMPLETENESS: 'اكتمال المصدر غير مثبت',
  PARTIAL_SOURCE: 'المصدر جزئي', REGISTRY_PREEXISTING: 'مسجّل سابقاً',
};

export const packageLabel = (value: unknown): string => {
  const raw = String(value ?? '');
  return PACKAGE_LABELS[raw] || raw || '—';
};
export const statusLabelAr = (value: unknown): string => {
  const raw = String(value ?? '');
  return STATUS_LABELS[raw] || raw || '—';
};
export const reasonLabelAr = (value: unknown): string => {
  const raw = String(value ?? '');
  return REASON_LABELS[raw] || raw || '—';
};
