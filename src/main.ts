/**
 * مدخل تطبيق BABIL FLOW.
 *
 * يعمل جنباً إلى جنب مع الشيفرة القديمة في index.html خلال الهجرة:
 * المصادقة والجلسة وشاشات لم تُهاجَر بعد تبقى هناك، والموجِّه يملك ما هُوجر.
 * شرط إزالة الجسر مذكور في docs/engineering/index-html-exit-plan.md.
 */

import { Router, readLocation, type Route } from './app/router';
import { renderNav, renderBreadcrumbs } from './app/shell';
import { mountSearch } from './app/search';
import { can, capabilitiesReady } from './services/api';
import { errorState, forbidden, empty, loading } from './components/ui';

import { routes as homeRoutes } from './features/home';
import { routes as commissionRoutes } from './features/commissions';
import { routes as installationRoutes } from './features/installation';
import { routes as financeRoutes } from './features/finance';
import { routes as masterRoutes } from './features/master';
import { routes as agentRoutes } from './features/master/agents';
import { routes as schemeRoutes } from './features/master/commission-schemes';
import { routes as mappingRoutes } from './features/master/mapping';
import { routes as fdtEventRoutes } from './features/master/fdt-events';
import { routes as correctionRoutes } from './features/commissions/corrections';
import { routes as workRoutes } from './features/work';
import { routes as decisionRoutes } from './features/work/decisions';
import { routes as productDecisionRoutes } from './features/work/product';
import { routes as auditRoutes } from './features/audit';
import { routes as systemRoutes } from './features/system/users';
import { routes as identityRoutes } from './features/system/identities';
import { routes as importRoutes } from './features/system/imports';
import { routes as importRunRoutes } from './features/system/import-run';
import { routes as reportRoutes } from './features/reports';

const legacyRoute: Route = {
  pattern: '/legacy',
  title: 'مساحة العمل السابقة',
  breadcrumb: () => [{ label: 'الرئيسية', href: '#/' }, { label: 'مساحة العمل السابقة' }],
  render(view) {
    // المحتوى التاريخي يبقى للقراءة، ولا يُحذف قبل أن يُقرأ منه ما يُحتاج.
    view.write('');
    document.body.classList.add('legacy-visible');

    // ويُبنى هنا لا عند الدخول: كان بناؤه يجري في كل دخولٍ وكل استعادة
    // جلسة، فيقرأ جداول الشهر كلّها ويُغرق الطرفية بتحذيرٍ لكل صفٍّ يخصّ
    // شهراً غير مرئي — على مساراتٍ لا علاقة لها بالشهر أصلاً.
    void window.ensureLegacyWorkspace?.();
  },
};

const ROUTES: Route[] = [
  ...homeRoutes,
  ...commissionRoutes,
  ...installationRoutes,
  ...financeRoutes,
  ...masterRoutes,
  ...agentRoutes,
  ...schemeRoutes,
  ...mappingRoutes,
  ...fdtEventRoutes,
  ...correctionRoutes,
  ...workRoutes,
  ...decisionRoutes,
  ...productDecisionRoutes,
  ...auditRoutes,
  ...systemRoutes,
  ...identityRoutes,
  ...importRunRoutes,
  ...importRoutes,
  ...reportRoutes,
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
    capabilitiesReady,
    renderCapabilityLoading: (host) => { host.innerHTML = loading('جارٍ التحقّق من الصلاحيات…'); },
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

  // البحث يعيش في الترويسة القديمة؛ إن غابت مضى التطبيق بلا بحث لا بخطأ.
  const searchHost = document.getElementById('appSearch');
  if (searchHost) mountSearch(searchHost);

  router.start();

  // إعادة الرسم بعد وصول الصلاحيات من الخادم: الشريط يُبنى قبلها فارغاً.
  window.addEventListener('babil:capabilities', () => {
    renderNav(navHost, can);
    router.refresh();
  });
  // تحديثٌ موضعي يحفظ المسار والاستعلام والصفحة. تستعمله إجراءات الشاشات
  // المهاجرة بدل إعادة تحميل التطبيق والجلسة كاملةً.
  window.addEventListener('babil:refresh', () => router.refresh(true));
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
