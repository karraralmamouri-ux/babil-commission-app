/**
 * تصنيف الجِدّة كما ثبّته الخادم.
 *
 * NEW ادعاءٌ ماليّ: يعني أن المشترك لم يوجد قط، ويُبنى عليه أجر تنصيب. لا
 * يُمنح إلا من مصدرٍ مكتمل، وكل دفعات الاستيراد حتى اليوم اكتمالها UNKNOWN.
 *
 * فصفرُ NEW هنا ليس عطلاً بل ما يقوله المصدر. ولذلك تُعرض الأسباب لا الأعداد
 * وحدها: «22,424 عدّاد عمرهم يتجاوز ما رُصد» تقول إن قِدَمهم مُثبَت إثباتاً
 * موجباً، لا أنه افتراضٌ عند الشك.
 */

import { esc, chip } from '../../components/ui';
import { count } from '../../domain/money';

type Row = Record<string, unknown>;

export const REASON_AR: Record<string, string> = {
  REGISTRY_PREEXISTING: 'موجود سابقاً في سجلّ التنصيب',
  LIFETIME_COUNT_EXCEEDS_OBSERVED: 'عدّاد العمر يتجاوز ما رُصد',
  COMPLETE_LIFETIME_HISTORY_OBSERVED: 'تاريخ كامل مرصود من مصدر مكتمل',
  PARTIAL_SOURCE: 'المصدر ناقص',
  UNKNOWN_SOURCE_COMPLETENESS: 'اكتمال المصدر غير مُثبت',
  IDENTITY_CONFLICT: 'تعارض هوية',
  CANCELED_ONLY_HISTORY: 'كل ما رُصد ملغى',
  NO_QUALIFYING_PAID_EVENT: 'لا حدث مدفوع مؤهل',
};

const TONE: Record<string, 'success' | 'info' | 'warning'> = {
  NEW: 'success', EXISTING: 'info', NEEDS_REVIEW: 'warning',
};

const CLASS_AR: Record<string, string> = {
  NEW: 'جديد', EXISTING: 'قديم', NEEDS_REVIEW: 'تحتاج مراجعة',
};

export function classificationPanel(doc: Row | null): string {
  const byClass = (doc?.['by_class'] || {}) as Record<string, number>;
  const byReason = (doc?.['by_reason'] || {}) as Record<string, number>;
  const done = Number(doc?.['classified'] || 0);
  const total = Number(doc?.['total_subscribers'] || 0);

  if (!Object.keys(byClass).length) {
    return `<p class="muted">لم يُصنَّف أحد بعد.
      يُشغَّل التصنيف على الخادم ويُحفَظ بشواهده.</p>`;
  }

  const classes = Object.entries(byClass)
    .map(([k, v]) => `<div class="minirow">
      <span>${chip(CLASS_AR[k] || k, TONE[k] || 'neutral')}</span>
      <b>${count(Number(v))}</b></div>`).join('');

  const reasons = Object.entries(byReason)
    .sort((a, b) => Number(b[1]) - Number(a[1]))
    .map(([k, v]) => `<div class="minirow">
      <span class="muted">${esc(REASON_AR[k] || k)}</span>
      <b>${count(Number(v))}</b></div>`).join('');

  return classes
    + (reasons ? `<div style="margin-top:10px">${reasons}</div>` : '')
    + `<div class="muted" style="font-size:10px;margin-top:8px">
        صُنِّف ${count(done)} من ${count(total)}.
        الجِدّة لا تُمنح من مصدرٍ غير مُثبت الاكتمال.</div>`;
}
