/**
 * المال — نوع واحد وصيغة واحدة.
 *
 * الدينار عدد صحيح بلا كسور. النوع الموسوم يمنع تمرير رقم عادي حيث يُنتظر
 * مبلغ، وهو الخطأ الذي أنتج «الصفر الصامت» سابقاً: قيمة غائبة صارت 0 ومرّت
 * كأنها حقيقة.
 */

export type IQD = number & { readonly __brand: 'IQD' };

/** يُبنى مبلغٌ من رقم موثوق (قادم من الخادم). */
export function iqd(value: number): IQD {
  return Math.round(value) as IQD;
}

/**
 * القيمة القادمة من الشبكة قد تكون غائبة. الغياب ليس صفراً، فيُعاد null
 * ليقرر العرض: الشرطة تعني «لم يُحمَّل»، والصفر يعني «قال الخادم صفراً».
 */
export function maybeIqd(value: unknown): IQD | null {
  if (value === null || value === undefined || value === '') return null;
  const n = Number(value);
  return Number.isFinite(n) ? (Math.round(n) as IQD) : null;
}

const UNIT = 'د.ع';

/** الرقم وحده، بفواصل الآلاف. */
export function amount(value: IQD | number | null | undefined): string {
  if (value === null || value === undefined) return '—';
  return Math.round(Number(value)).toLocaleString('en-US');
}

/** الرقم ووحدته. صيغة واحدة في كل الشاشات. */
export function money(value: IQD | number | null | undefined): string {
  if (value === null || value === undefined) return '—';
  return `${amount(value)} ${UNIT}`;
}

/** العدد الصحيح غير المالي — أحداث، مشتركون، صفوف. */
export function count(value: number | null | undefined): string {
  if (value === null || value === undefined) return '—';
  return Math.round(value).toLocaleString('en-US');
}

export const IQD_UNIT = UNIT;
