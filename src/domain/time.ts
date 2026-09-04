/**
 * الوقت المعروض — بتوقيت بغداد.
 *
 * كانت الشاشات تقصّ الطابع الزمني نصّاً: `.replace('T',' ').slice(0,16)`.
 * والطابع يصل بتوقيت UTC، فحدثٌ وقع الساعة 00:30 بتوقيت بغداد يُعرض
 * 21:30 من اليوم السابق. الرقم صحيح والتاريخ المعروض خطأ بيوم — وفي نظامٍ
 * نافذتُه الماليّة شهرٌ بتوقيت بغداد، ذلك يعني حدثاً يبدو خارج شهره.
 *
 * والتخزين لا يُمسّ: `timestamptz` يبقى كما هو، والتحويل عند العرض وحده.
 */

const TZ = 'Asia/Baghdad';

function parse(value: unknown): Date | null {
  if (value === null || value === undefined || value === '') return null;
  const d = value instanceof Date ? value : new Date(String(value));
  return Number.isNaN(d.getTime()) ? null : d;
}

/**
 * التاريخ والوقت: 2026-07-31 23:16
 *
 * ترتيب المقاطع ثابت (سنة-شهر-يوم) لا يتبع لغة المتصفّح: العمود المالي
 * يُمسح بصرياً، والترتيب المتغيّر يكسر المسح.
 */
export function dateTime(value: unknown): string {
  const d = parse(value);
  if (!d) return '—';
  const p = new Intl.DateTimeFormat('en-CA', {
    timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hour12: false,
  }).formatToParts(d);
  const get = (t: string) => p.find((x) => x.type === t)?.value ?? '';
  return `${get('year')}-${get('month')}-${get('day')} ${get('hour')}:${get('minute')}`;
}

/** التاريخ وحده: 2026-07-31 */
export function dateOnly(value: unknown): string {
  const d = parse(value);
  if (!d) return '—';
  const p = new Intl.DateTimeFormat('en-CA', {
    timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit',
  }).formatToParts(d);
  const get = (t: string) => p.find((x) => x.type === t)?.value ?? '';
  return `${get('year')}-${get('month')}-${get('day')}`;
}

/**
 * الشهر الذي يقع فيه الطابع بتوقيت العمل: 2026-07
 *
 * نظيرُ `to_char(ts at time zone business_timezone(), 'YYYY-MM')` على الخادم،
 * وبالمنطقة نفسها المعرَّفة أعلاه — لا ثابتَ ثانٍ. ويُستعمل للمعاينة وحدها:
 * الخادم يعيد الاشتقاق ويحرسه بزنادٍ على الجدول، وهو وحده الحُجّة.
 */
export function businessMonth(value: unknown): string | null {
  const d = parse(value);
  if (!d) return null;
  const p = new Intl.DateTimeFormat('en-CA', {
    timeZone: TZ, year: 'numeric', month: '2-digit',
  }).formatToParts(d);
  const get = (t: string) => p.find((x) => x.type === t)?.value ?? '';
  const y = get('year'); const m = get('month');
  return y && m ? `${y}-${m}` : null;
}
/** يُستعمل حيث يلزم التصريح بالمنطقة، كالتدقيق. */
export const timezoneLabel = 'بتوقيت بغداد';
