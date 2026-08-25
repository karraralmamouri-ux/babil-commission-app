/**
 * شرط ظهور زرّ «رفع التعليق» — نفس ما يتحقّق منه `release_hold_v2` خادمياً:
 * قدرة `installation.release_hold`، وتعليقٌ حالته `ACTIVE` فعلاً (لا يهمّ
 * انتهاؤه التلقائي أم لا — الرفع سجلٌّ صريح، والخادم مصدر الحقيقة الوحيد).
 */
export function canReleaseHold(status: string, hasCapability: boolean): boolean {
  return hasCapability && status === 'ACTIVE';
}
