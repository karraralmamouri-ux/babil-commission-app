/**
 * التوجيه.
 *
 * بالـhash عمداً. GitHub Pages لا يملك إعادة كتابة للمسارات، فالتوجيه
 * التاريخي يحتاج نسخة من الصفحة في 404.html — حيلة تعمل حتى تُربك من يشخّص
 * عطلاً. والـhash يجعل الرابط العميق يعمل بلا إعداد على الخادم إطلاقاً.
 *
 * تحذير قائم: الـhash مستعمل أصلاً في استرجاع كلمة المرور من Supabase
 * (`#access_token=...&type=recovery`). لذلك يُفحص الاسترجاع أولاً في main.ts
 * قبل أن يرى الموجِّه الـhash، ويتجاهل الموجِّه أي hash لا يبدأ بـ`#/`.
 */

export interface RouteMatch {
  path: string;
  params: Record<string, string>;
  query: URLSearchParams;
}

/**
 * نافذة الشاشة على المستند.
 *
 * سبب وجودها: الرقم المتسلسل وحده لم يكن كافياً. كان يحرس مسار الخطأ فقط،
 * فشاشةٌ تنتظر ردّ الخادم ثم تكتب في outlet.innerHTML مباشرةً كانت تكتب فوق
 * الشاشة التي انتقل إليها المستخدم بينما هي تنتظر. والمستخدم يرى محتوى شاشة
 * غادرها تحت عنوان شاشة أخرى — وفي واجهة مالية هذا أسوأ من الفراغ.
 *
 * الآن الكتابة تمرّ من هنا وحدها: إن أُلغي الانتقال لم تُكتب، وأُعيد false
 * لتتوقّف الشاشة عن العمل. والـsignal يُمرَّر إلى الشبكة فيُلغى الطلب نفسه.
 */
export interface View {
  readonly el: HTMLElement;
  readonly signal: AbortSignal;
  /** يكتب إن كان الانتقال ما زال جارياً. يُعيد false إن فات أوانه. */
  write(html: string): boolean;
  /**
   * نفس write بصيغة الإسناد المعتادة، محروسةً بالقدر نفسه.
   *
   * وجودها مقصود: الكتابة المباشرة هي ما يكتبه المرء تلقائياً، فجعلُها آمنة
   * أضمنُ من الاعتماد على تذكُّر استدعاء write في كل موضع.
   */
  set innerHTML(html: string);
  /** يكتب داخل عنصر فرعي — للتبويبات التي تُحمَّل بعد الإطار. */
  writeInto(selector: string, html: string): boolean;
  /** هل ما زالت هذه الشاشة هي المعروضة؟ */
  readonly live: boolean;
}

export interface Route {
  /** نمط مثل `/installation/subscribers/:id` */
  pattern: string;
  /** القدرة المطلوبة؛ يُفحص العرض فقط — الخادم يبقى الحارس. */
  capability?: string;
  title: string;
  /** فتات الخبز: نصوص ومسارات الآباء. */
  breadcrumb?: (m: RouteMatch) => Array<{ label: string; href?: string }>;
  render: (view: View, m: RouteMatch) => void | Promise<void>;
}

const segments = (p: string) => p.replace(/^\/+|\/+$/g, '').split('/').filter(Boolean);

export function matchRoute(pattern: string, path: string): Record<string, string> | null {
  const pa = segments(pattern);
  const pb = segments(path);
  if (pa.length !== pb.length) return null;
  const params: Record<string, string> = {};
  for (let i = 0; i < pa.length; i += 1) {
    const a = pa[i] as string;
    const b = pb[i] as string;
    if (a.startsWith(':')) params[a.slice(1)] = decodeURIComponent(b);
    else if (a !== b) return null;
  }
  return params;
}

/** يقرأ المسار والاستعلام من الـhash. `#/a/b?x=1` */
export function readLocation(): { path: string; query: URLSearchParams } {
  const raw = window.location.hash.slice(1);
  if (!raw.startsWith('/')) return { path: '/', query: new URLSearchParams() };
  const qi = raw.indexOf('?');
  if (qi === -1) return { path: raw, query: new URLSearchParams() };
  return { path: raw.slice(0, qi), query: new URLSearchParams(raw.slice(qi + 1)) };
}

export function href(path: string, query?: Record<string, string | undefined>): string {
  const q = new URLSearchParams();
  Object.entries(query || {}).forEach(([k, v]) => { if (v !== undefined && v !== '') q.set(k, v); });
  const qs = q.toString();
  return `#${path}${qs ? `?${qs}` : ''}`;
}

export function navigate(path: string, query?: Record<string, string | undefined>): void {
  window.location.hash = href(path, query).slice(1);
}

/** يستبدل المسار دون إضافة خطوة إلى تاريخ المتصفح. */
export function replace(path: string, query?: Record<string, string | undefined>): void {
  window.history.replaceState(null, '', href(path, query));
  window.dispatchEvent(new HashChangeEvent('hashchange'));
}

export interface RouterOptions {
  outlet: HTMLElement;
  routes: Route[];
  onNavigated?: (route: Route, m: RouteMatch) => void;
  can: (capability: string) => boolean;
  /**
   * هل وصلت الصلاحيات من الخادم بعد؟ غيابها اختياري: من لا يمرّره يقبل خطر
   * "ممنوع" لحظياً قبل وصول الجلسة — كما كان الحال قبل LIVE-08.
   */
  capabilitiesReady?: () => boolean;
  /** يُعرض بدل "ممنوع" ريثما تصل الصلاحيات — لا حكم نهائي بعد. */
  renderCapabilityLoading?: (outlet: HTMLElement, capability: string) => void;
  renderForbidden: (outlet: HTMLElement, capability: string) => void;
  renderNotFound: (outlet: HTMLElement, path: string) => void;
  renderError: (outlet: HTMLElement, error: unknown) => void;
}

function makeView(el: HTMLElement, signal: AbortSignal): View {
  return {
    el,
    signal,
    get live() { return !signal.aborted; },
    write(html: string) {
      if (signal.aborted) return false;
      el.innerHTML = html;
      return true;
    },
    set innerHTML(html: string) {
      if (signal.aborted) return;
      el.innerHTML = html;
    },
    writeInto(selector: string, html: string) {
      if (signal.aborted) return false;
      const host = el.querySelector<HTMLElement>(selector);
      if (!host) return false;
      host.innerHTML = html;
      return true;
    },
  };
}

export class Router {
  private readonly options: RouterOptions;
  private inflight: AbortController | null = null;

  constructor(options: RouterOptions) {
    this.options = options;
  }

  start(): void {
    window.addEventListener('hashchange', () => { void this.resolve(); });
    if (!window.location.hash.startsWith('#/')) {
      window.history.replaceState(null, '', '#/');
    }
    void this.resolve();
  }

  /** يُعيد الرسم للمسار الحالي — بعد تغيّر يمسّ المعروض. */
  refresh(preserveScroll = false): void { void this.resolve(preserveScroll); }

  private async resolve(preserveScroll = false): Promise<void> {
    const priorScroll = preserveScroll ? window.scrollY : 0;
    const { path, query } = readLocation();
    const { outlet, routes } = this.options;

    // الانتقال الجديد يُلغي سابقه: طلبه الشبكي يُقطع، وكتابته تُرفَض.
    this.inflight?.abort();
    const controller = new AbortController();
    this.inflight = controller;
    const view = makeView(outlet, controller.signal);

    for (const route of routes) {
      const params = matchRoute(route.pattern, path);
      if (!params) continue;

      const match: RouteMatch = { path, params, query };

      if (route.capability) {
        const ready = this.options.capabilitiesReady?.() ?? true;
        if (!ready && this.options.renderCapabilityLoading) {
          if (!controller.signal.aborted) {
            this.options.renderCapabilityLoading(outlet, route.capability);
            this.options.onNavigated?.(route, match);
          }
          return;
        }
        if (ready && !this.options.can(route.capability)) {
          if (!controller.signal.aborted) {
            this.options.renderForbidden(outlet, route.capability);
            this.options.onNavigated?.(route, match);
          }
          return;
        }
      }

      try {
        this.options.onNavigated?.(route, match);
        const result = route.render(view, match);
        if (result instanceof Promise) await result;
        if (preserveScroll && !controller.signal.aborted) {
          window.requestAnimationFrame(() => window.scrollTo({ top: priorScroll }));
        }
      } catch (error) {
        // الإلغاء ليس خطأً يُعرَض: المستخدم غادر الشاشة عمداً.
        if (controller.signal.aborted) return;
        if (isAbortError(error)) return;
        this.options.renderError(outlet, error);
      }
      return;
    }

    if (!controller.signal.aborted) this.options.renderNotFound(outlet, path);
  }
}

export function isAbortError(error: unknown): boolean {
  return error instanceof DOMException && error.name === 'AbortError';
}
