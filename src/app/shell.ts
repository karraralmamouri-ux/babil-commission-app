/**
 * الشريط الجانبي وفتات الخبز.
 *
 * كل عنصر يقصد مساراً حقيقياً. لا اسمَين يقصدان لوحةً واحدة — وهذا كان أصل
 * العيب: خمس تسميات في «أجور التنصيب» كانت تصل إلى نفس الودجت.
 */

import { href, readLocation } from './router';
import { esc } from '../components/ui';

export interface NavItem {
  label: string;
  path: string;
  icon: string;
  capability?: string;
  /** مسار قديم يُبقى مؤقّتاً حتى تُهاجَر شاشته. */
  legacy?: boolean;
}

export interface NavGroup {
  key: string;
  label: string;
  items: NavItem[];
}

/**
 * الملاحة.
 *
 * لغة أيقونات واحدة: محارف هندسية أحادية اللون. الرموز التعبيرية (🗓 👥 🧾)
 * تُرسَم ملوّنةً بخطّ النظام، فتكسر النظام البصري وتتغيّر شكلاً بين
 * المنصّات. استُبدلت بمحارف من العائلة نفسها.
 */
/*
 * الترتيب: نتيجة ← قرار ← إجراء.
 *
 * كان الشريط مرتَّباً بالجداول: قسمٌ لكل محرّك، وقسمٌ لكل مجموعة شاشات.
 * فيقرأ المشغّل «الاستثناءات» و«تصحيح التفعيلات» و«الدورة الشهرية» بلا
 * ترتيبٍ يقول أيّها نتيجة وأيّها قرار.
 *
 * فصار الترتيب يتبع السؤال لا الجدول: ما النتيجة؟ ثم ما القرار المطلوب؟
 * ثم أين البيانات التي تُبنى عليها؟ ثم النظام.
 *
 * والمسارات لم تتغيّر — أُعيد تجميعها فقط. كل رابطٍ عميق قديم يبقى صالحاً،
 * وما خرج من الشريط لم يخرج من المُوجِّه: يُبلَغ من سياقه (زرّ في صفّ، أو
 * وصلة من قرار) لا من قائمةٍ عامة.
 */
export const NAV: NavGroup[] = [
  {
    key: 'main', label: '', items: [
      { label: 'الرئيسية', path: '/', icon: '▦', capability: 'report.view' },
    ],
  },
  {
    key: 'results', label: 'النتائج المالية', items: [
      { label: 'العمولات', path: '/commissions', icon: '◎', capability: 'commission.view' },
      { label: 'أجور التنصيب', path: '/installation', icon: '⊞', capability: 'installation.view' },
      { label: 'التقارير', path: '/reports', icon: '▧', capability: 'report.view' },
      { label: 'الأرشيف', path: '/reports/archive', icon: '▩', capability: 'report.view' },
    ],
  },
  {
    key: 'work', label: '', items: [
      { label: 'مركز العمل', path: '/work', icon: '◉', capability: 'report.view' },
    ],
  },
  {
    key: 'data', label: 'البيانات', items: [
      { label: 'المشتركون', path: '/installation/subscribers', icon: '◫', capability: 'installation.view' },
      { label: 'الوكلاء والكابينات', path: '/master/mapping', icon: '⋈', capability: 'commission.view' },
      { label: 'الملكية وأسماء المصدر', path: '/master/parents', icon: '⌂', capability: 'agent.view' },
      { label: 'الباقات', path: '/master/packages', icon: '▥', capability: 'agent.view' },
      { label: 'أسعار العمولات والتير', path: '/master/commission-schemes', icon: '⊜', capability: 'commission.view' },
    ],
  },
  {
    key: 'system', label: 'النظام', items: [
      { label: 'الاستيراد', path: '/system/imports', icon: '⊕', capability: 'saas.review' },
      { label: 'المستخدمون والصلاحيات', path: '/system/users', icon: '◍', capability: 'permission.manage' },
      { label: 'سجلّ التدقيق', path: '/audit', icon: '❑', capability: 'audit.view' },
    ],
  },
  {
    // تبقى مرئيّةً ومُعلَّمةً بأنها سابقة، وللقراءة التاريخية وحدها.
    key: 'legacy', label: 'الشاشات السابقة', items: [
      { label: 'مساحة العمل الكاملة', path: '/legacy', icon: '▥', legacy: true },
    ],
  },
];

/**
 * مسارات باقية في المُوجِّه وخارج الشريط.
 *
 * ليست محذوفة ولا مهجورة: تُبلَغ من سياقها. «جاهز للصرف» يُفتح من نتيجة
 * التنصيب، و«مراجعة الفواتير» من قرارها في مركز العمل، و«تصحيح التفعيلات»
 * من الحدث نفسه. وضعُها في قائمةٍ عامة يجعل المشغّل يختار من بين عشرين
 * اسماً بدل أن يتبع ما تقوله النتيجة.
 *
 * تُذكر هنا صراحةً ليبقى وجودها مقصوداً ومُختبَراً، لا منسيّاً.
 */
export const CONTEXTUAL_ROUTES: string[] = [
  '/commissions/cycles',
  '/commissions/agents',
  '/commissions/corrections',
  '/exceptions',
  '/installation/cycle',
  '/installation/invoices',
  '/installation/ready',
  '/installation/holds',
  '/finance/payment-batches',
  '/finance/installation-batches',
  '/master/agents',
  '/master/fdts',
  '/system/imports/new',
];

/**
 * يبني الشريط، ويُخفي ما لا صلاحية له. الخادم يبقى الحارس.
 *
 * الإبراز يختار أطولَ مسارٍ مطابق، لا أوّلَ بادئة.
 * `/installation` بادئةٌ لـ`/installation/subscribers`، فمطابقة البادئة كانت
 * تُبرز «مركز التحكّم» بينما المستخدم في «المشتركون» — شريطٌ يكذب على
 * المستخدم بموضعه أسوأ من شريط بلا إبراز.
 */
export function renderNav(host: HTMLElement, can: (c: string) => boolean): void {
  const { path } = readLocation();

  const matches = (p: string) => (p === '/' ? path === '/' : path === p || path.startsWith(p + '/'));
  const best = NAV
    .flatMap((g) => g.items)
    .filter((i) => matches(i.path))
    .sort((a, b) => b.path.length - a.path.length)[0];
  const isActive = (p: string) => best !== undefined && best.path === p;

  host.innerHTML = NAV.map((group) => {
    const items = group.items.filter((i) => !i.capability || can(i.capability));
    if (!items.length) return '';
    const links = items.map((i) => `
      <a class="side-btn${isActive(i.path) ? ' active' : ''}" href="${esc(href(i.path))}">
        <span class="ico" aria-hidden="true">${esc(i.icon)}</span>
        <span class="txt">${esc(i.label)}</span>
      </a>`).join('');
    return group.label
      ? `<div class="side-section"><div class="side-label">${esc(group.label)}</div>
           <nav class="side-nav">${links}</nav></div>`
      : `<div class="side-section"><nav class="side-nav">${links}</nav></div>`;
  }).join('');
}

export function renderBreadcrumbs(host: HTMLElement, trail: Array<{ label: string; href?: string }>): void {
  if (!trail.length) { host.innerHTML = ''; return; }
  host.innerHTML = trail.map((c, i) => {
    const last = i === trail.length - 1;
    return last || !c.href
      ? `<span aria-current="${last ? 'page' : 'false'}">${esc(c.label)}</span>`
      : `<a href="${esc(c.href)}">${esc(c.label)}</a>`;
  }).join('<span class="sep" aria-hidden="true">›</span>');
}
