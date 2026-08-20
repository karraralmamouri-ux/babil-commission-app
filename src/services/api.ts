/**
 * الوصول إلى الخادم.
 *
 * محوّل مؤقّت مقصود: يمرّ عبر `window.sbRequest` القادم من index.html بدل
 * إعادة بناء الجلسة والتجديد. سبب ذلك أن تجديد الرمز ومعالجة انتهاء الجلسة
 * مُختبَران بالفعل (session-persistence.test.js)، وإعادة كتابتهما في هذه
 * المرحلة تخاطر بالمصادقة مقابل لا شيء.
 *
 * شرط الإزالة: عندما تنتقل الجلسة إلى src/app/session.ts ويُغطّى الانتقال
 * باختبارات مكافئة. مسجَّل في docs/engineering/index-html-exit-plan.md.
 */

declare global {
  interface Window {
    sbRequest?: (path: string, init?: RequestInit) => Promise<unknown>;
    opsCan?: (capability: string) => boolean;
    opsCapabilities?: Map<string, boolean>;
    /** يبني مساحة الشهر السابقة عند فتح #/legacy، لا عند الدخول. */
    ensureLegacyWorkspace?: () => Promise<void>;
  }
}

export class ApiError extends Error {
  readonly status: number | undefined;
  constructor(message: string, status?: number) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
  }
}

function bridge(): (path: string, init?: RequestInit) => Promise<unknown> {
  const fn = window.sbRequest;
  if (typeof fn !== 'function') {
    throw new ApiError('طبقة الاتصال غير جاهزة بعد');
  }
  return fn;
}

/** استدعاء دالة خادمية. الخادم هو المرجع المالي — لا حساب هنا. */
export async function rpc<T>(name: string, args: Record<string, unknown> = {}): Promise<T> {
  try {
    const result = await bridge()(`/rest/v1/rpc/${name}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(args),
    });
    return result as T;
  } catch (error) {
    throw asApiError(error);
  }
}

/**
 * استدعاء دالة حافة.
 *
 * لا تُستعمل إلا لما يحتاج صلاحية خدمةٍ فعلاً — إنشاء حسابٍ في نظام المصادقة
 * وتعيين كلمة مرور. المفتاح يبقى في الدالّة على الخادم، والمتصفّح يرسل رمز
 * جلسة المستخدم لا أكثر. وما عدا ذلك يمرّ بدوالّ القاعدة المحروسة بالقدرة.
 */
export async function edge<T>(name: string, body: Record<string, unknown>): Promise<T> {
  try {
    const result = await bridge()(`/functions/v1/${encodeURIComponent(name)}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    // الدالّة تردّ أحياناً بـ200 وفي جسمها خطأ، فلا يكفي أن الجسر لم يرمِ.
    const asRecord = (result || {}) as Record<string, unknown>;
    if (typeof asRecord['error'] === 'string') {
      throw new ApiError(asRecord['error']);
    }
    return result as T;
  } catch (error) {
    throw asApiError(error);
  }
}

/** قراءة جدول عبر PostREST — للقوائم الصغيرة المحدودة أصلاً. */
export async function select<T>(path: string): Promise<T> {
  try {
    return (await bridge()(`/rest/v1/${path}`)) as T;
  } catch (error) {
    throw asApiError(error);
  }
}

/**
 * يستخرج رسالةً مقروءة من أي شكل خطأ.
 *
 * الطبقة القديمة ترفض بكائن عادي لا بـError، وPostgREST يُعيد
 * `{ message, code, details, hint }`. وString() على كائن تُنتج
 * «[object Object]» — وهي أسوأ من رسالة تقنية: لا تقول شيئاً إطلاقاً،
 * وقد ظهرت فعلاً على الشاشة المنشورة.
 */
function messageOf(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (typeof error === 'string') return error;
  if (error && typeof error === 'object') {
    const o = error as Record<string, unknown>;
    for (const k of ['message', 'error_description', 'error', 'msg', 'details', 'hint']) {
      const v = o[k];
      if (typeof v === 'string' && v.trim()) return v;
    }
    const code = typeof o['code'] === 'string' ? o['code'] : null;
    const status = typeof o['status'] === 'number' ? String(o['status']) : null;
    if (code || status) return `الخادم ردّ برمز ${code || status}`;
  }
  return 'خطأ غير متوقّع';
}

function asApiError(error: unknown): ApiError {
  if (error instanceof ApiError) return error;
  const message = messageOf(error);
  // لا يُعرض أثر المكدّس ولا تفاصيل داخلية للمستخدم.
  if (/permission|capability|denied|42501/i.test(message)) {
    return new ApiError('لا صلاحية لهذا الإجراء', 403);
  }
  if (/fetch|network|Failed to fetch|JWT|token|401|session/i.test(message)) {
    return new ApiError('انتهت الجلسة أو تعذّر الاتصال — سجّل الدخول من جديد', 0);
  }
  return new ApiError(message.slice(0, 200));
}

/** هل يملك المستخدم القدرة؟ للعرض فقط — الخادم يفحص مرة أخرى دائماً. */
export function can(capability: string): boolean {
  const fn = window.opsCan;
  if (typeof fn === 'function') {
    try { return Boolean(fn(capability)); } catch { return false; }
  }
  return false;
}

/* -------------------------------------------------------------------------
   الصفحات
   ------------------------------------------------------------------------- */

export interface Page<T> {
  rows: T[];
  total: number;
  limit: number;
  offset: number;
}

/**
 * العقد القديم: الإجمالي محمولٌ في كل صفّ.
 *
 * يبقى للنداءات التي لم تنتقل بعد، وعيبه معروف ومُوثَّق: حين تقع الإزاحة خارج
 * المدى لا تعود صفوف، فيختفي الإجمالي معها. لذلك انتقلت القوائم الكبيرة إلى
 * الصدفة أدناه.
 */
export function toPage<T extends { total_count?: number | string }>(
  rows: T[] | null,
  limit: number,
  offset: number,
): Page<T> {
  const list = rows || [];
  const first = list[0];
  const total = first && first.total_count !== undefined ? Number(first.total_count) : list.length;
  return { rows: list, total: Number.isFinite(total) ? total : list.length, limit, offset };
}

/**
 * صدفة الصفحة — العقد الصحيح.
 *
 * الإجمالي منفصل عن الصفوف، فلا تُخفيه صفحةٌ فارغة. صفحةٌ خارج المدى تُعيد
 * صفوفاً صفراً وإجمالياً صادقاً و`outOfRange` صريحة — بدل أن تُقرأ 22,727
 * صفراً لأن الإزاحة تجاوزت النهاية.
 */
export interface Envelope<T> {
  rows: T[];
  total: number;
  limit: number;
  offset: number;
  returned: number;
  outOfRange: boolean;
}

export function envelope<T>(raw: unknown): Envelope<T> {
  const o = (raw || {}) as Record<string, unknown>;
  const rows = Array.isArray(o['rows']) ? (o['rows'] as T[]) : [];
  const n = (v: unknown, d: number) => (Number.isFinite(Number(v)) ? Number(v) : d);
  return {
    rows,
    total: n(o['total'], rows.length),
    limit: n(o['limit'], rows.length),
    offset: n(o['offset'], 0),
    returned: n(o['returned'], rows.length),
    outOfRange: Boolean(o['out_of_range']),
  };
}

/** يُستدعى مع إشارة الإلغاء، فالطلب يُهمَل حين يغادر المستخدم الشاشة. */
export async function pageRpc<T>(
  name: string,
  args: Record<string, unknown>,
  signal?: AbortSignal,
): Promise<Envelope<T>> {
  if (signal?.aborted) throw new DOMException('aborted', 'AbortError');
  const raw = await rpc<unknown>(name, args);
  if (signal?.aborted) throw new DOMException('aborted', 'AbortError');
  return envelope<T>(raw);
}
