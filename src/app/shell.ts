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

export const NAV: NavGroup[] = [
  {
    key: 'main', label: '', items: [
      { label: 'الرئيسية', path: '/', icon: '▦', capability: 'report.view' },
    ],
  },
  {
    key: 'commission', label: 'عمولات الوكلاء', items: [
      { label: 'نظرة عامة', path: '/commissions', icon: '◎', capability: 'commission.view' },
      { label: 'الدورات', path: '/commissions/cycles', icon: '🗓', capability: 'commission.view' },
      { label: 'الوكلاء', path: '/commissions/agents', icon: '♟', capability: 'commission.view' },
    ],
  },
  {
    key: 'installation', label: 'أجور التنصيب', items: [
      { label: 'مركز التحكّم', path: '/installation', icon: '⚙', capability: 'installation.view' },
      { label: 'المشتركون', path: '/installation/subscribers', icon: '👥', capability: 'installation.view' },
      { label: 'الفواتير', path: '/installation/invoices', icon: '🧾', capability: 'installation.view' },
      { label: 'جاهز للصرف', path: '/installation/ready', icon: '✓', capability: 'installation.view' },
      { label: 'الموقوفون', path: '/installation/holds', icon: '⏸', capability: 'installation.view' },
    ],
  },
  {
    key: 'finance', label: 'المالية', items: [
      { label: 'دفعات الصرف', path: '/finance/payment-batches', icon: '◈', capability: 'payment.view' },
    ],
  },
  {
    key: 'master', label: 'البيانات المرجعية', items: [
      { label: 'الآباء', path: '/master/parents', icon: '⌂', capability: 'agent.view' },
    ],
  },
  {
    key: 'work', label: 'العمل', items: [
      { label: 'مركز العمل', path: '/work', icon: '◈', capability: 'report.view' },
      { label: 'الاستثناءات', path: '/exceptions', icon: '⚠', capability: 'commission.view' },
    ],
  },
  {
    key: 'legacy', label: 'الشاشات السابقة', items: [
      { label: 'مساحة العمل الكاملة', path: '/legacy', icon: '▤', legacy: true },
    ],
  },
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
