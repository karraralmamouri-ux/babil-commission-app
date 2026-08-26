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

import type { View } from '../../app/router';
import { esc, chip, loading } from '../../components/ui';
import { count } from '../../domain/money';
import { rpc, can, ApiError } from '../../services/api';

type Row = Record<string, unknown>;

function insight(tone: 'good' | 'danger', title: string, detail = ''): string {
  return `<div class="insight ${tone}" style="margin-top:10px"><span class="insight-dot"></span><span>
    <b>${esc(title)}</b>${detail ? `<small>${esc(detail)}</small>` : ''}</span></div>`;
}

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

/**
 * تشغيل classify_newness() على من لم يُصنَّف بعد — دفعة محدودة، بلا أثر مالي.
 *
 * التصنيف مُدخَلٌ لقرارٍ بشري لاحق، لا استحقاقاً: الكتابة تصل فقط
 * subscriber_classifications، ولا تُنشئ مشتركاً ولا استحقاقاً ولا دفعة.
 * إعادة التشغيل آمنة — upsert بمفتاح username_key.
 */
export function classificationRunPanel(): string {
  if (!can('saas.review')) return '';
  return `<div class="box" style="margin-top:12px" id="classRunBox">
    <h3>تشغيل التصنيف</h3>
    <div class="insight warn"><span class="insight-dot"></span><span>
      <b>التصنيف مُدخَلٌ للمراجعة، لا قرارٌ مالي</b>
      <small>يحسب classify_newness() لمن لم يُصنَّف بعد ويحفظ الناتج بشواهده.
        لا يُنشئ مشتركاً ولا استحقاقاً ولا دفعة. إعادة التشغيل آمنة.</small></span></div>
    <button class="btn gold" id="classRunBtn" style="margin-top:10px">صنّف الدفعة التالية</button>
    <div id="classRunResult"></div>
  </div>`;
}

export function wireClassificationRun(view: View): void {
  const btn = view.el.querySelector<HTMLButtonElement>('#classRunBtn');
  const out = view.el.querySelector<HTMLElement>('#classRunResult');
  if (!btn || !out) return;

  btn.addEventListener('click', async () => {
    if (!window.confirm('تشغيل التصنيف الآن؟ لن يُنشأ أي مشترك أو استحقاق أو دفعة.')) return;
    btn.disabled = true;
    out.innerHTML = loading('جارٍ التصنيف…');
    try {
      const res = await rpc<Row>('refresh_subscriber_classifications', {});
      if (!view.live) return;
      const remaining = Number(res?.['remaining'] || 0);
      out.innerHTML = insight('good', 'انتهت هذه الدفعة',
        `صُنِّف ${count(Number(res?.['evaluated'] || 0))}` +
        ` · جديد ${count(Number(res?.['new'] || 0))}` +
        ` · قديم ${count(Number(res?.['existing'] || 0))}` +
        ` · يحتاج مراجعة ${count(Number(res?.['needs_review'] || 0))}` +
        (remaining ? ` · متبقٍّ ${count(remaining)}` : ' · لا شيء متبقٍّ'));
      window.setTimeout(() => { if (view.live) window.location.reload(); }, 1800);
    } catch (error) {
      if (!view.live) return;
      out.innerHTML = insight('danger', 'تعذّر التشغيل',
        error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
    } finally {
      btn.disabled = false;
    }
  });
}
