/**
 * نتيجة دورة العمولة — عقد قراءة واحد.
 *
 * كانت الشاشة تنادي `report_commission_cycle_detail` وتقرأ منه `totals`.
 * وتلك الدالّة تُعيد **جدولاً**: صفٌّ لكل نطاق. فما وصل إلى الواجهة مصفوفة،
 * و`array['totals']` قيمته `undefined` دائماً — ولهذا كانت كل مؤشّرات
 * الدورة شرطات. لم يكن الخادم معطلاً؛ العقد الذي تقرأه الواجهة لم يوجد قطّ.
 *
 * وكانت تُنادى ثلاث مرّات في ثلاث شاشات، كلٌّ منها `.catch(() => null)` —
 * فلو عطل الخادم فعلاً لظهرت الشرطة نفسها، ولا يفرّق أحد بين «لا بيانات»
 * و«تعذّر الاتصال».
 *
 * فصار العقد واحداً: `commission_cycle_result` تُعيد كائناً واحداً يُقرأ
 * مرّةً وتُعاد قسمته، والخطأ يُرفع لا يُبتلع.
 */

import { rpc } from '../services/api';

export interface CycleTotals {
  gross: number;
  approved: number;
  ready: number;
  paid: number;
  remaining: number;
  scopes: number;
}

export interface CycleVolumes {
  qualifying_events: number;
  tier_basis: number;
}

export interface CycleAgent {
  agent_id: string;
  agent_name: string;
  agent_code: string;
  events: number;
  subscribers: number;
  gross: number;
}

export interface UnresolvedOwnership {
  events: number;
  subscribers: number;
  amount: number;
  parents: string[];
}

export interface CycleZone {
  zone: string;
  scopes: number;
  tier_basis: number;
  events: number;
  gross: number;
}

export interface CycleBlocker {
  reason_code: string;
  events: number;
  subscribers: number;
}

export interface CycleResult {
  found: boolean;
  cycle: {
    id: string; name: string; status: string;
    period_start: string; period_end: string;
    window_start: string; window_end: string;
    finalized_at: string | null; closed_at: string | null;
  };
  totals: CycleTotals;
  volumes: CycleVolumes;
  zones: CycleZone[];
  agents: CycleAgent[];
  unresolved_ownership: UnresolvedOwnership;
  blockers: CycleBlocker[];
}

const n = (v: unknown) => Number(v || 0);

/**
 * يقرأ النتيجة ويُطبِّعها.
 *
 * لا `catch` هنا: عطل الخادم يجب أن يصل إلى الشاشة لتقول «تعذّر التحميل»
 * لا «—». والفرق بينهما هو الفرق بين رقمٍ صفرٍ حقيقي ورقمٍ لم يصل.
 */
export async function readCycleResult(cycleId?: string): Promise<CycleResult | null> {
  const raw = await rpc<Record<string, unknown>>(
    'commission_cycle_product_result', cycleId ? { p_cycle_id: cycleId } : {});

  if (!raw || raw['found'] !== true) return null;

  const totals = (raw['totals'] || {}) as Record<string, unknown>;
  const volumes = (raw['volumes'] || {}) as Record<string, unknown>;
  const unresolved = (raw['unresolved_ownership'] || {}) as Record<string, unknown>;

  return {
    found: true,
    cycle: raw['cycle'] as CycleResult['cycle'],
    totals: {
      gross: n(totals['gross']),
      approved: n(totals['approved']),
      ready: n(totals['ready']),
      paid: n(totals['paid']),
      remaining: n(totals['remaining']),
      scopes: n(totals['scopes']),
    },
    volumes: {
      qualifying_events: n(volumes['qualifying_events']),
      tier_basis: n(volumes['tier_basis']),
    },
    zones: ((raw['zones'] || []) as Record<string, unknown>[]).map((z) => ({
      zone: String(z['zone'] ?? ''),
      scopes: n(z['scopes']),
      tier_basis: n(z['tier_basis']),
      events: n(z['events']),
      gross: n(z['gross']),
    })),
    agents: ((raw['agents'] || []) as Record<string, unknown>[]).map((a) => ({
      agent_id: String(a['agent_id'] ?? ''),
      agent_name: String(a['agent_name'] ?? ''),
      agent_code: String(a['agent_code'] ?? ''),
      events: n(a['events']),
      subscribers: n(a['subscribers']),
      gross: n(a['gross']),
    })),
    unresolved_ownership: {
      events: n(unresolved['events']),
      subscribers: n(unresolved['subscribers']),
      amount: n(unresolved['amount']),
      parents: (unresolved['parents'] || []) as string[],
    },
    blockers: ((raw['blockers'] || []) as Record<string, unknown>[]).map((b) => ({
      reason_code: String(b['reason_code'] ?? ''),
      events: n(b['events']),
      subscribers: n(b['subscribers']),
    })),
  };
}

/** المنسوب لوكلاء معروفين — ما عدا ما لم تُحسم عائديته. */
export function knownAgentTotal(r: CycleResult): number {
  return r.agents.reduce((sum, a) => sum + a.gross, 0);
}

/**
 * تتصالح الأرقام أم لا.
 *
 * المعروف + المعلّق يجب أن يساوي المحسوب. لو اختلّت فذلك عيبٌ في القراءة
 * لا في العرض، ويجب أن يُقال لا أن يُخفى بفارقٍ صامت.
 */
export function reconciles(r: CycleResult): boolean {
  return knownAgentTotal(r) + r.unresolved_ownership.amount === r.totals.gross;
}

/* ---- حالة الدورة بالعربية ------------------------------------------------- */

const STATUS_AR: Record<string, string> = {
  DRAFT: 'مسودّة',
  DATA_IMPORTED: 'بيانات مُستوردة',
  UNDER_REVIEW: 'قيد المراجعة',
  READY_TO_FINALIZE: 'جاهزة للاعتماد',
  FINALIZED: 'معتمدة',
  PARTIALLY_PAID: 'مدفوعة جزئياً',
  PAID: 'مدفوعة',
  CLOSED: 'مقفلة',
};

export const cycleStatusAr = (s: string): string => STATUS_AR[s] || s;

/** ما قبل الاعتماد رقمٌ متوقَّع، وما بعده رقمٌ نهائي. */
const FINAL = new Set(['FINALIZED', 'PARTIALLY_PAID', 'PAID', 'CLOSED']);
export const isProjectedStatus = (s: string): boolean => !FINAL.has(s);
