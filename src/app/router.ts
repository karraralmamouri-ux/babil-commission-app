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

export interface Route {
  /** نمط مثل `/installation/subscribers/:id` */
  pattern: string;
  /** القدرة المطلوبة؛ يُفحص العرض فقط — الخادم يبقى الحارس. */
  capability?: string;
  title: string;
  /** فتات الخبز: نصوص ومسارات الآباء. */
  breadcrumb?: (m: RouteMatch) => Array<{ label: string; href?: string }>;
  render: (outlet: HTMLElement, m: RouteMatch) => void | Promise<void>;
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
  const target = href(path, query);
  window.history.replaceState(null, '', target);
  window.dispatchEvent(new HashChangeEvent('hashchange'));
}

export interface RouterOptions {
  outlet: HTMLElement;
  routes: Route[];
  /** يُستدعى بعد كل انتقال ناجح — لتحديث الشريط وفتات الخبز. */
  onNavigated?: (route: Route, m: RouteMatch) => void;
  /** يقرر إن كان المستخدم يملك القدرة. العرض فقط. */
  can: (capability: string) => boolean;
  renderForbidden: (outlet: HTMLElement, capability: string) => void;
  renderNotFound: (outlet: HTMLElement, path: string) => void;
  renderError: (outlet: HTMLElement, error: unknown) => void;
}

export class Router {
  private readonly options: RouterOptions;
  private token = 0;

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
  refresh(): void { void this.resolve(); }

  private async resolve(): Promise<void> {
    const { path, query } = readLocation();
    const { outlet, routes } = this.options;

    // كل انتقال يحمل رقمه. الردّ البطيء لانتقال سابق لا يكتب فوق الحالي.
    this.token += 1;
    const mine = this.token;

    for (const route of routes) {
      const params = matchRoute(route.pattern, path);
      if (!params) continue;

      const match: RouteMatch = { path, params, query };

      if (route.capability && !this.options.can(route.capability)) {
        this.options.renderForbidden(outlet, route.capability);
        this.options.onNavigated?.(route, match);
        return;
      }

      try {
        const result = route.render(outlet, match);
        this.options.onNavigated?.(route, match);
        if (result instanceof Promise) await result;
      } catch (error) {
        if (mine === this.token) this.options.renderError(outlet, error);
      }
      return;
    }

    this.options.renderNotFound(outlet, path);
  }
}
