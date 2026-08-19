/**
 * المستخدمون والصلاحيات.
 *
 * الكتالوج في القاعدة هو المرجع: لا عدد مثبَّت هنا ولا قائمة مكرّرة. تُعرض
 * كل قدرة بحكمها ومصدره — دورٌ أم منحٌ صريح أم منعٌ صريح — فلا يبقى سؤال
 * «لماذا يستطيع هذا؟» بلا جواب على الشاشة.
 *
 * وقدرةٌ ممنوحة لا يعرفها الكتالوج تُعرض بمفتاحها التقني مع قولٍ صريح إنها
 * غير معرّفة. إخفاؤها يترك صلاحيةً نافذة بلا أثر مرئي، و«؟؟؟» تقول للمشغّل
 * إن النظام لا يعرف ما يفعل.
 */

import type { Route } from '../../app/router';
import { href } from '../../app/router';
import { rpc, pageRpc } from '../../services/api';
import { count } from '../../domain/money';
import {
  esc, loading, empty, pageHeader, table, pager, kpiRow, chip,
  filterBar, wireFilters, type Column,
} from '../../components/ui';

type Row = Record<string, unknown>;
const num = (r: Row, k: string) => Number(r[k] || 0);
const str = (r: Row, k: string) => String(r[k] ?? '');
const when = (v: unknown) => (v ? String(v).replace('T', ' ').slice(0, 16) : '—');

const SOURCE_AR: Record<string, { label: string; tone: 'success' | 'critical' | 'info' | 'neutral' }> = {
  ROLE:            { label: 'من الدور', tone: 'info' },
  OVERRIDE_GRANT:  { label: 'منح صريح', tone: 'success' },
  OVERRIDE_DENY:   { label: 'منع صريح', tone: 'critical' },
  NONE:            { label: 'غير ممنوحة', tone: 'neutral' },
};

/* ---- قائمة المستخدمين ---------------------------------------------------- */

export const users: Route = {
  pattern: '/system/users',
  capability: 'permission.manage',
  title: 'المستخدمون',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'النظام' },
    { label: 'المستخدمون' },
  ],
  async render(view, m) {
    const limit = 50;
    const offset = Number(m.query.get('offset') || 0);
    view.innerHTML = loading('جارٍ تحميل المستخدمين…');

    const args: Record<string, unknown> = { p_limit: limit, p_offset: offset };
    const search = m.query.get('search');
    const role = m.query.get('role');
    const active = m.query.get('active');
    if (search) args['p_search'] = search;
    if (role) args['p_role'] = role;
    if (active === 'true') args['p_active'] = true;
    if (active === 'false') args['p_active'] = false;

    const [page, cat] = await Promise.all([
      pageRpc<Row>('page_users', args, view.signal),
      rpc<Row>('permission_catalogue', {}).catch(() => null),
    ]);
    if (!view.live) return;

    const roles = (cat?.['roles'] || []) as Row[];
    const domains = (cat?.['domains'] || []) as Row[];

    const columns: Array<Column<Row>> = [
      { key: 'email', label: 'المستخدم', cell: (r) =>
        `<a href="${esc(href(`/system/users/${encodeURIComponent(str(r, 'id'))}`))}">
           <b dir="ltr">${esc(str(r, 'email'))}</b></a>
         ${str(r, 'full_name') ? `<div class="muted">${esc(str(r, 'full_name'))}</div>` : ''}` },
      { key: 'role', label: 'الدور', cell: (r) =>
        chip(str(r, 'role_label') || str(r, 'role'), 'info') },
      { key: 'caps', label: 'قدرات الدور', cell: (r) => count(num(r, 'role_capability_count')), numeric: true },
      { key: 'ovr', label: 'استثناءات', cell: (r) =>
        num(r, 'override_count') ? chip(count(num(r, 'override_count')), 'warning') : '—', numeric: true },
      { key: 'active', label: 'الحالة', cell: (r) =>
        r['is_active'] === true ? chip('فعّال', 'success') : chip('موقوف', 'neutral') },
      { key: 'last', label: 'آخر أثر', cell: (r) =>
        `<span dir="ltr">${esc(when(r['last_action_at']))}</span>` },
      { key: 'go', label: '', cell: (r) =>
        `<a class="smallbtn" href="${esc(href(`/system/users/${encodeURIComponent(str(r, 'id'))}`))}">الصلاحيات</a>` },
    ];

    view.innerHTML = pageHeader('المستخدمون والصلاحيات',
      'كتالوج الصلاحيات في القاعدة هو المرجع — لا قائمة مكرّرة في الواجهة')

      + kpiRow([
        { label: 'المستخدمون', value: count(page.total), tone: 'primary' },
        { label: 'القدرات في الكتالوج', value: count(num(cat || {}, 'total')), tone: 'blue',
          sub: `${count(domains.length)} نطاقاً` },
        { label: 'الأدوار', value: count(roles.length), tone: 'gold' },
        { label: 'قدرات حسّاسة', value:
          count(domains.reduce((a, d) => a + num(d, 'sensitive'), 0)), tone: 'red',
          sub: 'تُمنح بحذر' },
      ])

      + filterBar([
        { key: 'search', label: 'بحث بالبريد أو الاسم', type: 'search' },
        { key: 'role', label: 'الدور', type: 'select',
          options: roles.map((r) => ({ value: str(r, 'key'), label: str(r, 'label_ar') || str(r, 'key') })) },
        { key: 'active', label: 'الحالة', type: 'select', options: [
          { value: 'true', label: 'الفعّالون' }, { value: 'false', label: 'الموقوفون' } ] },
      ], '/system/users', m.query)

      + (page.rows.length ? table(columns, page.rows) : empty('لا مستخدمين مطابقين'))
      + pager(page.total, limit, offset, '/system/users', m.query)

      + `<div class="box" style="margin-top:16px">
        <h3>الأدوار</h3>
        ${roles.map((r) => `<div class="minirow">
          <span>${chip(str(r, 'label_ar') || str(r, 'key'), 'info')}
            <span class="muted" dir="ltr">${esc(str(r, 'key'))}</span></span>
          <span><b>${count(num(r, 'capability_count'))}</b> قدرة ·
            <b>${count(num(r, 'user_count'))}</b> مستخدماً</span></div>`).join('')}
      </div>`;

    wireFilters(view.el);
  },
};

/* ---- صلاحيات مستخدم ------------------------------------------------------ */

export const userDetail: Route = {
  pattern: '/system/users/:id',
  capability: 'permission.manage',
  title: 'صلاحيات المستخدم',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'المستخدمون', href: href('/system/users') },
    { label: 'الصلاحيات' },
  ],
  async render(view, m) {
    const id = m.params['id'] as string;
    view.innerHTML = loading('جارٍ حساب الصلاحيات الفعّالة…');

    const doc = await rpc<Row>('user_effective_permissions', { p_user_id: id });
    if (!view.live) return;
    if (!doc || doc['found'] !== true) {
      view.innerHTML = empty('المستخدم غير موجود', id);
      return;
    }

    const profile = (doc['profile'] || {}) as Row;
    const caps = (doc['capabilities'] || []) as Row[];
    const uncat = (doc['uncatalogued'] || []) as Row[];
    const granted = caps.filter((c) => c['effective'] === true);
    const denied = caps.filter((c) => str(c, 'source') === 'OVERRIDE_DENY');
    const admins = num(doc, 'administrators_remaining');

    // مجمَّعة بالنطاق: القراءة بالنطاق أسرع من قائمةٍ من 44 سطراً.
    const byDomain = new Map<string, Row[]>();
    for (const c of caps) {
      const d = str(c, 'domain') || 'أخرى';
      if (!byDomain.has(d)) byDomain.set(d, []);
      (byDomain.get(d) as Row[]).push(c);
    }

    view.innerHTML = pageHeader(str(profile, 'email') || id,
      `${esc(str(profile, 'full_name') || '')} · ${esc(str(doc, 'role_label') || str(doc, 'role'))}`,
      profile['is_active'] === true ? chip('فعّال', 'success') : chip('موقوف', 'neutral'))

      + kpiRow([
        { label: 'قدرات فعّالة', value: count(granted.length), tone: 'primary',
          sub: `من ${count(num(doc, 'catalogue_size'))} في الكتالوج` },
        { label: 'منع صريح', value: count(denied.length), tone: 'red',
          sub: denied.length ? 'يتقدّم على الدور' : 'لا منع' },
        { label: 'الدور', value: esc(str(doc, 'role_label') || str(doc, 'role')), tone: 'blue' },
        { label: 'إداريون متبقّون', value: count(admins), tone: admins > 1 ? 'green' : 'red',
          sub: admins > 1 ? 'يمكن سحب صلاحية بأمان' : 'آخر إداري — السحب يُقفل النظام' },
      ])

      // ما لا يعرفه الكتالوج يُقال، لا يُخفى ولا يُسمّى «؟؟؟».
      + (uncat.length
        ? `<div class="insight warn" style="margin-top:12px"><span class="insight-dot"></span><span>
            <b>${count(uncat.length)} قدرة غير معرّفة في كتالوج الصلاحيات</b>
            <small>${uncat.map((u) => `<code dir="ltr">${esc(str(u, 'capability_key'))}</code>`).join('، ')}
            — نافذة فعلاً ولا وصف لها. تُضاف إلى الكتالوج أو تُسحب.</small></span></div>`
        : '')

      + [...byDomain.entries()].map(([domain, list]) => `<div class="box" style="margin-top:12px">
          <h3>${esc(domain)}</h3>
          ${list.map((c) => {
            const src = SOURCE_AR[str(c, 'source')] ?? { label: 'غير ممنوحة', tone: 'neutral' as const };
            const on = c['effective'] === true;
            return `<div class="minirow">
              <span>
                ${on ? chip('نعم', 'success') : chip('لا', 'neutral')}
                <b>${esc(str(c, 'label_ar') || str(c, 'capability'))}</b>
                ${c['is_sensitive'] === true ? chip('حسّاسة', 'warning') : ''}
                <span class="muted" dir="ltr">${esc(str(c, 'capability'))}</span>
                ${str(c, 'description') ? `<div class="muted">${esc(str(c, 'description'))}</div>` : ''}
              </span>
              <span>
                ${chip(src.label, src.tone)}
                ${str(c, 'override_scope_type')
                  ? `<span class="muted">نطاق: ${esc(str(c, 'override_scope_type'))}
                     ${esc(str(c, 'override_scope_id') || '')}</span>` : ''}
                ${str(c, 'override_expires_at')
                  ? `<span class="muted">ينتهي ${esc(when(c['override_expires_at']))}</span>` : ''}
                ${str(c, 'override_reason')
                  ? `<div class="muted">${esc(str(c, 'override_reason'))}</div>` : ''}
              </span></div>`;
          }).join('')}
        </div>`).join('');
  },
};

export const routes: Route[] = [users, userDetail];
