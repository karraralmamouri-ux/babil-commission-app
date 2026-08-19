/**
 * مدخل تطبيق BABIL FLOW.
 *
 * يعمل جنباً إلى جنب مع الشيفرة القديمة في index.html خلال الهجرة:
 * المصادقة والجلسة وشاشات لم تُهاجَر بعد تبقى هناك، والموجِّه يملك ما هُوجر.
 * شرط إزالة الجسر مذكور في docs/engineering/index-html-exit-plan.md.
 */

import { Router, readLocation, type Route } from './app/router';
import { renderNav, renderBreadcrumbs } from './app/shell';
import { can } from './services/api';
import { errorState, forbidden, empty } from './components/ui';

import { routes as homeRoutes } from './features/home';
import { routes as commissionRoutes } from './features/commissions';
import { routes as installationRoutes } from './features/installation';
import { routes as financeRoutes } from './features/finance';
import { routes as masterRoutes } from './features/master';
import { routes as workRoutes } from './features/work';

const legacyRoute: Route = {
  pattern: '/legacy',
  title: 'مساحة العمل السابقة',
  breadcrumb: () => [{ label: 'الرئيسية', href: '#/' }, { label: 'مساحة العمل السابقة' }],
  render(view) {
    // الشاشات التي لم تُهاجَر بعد تبقى تعمل كما هي، ولا تُحذف قبل بديلها.
    view.write('');
    document.body.classList.add('legacy-visible');
  },
};

const ROUTES: Route[] = [
  ...homeRoutes,
  ...commissionRoutes,
  ...installationRoutes,
  ...financeRoutes,
  ...masterRoutes,
  ...workRoutes,
  legacyRoute,
];

function boot(): void {
  const outlet = document.getElementById('appOutlet');
  const navHost = document.getElementById('appNav');
  const crumbHost = document.getElementById('appCrumbs');
  if (!outlet || !navHost) return;

  const router = new Router({
    outlet,
    routes: ROUTES,
    can,
    onNavigated: (route, match) => {
      document.body.classList.toggle('legacy-visible', route.pattern === '/legacy');
      renderNav(navHost, can);
      if (crumbHost) renderBreadcrumbs(crumbHost, route.breadcrumb ? route.breadcrumb(match) : []);
      const title = document.getElementById('appScreenTitle');
      if (title) title.textContent = route.title;
      document.title = `${route.title} — BABIL FLOW`;
      outlet.scrollTo?.({ top: 0 });
      window.scrollTo({ top: 0 });
    },
    renderForbidden: (host, capability) => { host.innerHTML = forbidden(capability); },
    renderNotFound: (host, path) => {
      host.innerHTML = empty('الشاشة غير موجودة', path);
    },
    renderError: (host, error) => {
      const message = error instanceof Error ? error.message : 'خطأ غير متوقّع';
      host.innerHTML = errorState(message, 'location.reload()');
    },
  });

  renderNav(navHost, can);
  router.start();

  // إعادة الرسم بعد وصول الصلاحيات من الخادم: الشريط يُبنى قبلها فارغاً.
  window.addEventListener('babil:capabilities', () => {
    renderNav(navHost, can);
    router.refresh();
  });
}

/**
 * الانتظار مقصود: index.html يفحص رابط استرجاع كلمة المرور من الـhash
 * (`#access_token=…&type=recovery`) قبل أن يرى الموجِّه الـhash. لو بدأ
 * الموجِّه أولاً لابتلع الـhash وضاع الاسترجاع.
 */
function whenAppShellReady(): void {
  const ready = document.getElementById('appOutlet')
    && !window.location.hash.includes('access_token');
  if (ready) { boot(); return; }
  window.setTimeout(whenAppShellReady, 120);
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', whenAppShellReady);
} else {
  whenAppShellReady();
}

export { ROUTES, readLocation };
