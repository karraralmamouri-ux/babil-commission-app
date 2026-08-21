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

import type { Route, View } from '../../app/router';
import { href } from '../../app/router';
import { dateTime } from '../../domain/time';
import { rpc, pageRpc, edge, can, ApiError } from '../../services/api';
import { count } from '../../domain/money';
import {
  esc, loading, empty, pageHeader, table, pager, kpiRow, chip,
  filterBar, wireFilters, type Column,
} from '../../components/ui';

type Row = Record<string, unknown>;
const num = (r: Row, k: string) => Number(r[k] || 0);
const str = (r: Row, k: string) => String(r[k] ?? '');
const when = (v: unknown) => (v ? dateTime(v) : '—');

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

      + createPanel(roles)
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
    wireCreatePanel(view);
  },
};

/* ---- إنشاء حساب ---------------------------------------------------------- */

/**
 * إنشاء الحساب وحده يمرّ بدالّة الحافة، لأن نظام المصادقة لا يُكتب إلا
 * بصلاحية خدمة. والمفتاح يبقى هناك: الصفحة ترسل رمز جلسة صاحب الطلب، ودالّة
 * الحافة هي التي تتحقّق منه ثم تنشئ الحساب.
 *
 * وكلمة المرور لا تُحفظ في الحالة ولا تُطبع ولا تُرسل إلى أي مكانٍ آخر —
 * تُقرأ من الحقل عند الإرسال ويُمسح الحقل بعده.
 */
function createPanel(roles: Row[]): string {
  if (!can('permission.manage')) return '';
  return `<div class="box" style="margin-top:12px" id="newUserBox">
    <h3>حساب جديد</h3>
    <p class="muted" style="font-size:11px;margin:0 0 10px">
      الدور يُعطي مجموعة قدراتٍ جاهزة، وتُعدَّل بالاستثناءات بعد الإنشاء من
      صفحة المستخدم. لا تقلّ كلمة المرور عن ثمانية محارف.</p>
    <div class="toolbar">
      <input class="search" id="nuName" placeholder="الاسم الكامل" aria-label="الاسم الكامل">
      <input class="search" id="nuEmail" type="email" placeholder="البريد"
        aria-label="البريد الإلكتروني" dir="ltr" autocomplete="off">
      <input class="search" id="nuPass" type="password" placeholder="كلمة المرور"
        aria-label="كلمة المرور" autocomplete="new-password">
      <input class="search" id="nuPass2" type="password" placeholder="تأكيد كلمة المرور"
        aria-label="تأكيد كلمة المرور" autocomplete="new-password">
      <select class="select" id="nuRole" aria-label="الدور">
        ${roles.map((r) => `<option value="${esc(str(r, 'key'))}"
          ${str(r, 'key') === 'viewer' ? 'selected' : ''}>${esc(str(r, 'label_ar') || str(r, 'key'))}</option>`).join('')}
      </select>
      <button class="btn gold" id="nuCreate">أنشئ</button>
    </div>
    <div id="nuResult"></div>
  </div>`;
}

function wireCreatePanel(view: View): void {
  const box = view.el.querySelector<HTMLElement>('#newUserBox');
  if (!box) return;
  const name = box.querySelector<HTMLInputElement>('#nuName');
  const email = box.querySelector<HTMLInputElement>('#nuEmail');
  const pass = box.querySelector<HTMLInputElement>('#nuPass');
  const confirmPass = box.querySelector<HTMLInputElement>('#nuPass2');
  const role = box.querySelector<HTMLSelectElement>('#nuRole');
  const create = box.querySelector<HTMLButtonElement>('#nuCreate');
  const out = box.querySelector<HTMLElement>('#nuResult');
  if (!name || !email || !pass || !confirmPass || !role || !create || !out) return;

  create.addEventListener('click', async () => {
    if (!name.value.trim()) { out.innerHTML = insight('warn', 'الاسم إلزامي'); return; }
    if (!email.value.trim()) { out.innerHTML = insight('warn', 'البريد إلزامي'); return; }
    if (pass.value.length < 8) {
      out.innerHTML = insight('warn', 'كلمة المرور قصيرة', 'ثمانية محارف على الأقل');
      return;
    }
    // كلمة المرور لا تُعرض بعد كتابتها، فخطأٌ مطبعيّ فيها يُقفل الحساب على
    // صاحبه ولا يظهر إلا عند أول محاولة دخول. التأكيد يكشفه الآن.
    if (pass.value !== confirmPass.value) {
      out.innerHTML = insight('warn', 'التأكيد لا يطابق كلمة المرور');
      return;
    }
    create.disabled = true;
    out.innerHTML = loading('جارٍ إنشاء الحساب…');
    try {
      await edge<Row>('admin-users', {
        action: 'create',
        full_name: name.value.trim(),
        email: email.value.trim(),
        password: pass.value,
        role: role.value,
      });
      pass.value = ''; confirmPass.value = '';
      if (!view.live) return;
      out.innerHTML = insight('good', 'أُنشئ الحساب',
        'صار بإمكانه الدخول، وقدراته من دوره حتى تُستثنى.');
      window.setTimeout(() => { if (view.live) window.location.reload(); }, 1300);
    } catch (error) {
      pass.value = ''; confirmPass.value = '';
      if (!view.live) return;
      out.innerHTML = insight('danger', 'لم يُنشأ الحساب',
        error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
    } finally {
      create.disabled = false;
    }
  });
}

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

    const [doc, cat] = await Promise.all([
      rpc<Row>('user_effective_permissions', { p_user_id: id }),
      rpc<Row>('permission_catalogue', {}).catch(() => null),
    ]);
    if (!view.live) return;
    const roleOptions = (cat?.['roles'] || []) as Row[];
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

      + profilePanel(id, profile, str(doc, 'role'), roleOptions, admins)

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
                ${can('permission.manage')
                  ? `<button class="smallbtn cap-pick"
                       data-cap="${esc(str(c, 'capability'))}"
                       data-effect="${on ? 'DENY' : 'GRANT'}">${on ? 'امنع' : 'امنح'}</button>`
                  : ''}
              </span></div>`;
          }).join('')}
        </div>`).join('')

      + overridePanel(id, caps);

    wireProfilePanel(view, id);
    wireOverridePanel(view, id);
  },
};

/* ---- تعديل الحساب: الاسم والدور والتفعيل ---------------------------------- */

/**
 * الدور والتفعيل يُكتبان بدالّة `update_user_profile` وحدها.
 *
 * كانت دالّة الحافة `admin-users` تكتبهما أيضاً بمفتاح الخدمة، بحارسٍ أضعف:
 * تمنع الإداريّ من نزع صلاحية نفسه فقط. فكان بالإمكان أن ينزع إداريٌّ صلاحية
 * الإداريّ الأخير غيره ويقفل النظام على الجميع. صار المسار واحداً، وحارسه
 * يعدّ الإداريين الفعّالين كلّهم لا صاحب الطلب وحده.
 */
function profilePanel(
  id: string, profile: Row, role: string, roles: Row[], adminsRemaining: number,
): string {
  if (!can('permission.manage')) return '';
  const active = profile['is_active'] === true;
  const options = roles.length
    ? roles
    : [{ key: role, label_ar: role }];
  return `<div class="box" style="margin-top:12px" id="profileBox" data-user="${esc(id)}">
    <h3>الحساب</h3>
    <p class="muted" style="font-size:11px;margin:0 0 10px">
      كل تغييرٍ هنا يُسجَّل بفاعله وسببه.
      ${adminsRemaining > 1
        ? `يوجد ${count(adminsRemaining)} إداريين فعّالين، فسحب صلاحية واحدٍ آمن.`
        : 'لا يبقى إلا إداريٌّ فعّال واحد — الخادم يرفض سحبه.'}</p>
    <div class="toolbar">
      <input class="search" id="upName" aria-label="الاسم الكامل"
        placeholder="الاسم الكامل" value="${esc(str(profile, 'full_name'))}">
      <select class="select" id="upRole" aria-label="الدور">
        ${options.map((r) => `<option value="${esc(str(r, 'key'))}"
          ${str(r, 'key') === role ? 'selected' : ''}>${esc(str(r, 'label_ar') || str(r, 'key'))}</option>`).join('')}
      </select>
      <select class="select" id="upActive" aria-label="حالة الحساب">
        <option value="true" ${active ? 'selected' : ''}>فعّال</option>
        <option value="false" ${active ? '' : 'selected'}>موقوف</option>
      </select>
      <input class="search" id="upReason" placeholder="السبب (إلزامي)" aria-label="سبب التغيير">
      <button class="btn gold" id="upSave">احفظ</button>
    </div>
    <div id="upResult"></div>

    <h3 style="margin-top:16px">كلمة المرور</h3>
    <p class="muted" style="font-size:11px;margin:0 0 10px">
      تُعيَّن بدالّة الحافة <code dir="ltr">admin-users</code>، لأن نظام المصادقة
      لا يُكتب إلا بصلاحية خدمةٍ لا تُسلَّم لصفحة. ولا تُخزَّن هنا ولا تُسجَّل —
      يُسجَّل أنها غُيِّرت ومَن غيّرها فقط.</p>
    <div class="toolbar">
      <input class="search" id="upPass" type="password" placeholder="كلمة مرور جديدة"
        aria-label="كلمة مرور جديدة" autocomplete="new-password">
      <input class="search" id="upPass2" type="password" placeholder="تأكيد كلمة المرور"
        aria-label="تأكيد كلمة المرور" autocomplete="new-password">
      <button class="btn" id="upPassSave">عيّن</button>
    </div>
    <div id="upPassResult"></div>
  </div>`;
}

function wireProfilePanel(view: View, id: string): void {
  const box = view.el.querySelector<HTMLElement>('#profileBox');
  if (!box) return;
  const name = box.querySelector<HTMLInputElement>('#upName');
  const role = box.querySelector<HTMLSelectElement>('#upRole');
  const active = box.querySelector<HTMLSelectElement>('#upActive');
  const reason = box.querySelector<HTMLInputElement>('#upReason');
  const save = box.querySelector<HTMLButtonElement>('#upSave');
  const out = box.querySelector<HTMLElement>('#upResult');
  const pass = box.querySelector<HTMLInputElement>('#upPass');
  const passConfirm = box.querySelector<HTMLInputElement>('#upPass2');
  const passSave = box.querySelector<HTMLButtonElement>('#upPassSave');
  const passOut = box.querySelector<HTMLElement>('#upPassResult');
  if (!role || !active || !save || !out) return;

  passSave?.addEventListener('click', async () => {
    if (!pass || !passConfirm || !passOut) return;
    if (pass.value.length < 8) {
      passOut.innerHTML = insight('warn', 'كلمة المرور قصيرة', 'ثمانية محارف على الأقل');
      return;
    }
    // خطأٌ مطبعيّ في حقلٍ لا يُعرض محتواه يُقفل الحساب على صاحبه، ولا يظهر
    // إلا عند أول محاولة دخول. التأكيد يكشفه الآن.
    if (pass.value !== passConfirm.value) {
      passOut.innerHTML = insight('warn', 'التأكيد لا يطابق كلمة المرور');
      return;
    }
    passSave.disabled = true;
    passOut.innerHTML = loading('جارٍ تعيين كلمة المرور…');
    try {
      await edge<Row>('admin-users', { action: 'update', id, password: pass.value });
      pass.value = ''; passConfirm.value = '';
      if (!view.live) return;
      passOut.innerHTML = insight('good', 'عُيِّنت كلمة المرور',
        'سُجِّل التغيير دون قيمته.');
    } catch (error) {
      pass.value = ''; passConfirm.value = '';
      if (!view.live) return;
      passOut.innerHTML = insight('danger', 'لم تُعيَّن كلمة المرور',
        error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
    } finally {
      passSave.disabled = false;
    }
  });

  save.addEventListener('click', async () => {
    const why = reason?.value.trim() || '';
    if (!why) {
      out.innerHTML = insight('warn', 'السبب إلزامي',
        'تغيير الصلاحية يُقرأ لاحقاً في سجلّ التدقيق، وسطرٌ بلا سبب لا يُفهم');
      return;
    }
    save.disabled = true;
    out.innerHTML = loading('جارٍ الحفظ…');
    try {
      await rpc<Row>('update_user_profile', {
        p_user_id: id,
        p_full_name: name?.value.trim() || null,
        p_role: role.value,
        p_is_active: active.value === 'true',
        p_reason: why,
        p_request_id: crypto.randomUUID(),
      });
      if (!view.live) return;
      out.innerHTML = insight('good', 'حُفظ الحساب');
      window.setTimeout(() => { if (view.live) window.location.reload(); }, 1200);
    } catch (error) {
      if (!view.live) return;
      out.innerHTML = insight('danger', 'لم يُحفظ الحساب',
        error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
    } finally {
      save.disabled = false;
    }
  });
}

/* ---- الاستثناءات: منح ومنع ووراثة ---------------------------------------- */

/**
 * «وراثة» ليست خياراً ثالثاً بل إزالة الاستثناء: يعود الحكم إلى الدور.
 * تسميتها «إلغاء» كانت ستوحي بأنها تمنع، وهي قد تمنح.
 */
function overridePanel(id: string, caps: Row[]): string {
  if (!can('permission.manage')) return '';
  return `<div class="box" style="margin-top:12px" id="ovrBox" data-user="${esc(id)}">
    <h3>استثناء على الدور</h3>
    <p class="muted" style="font-size:11px;margin:0 0 10px">
      المنع الصريح يتقدّم على الدور دائماً. والوراثة تُزيل الاستثناء فيعود
      الحكم إلى الدور — لا تمنع ولا تمنح بذاتها.</p>
    <div class="toolbar">
      <select class="select" id="ovCap" aria-label="القدرة">
        <option value="">— القدرة —</option>
        ${caps.map((c) => `<option value="${esc(str(c, 'capability'))}">
          ${esc(str(c, 'label_ar') || str(c, 'capability'))} — ${esc(str(c, 'capability'))}
        </option>`).join('')}
      </select>
      <select class="select" id="ovEffect" aria-label="الحكم">
        <option value="">— الحكم —</option>
        <option value="GRANT">منح صريح</option>
        <option value="DENY">منع صريح</option>
        <option value="INHERIT">وراثة من الدور</option>
      </select>
      <select class="select" id="ovScope" aria-label="النطاق">
        <option value="GLOBAL">كل النظام</option>
        <option value="AGENT">وكيل بعينه</option>
        <option value="FDT">كابينة بعينها</option>
        <option value="ZONE">منطقة بعينها</option>
      </select>
      <input class="search" id="ovScopeId" placeholder="معرّف النطاق"
        aria-label="معرّف النطاق" disabled dir="ltr">
      <input class="search" id="ovReason" placeholder="السبب (إلزامي)" aria-label="سبب الاستثناء">
      <button class="btn gold" id="ovSave">طبّق</button>
    </div>
    <div id="ovResult"></div>
  </div>`;
}

function wireOverridePanel(view: View, id: string): void {
  const box = view.el.querySelector<HTMLElement>('#ovrBox');
  if (!box) return;
  const cap = box.querySelector<HTMLSelectElement>('#ovCap');
  const effect = box.querySelector<HTMLSelectElement>('#ovEffect');
  const scope = box.querySelector<HTMLSelectElement>('#ovScope');
  const scopeId = box.querySelector<HTMLInputElement>('#ovScopeId');
  const reason = box.querySelector<HTMLInputElement>('#ovReason');
  const save = box.querySelector<HTMLButtonElement>('#ovSave');
  const out = box.querySelector<HTMLElement>('#ovResult');
  if (!cap || !effect || !scope || !save || !out) return;

  // نطاقٌ غير عامّ يلزمه معرّف، والعامّ يرفض المعرّف — القيد في الجدول،
  // والحقل هنا يتبعه بدل أن يترك المستخدم يصطدم به.
  const syncScope = () => {
    if (!scopeId) return;
    const global = scope.value === 'GLOBAL';
    scopeId.disabled = global;
    if (global) scopeId.value = '';
  };
  scope.addEventListener('change', syncScope);
  syncScope();

  for (const btn of view.el.querySelectorAll<HTMLButtonElement>('.cap-pick')) {
    btn.addEventListener('click', () => {
      cap.value = btn.dataset['cap'] || '';
      effect.value = btn.dataset['effect'] || '';
      out.innerHTML = '';
      reason?.focus();
    });
  }

  save.addEventListener('click', async () => {
    if (!cap.value) { out.innerHTML = insight('warn', 'اختر القدرة'); return; }
    if (!effect.value) { out.innerHTML = insight('warn', 'اختر الحكم'); return; }
    const why = reason?.value.trim() || '';
    if (!why) {
      out.innerHTML = insight('warn', 'السبب إلزامي',
        'الاستثناء يبقى نافذاً بعد أن يُنسى سببه');
      return;
    }
    if (scope.value !== 'GLOBAL' && !scopeId?.value.trim()) {
      out.innerHTML = insight('warn', 'النطاق يحتاج معرّفاً',
        'استثناء على وكيلٍ أو كابينةٍ أو منطقة يحتاج تعيين أيّها');
      return;
    }
    save.disabled = true;
    out.innerHTML = loading('جارٍ تطبيق الاستثناء…');
    try {
      await rpc<Row>('set_user_permission', {
        p_user_id: id,
        p_capability: cap.value,
        p_effect: effect.value,
        p_scope_type: scope.value,
        p_scope_id: scope.value === 'GLOBAL' ? null : (scopeId?.value.trim() || null),
        p_reason: why,
        p_request_id: crypto.randomUUID(),
      });
      if (!view.live) return;
      out.innerHTML = insight('good', 'طُبِّق الاستثناء',
        effect.value === 'INHERIT'
          ? 'أُزيل الاستثناء وعاد الحكم إلى الدور.'
          : effect.value === 'DENY'
            ? 'المنع الصريح يتقدّم على الدور.'
            : 'مُنحت القدرة صراحةً فوق الدور.');
      window.setTimeout(() => { if (view.live) window.location.reload(); }, 1200);
    } catch (error) {
      if (!view.live) return;
      out.innerHTML = insight('danger', 'لم يُطبَّق الاستثناء',
        error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
    } finally {
      save.disabled = false;
    }
  });
}

function insight(tone: 'good' | 'warn' | 'danger', title: string, detail = ''): string {
  return `<div class="insight ${tone}" style="margin-top:10px"><span class="insight-dot"></span><span>
    <b>${esc(title)}</b>${detail ? `<small>${esc(detail)}</small>` : ''}</span></div>`;
}

export const routes: Route[] = [users, userDetail];
