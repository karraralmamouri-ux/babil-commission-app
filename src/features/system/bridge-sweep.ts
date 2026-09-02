/**
 * مسح الجسر حتى تُغطّى الدفعة كلها.
 *
 * الخادم يمسح نافذةً واحدةً في النداء الواحد، وهذا مقصود: خمسة آلاف مرشّحٍ
 * في نداءٍ واحدٍ لا يكتملون تحت مهلة الثماني ثوانٍ للنداء المُصادَق عليه.
 * فالتغطية الكاملة مسؤولية المستدعي، والمؤشّر (last_username_key) هو ما
 * يجعلها حتميّةً لا احتمالية: مَن منعته البوابة يبقى مرشّحاً إلى الأبد،
 * فمسحةٌ بلا مؤشّرٍ تعيد الممنوعين أنفسهم كل مرّة ولا تبلغ مَن بعدهم أبداً.
 *
 * ولا قاعدة عملٍ هنا: البوابة على الخادم هي التي تقرّر مَن يُسجَّل، وهذا
 * الملف لا يفعل شيئاً سوى أن يُتِمّ المرور على المرشّحين.
 *
 * مكانٌ واحدٌ لهذا المرور: تستعمله شاشة الاستيراد بعد الرفع، وصفحة الدفعة
 * عند إعادة التشغيل. نسختان منه تنحرفان، وأوّل انحرافٍ بينهما مرشّحٌ يُغطّى
 * في إحداهما ويُنسى في الأخرى.
 */

import { rpc } from '../../services/api';
import { count } from '../../domain/money';

type Row = Record<string, unknown>;
const num = (r: Row, k: string) => Number(r[k] || 0);
const str = (r: Row, k: string) => String(r[k] ?? '');

export type BridgeTotals = {
  sweeps: number;
  considered: number;
  enrolled: number;
  blocked: number;
  remaining: number;
  reasons: Record<string, number>;
  /** غُطّيت الدفعة كلها فعلاً؟ خطأٌ يعني أن مرشّحين بقوا بلا نظر. */
  complete: boolean;
};

/** نافذة النداء الواحد. الخادم يقبل حتى 5000، لكن القياس على قاعدةٍ محلية
 *  أعطى 2.96 ثانية عندها — هامشٌ لا يُبنى عليه على جهازٍ أبطأ. 1000 قُيست
 *  عند ~0.6 ثانية. */
const SWEEP_LIMIT = 1000;

/** حرسٌ من دورةٍ لا تنتهي لو تغيّر عقد الخادم يوماً. مليون مرشّحٍ سقفٌ لا
 *  يبلغه ملفُ تفعيلٍ شهريّ بحال. */
const MAX_SWEEPS = 1000;

export async function bridgeSweepAll(
  batchId: string | null,
  onProgress?: (totals: BridgeTotals) => void,
): Promise<BridgeTotals> {
  const totals: BridgeTotals = {
    sweeps: 0, considered: 0, enrolled: 0, blocked: 0,
    remaining: 0, reasons: {}, complete: false,
  };
  let after: string | null = null;

  while (totals.sweeps < MAX_SWEEPS) {
    const r = await rpc<Row>('bridge_saas_activations_to_enrollments', {
      p_batch_id: batchId,
      p_limit: SWEEP_LIMIT,
      p_request_id: crypto.randomUUID(),
      p_after_username: after,
    });
    const res = (r?.['result'] || {}) as Row;

    totals.sweeps += 1;
    totals.considered += num(res, 'considered');
    totals.enrolled += num(res, 'enrolled');
    totals.blocked += num(res, 'blocked');
    totals.remaining = num(res, 'remaining');
    for (const [reason, n] of Object.entries((res['reasons'] || {}) as Row)) {
      totals.reasons[reason] = (totals.reasons[reason] || 0) + Number(n || 0);
    }
    onProgress?.(totals);

    const last = str(res, 'last_username_key');
    // المسحة التي لم تبلغ حدّها نظرت في كل ما بقي بعد مؤشّرها. ومسحةٌ لم
    // تُحرّك المؤشّر لا تُحرّكه في التي بعدها أيضاً، فالوقوف أصدق من الدوران.
    if (res['exhausted'] === true || !last || last === after) {
      totals.complete = true;
      break;
    }
    after = last;
  }

  return totals;
}

/** «مؤهَّل ١٢ · بانتظار المراجعة ٣٤٠» — الأسباب مرتَّبةً بالأكثر شيوعاً. */
export function bridgeReasons(totals: BridgeTotals): string {
  return Object.entries(totals.reasons)
    .sort((a, b) => b[1] - a[1])
    .map(([reason, n]) => `${reason}: ${count(n)}`)
    .join(' · ');
}
