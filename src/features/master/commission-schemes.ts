/**
 * أسعار العمولات والتير.
 *
 * الزرّ الذي كان يحمل هذا الاسم في الشريط كان ينادي `openSettingsSection`
 * على قسمٍ يعيش داخل مساحة العمل السابقة، وهي مخفيّة خارج `#/legacy`. فكان
 * يفتح `<details>` لا يراه أحد ثم يُمرّر الصفحة إلى عنصرٍ غير مرئي: زرٌّ لا
 * يفعل شيئاً وهو يبدو صالحاً.
 *
 * وهذه ليست إحياءً لذلك المحرّر. ذاك كان يحرّر أسعار الشهر في الحالة
 * المحليّة؛ وهذه تعرض المخطّط المنشور كما هو في القاعدة — وهو المرجع الذي
 * يُحسب به المال اليوم — وتُغيّره بنسخةٍ جديدة لا بتعديل المنشور.
 *
 * والمنشور لا يُعدَّل: مُشغِّلات على الجداول الثلاثة ترفض ذلك، والدوالّ
 * ترفضه قبلها برسالةٍ مفهومة. تعديل قاعدةٍ حُسب بها مالٌ يُعيد كتابة الماضي.
 */

import type { Route, View } from '../../app/router';
import { href } from '../../app/router';
import { rpc, can, ApiError } from '../../services/api';
import { money, count } from '../../domain/money';
import { esc, loading, empty, pageHeader, chip } from '../../components/ui';

type Row = Record<string, unknown>;
const num = (r: Row, k: string) => Number(r[k] || 0);
const str = (r: Row, k: string) => String(r[k] ?? '');

const STATUS: Record<string, { label: string; tone: 'success' | 'warning' | 'neutral' }> = {
  PUBLISHED: { label: 'منشورة', tone: 'success' },
  DRAFT:     { label: 'مسودّة', tone: 'warning' },
  RETIRED:   { label: 'متقاعدة', tone: 'neutral' },
};

const BASIS: Record<string, string> = {
  UNIQUE_ACTIVATED_SUBSCRIBERS: 'المشتركون المفعَّلون الفريدون',
  QUALIFYING_EVENT_COUNT: 'عدد الأحداث المؤهَّلة',
};

const SCOPE: Record<string, string> = {
  AGENT: 'بالوكيل', FDT: 'بالكابينة', GLOBAL: 'عامّ',
};

function insight(tone: 'good' | 'warn' | 'danger', title: string, detail = ''): string {
  return `<div class="insight ${tone}" style="margin-top:10px"><span class="insight-dot"></span><span>
    <b>${esc(title)}</b>${detail ? `<small>${esc(detail)}</small>` : ''}</span></div>`;
}

/** المدى كما يُقرأ: 0–200، و401 فأكثر للمفتوحة. */
function range(tier: Row): string {
  const lo = num(tier, 'min_subscribers');
  const hi = tier['max_subscribers'];
  return hi === null || hi === undefined
    ? `${count(lo)} فأكثر`
    : `${count(lo)} – ${count(Number(hi))}`;
}

export const commissionSchemes: Route = {
  pattern: '/master/commission-schemes',
  capability: 'commission.view',
  title: 'أسعار العمولات والتير',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'البيانات الرئيسية' },
    { label: 'أسعار العمولات والتير' },
  ],
  async render(view, m) {
    view.innerHTML = loading('جارٍ قراءة المخطّط المعتمد…');

    const versionId = m.query.get('version');
    const doc = await rpc<Row>('commission_scheme_detail',
      versionId ? { p_version_id: versionId } : {});
    if (!view.live) return;

    if (doc['found'] !== true) {
      view.innerHTML = empty('لا مخطّط عمولة منشور',
        'لا يمكن حساب عمولة بلا مخطّط معتمد');
      return;
    }

    const version = (doc['version'] || {}) as Row;
    const scheme = (doc['scheme'] || {}) as Row;
    const tiers = (doc['tiers'] || []) as Row[];
    const packages = (doc['packages'] || []) as string[];
    const versions = (doc['versions'] || []) as Row[];
    const status = str(version, 'status');
    const isDraft = status === 'DRAFT';
    const draft = versions.find((v) => str(v, 'status') === 'DRAFT');

    const check = isDraft
      ? await rpc<Row>('validate_commission_draft',
          { p_version_id: str(version, 'id') }).catch(() => null)
      : null;
    if (!view.live) return;
    const problems = (check?.['problems'] || []) as Row[];

    view.innerHTML = pageHeader('أسعار العمولات والتير',
      `${esc(str(scheme, 'name_ar') || str(scheme, 'code'))} · النسخة ${count(num(version, 'version'))}`,
      chip(STATUS[status]?.label || status, STATUS[status]?.tone || 'neutral'))

      /* ١ · ما يقوم عليه الحساب */
      + `<div class="box" style="margin-top:12px">
        <h3>أساس الحساب</h3>
        <div class="minirow">
          <span>أساس الشريحة
            <div class="muted" style="font-size:11px">ما يُعدّ لتحديد الشريحة</div></span>
          <b>${esc(BASIS[str(version, 'tier_basis')] || str(version, 'tier_basis'))}</b></div>
        <div class="minirow">
          <span>نطاق القديمة
            <div class="muted" style="font-size:11px">أين يُجمَع العدّ في المنطقة القديمة</div></span>
          <b>${esc(SCOPE[str(version, 'old_zone_scope')] || str(version, 'old_zone_scope'))}</b></div>
        <div class="minirow">
          <span>نطاق الجديدة
            <div class="muted" style="font-size:11px">أين يُجمَع العدّ في المنطقة الجديدة</div></span>
          <b>${esc(SCOPE[str(version, 'new_zone_scope')] || str(version, 'new_zone_scope'))}</b></div>
        <div class="minirow">
          <span>سريان</span>
          <b>${esc(str(version, 'effective_from') || '— غير محدّد')}</b></div>
        <div class="minirow">
          <span>النشر</span>
          <b>${esc(str(version, 'published_at').slice(0, 10) || '—')}
            ${str(doc, 'published_by_email')
              ? `<span class="muted" dir="ltr">${esc(str(doc, 'published_by_email'))}</span>`
              : '<span class="muted">— لا فاعل مسجَّل (نُشرت بمهاجرة)</span>'}</b></div>
      </div>`

      /* ٢ · الشرائح والأسعار */
      + `<div class="box" style="margin-top:12px">
        <h3>الشرائح والأسعار</h3>
        <p class="muted" style="font-size:11px;margin:0 0 10px">
          المبلغ لكل حدثٍ مؤهَّل، بالدينار. والشريحة تُختار بعدد المشتركين في
          النطاق المذكور أعلاه — لا بشريحةٍ مثبَّتة للوكيل.</p>
        <div style="overflow-x:auto">
        <table class="table"><thead><tr>
          <th>الشريحة</th><th>المدى</th>
          ${packages.map((p) => `<th class="num" dir="ltr">${esc(p)}</th>`).join('')}
          ${isDraft && can('commission.configure') ? '<th></th>' : ''}
        </tr></thead><tbody>
        ${tiers.map((t) => {
          const rates = (t['rates'] || {}) as Record<string, Row>;
          return `<tr>
            <td><b>${esc(str(t, 'label_ar') || str(t, 'code'))}</b>
              ${str(t, 'zone') ? chip(str(t, 'zone') === 'old' ? 'قديمة' : 'جديدة', 'info') : ''}</td>
            <td>${range(t)}</td>
            ${packages.map((p) => {
              const cell = rates[p];
              if (!cell) return '<td class="num"><span class="muted">— لا سعر</span></td>';
              const q = cell['qualifies'] !== false;
              return `<td class="num"><span class="money">${money(Number(cell['amount'] || 0))}</span>
                ${q ? '' : '<div class="muted" style="font-size:10px">لا تُحتسب</div>'}</td>`;
            }).join('')}
            ${isDraft && can('commission.configure')
              ? `<td><button class="smallbtn tier-edit"
                   data-id="${esc(str(t, 'id'))}"
                   data-code="${esc(str(t, 'label_ar') || str(t, 'code'))}"
                   data-min="${esc(str(t, 'min_subscribers'))}"
                   data-max="${esc(t['max_subscribers'] === null ? '' : str(t, 'max_subscribers'))}"
                   >حرِّر</button></td>`
              : ''}
          </tr>`;
        }).join('')}
        </tbody></table></div>
      </div>`

      /* ٣ · المسوّدة وفحصها */
      + (isDraft
        ? (problems.length
            ? `<div class="insight danger" style="margin-top:12px"><span class="insight-dot"></span><span>
                <b>${count(problems.length)} مانعاً من النشر</b>
                <small>${problems.map((p) => esc(str(p, 'detail') + ' — ' + str(p, 'message'))).join(' · ')}</small>
              </span></div>`
            : insight('good', 'المسوّدة صالحة للنشر',
                'لا فجوة ولا تداخل، وكل باقةٍ مسعَّرة في كل شريحة.'))
        : '')

      + draftPanel(isDraft, draft, str(version, 'id'), status)

      /* ٤ · النسخ */
      + `<div class="box" style="margin-top:12px">
        <h3>النسخ</h3>
        <p class="muted" style="font-size:11px;margin:0 0 10px">
          المنشورة والمتقاعدة لا تُعدَّل: حُسب بها مالٌ فعلاً، وتعديلها يُعيد
          كتابة ما مضى.</p>
        ${versions.map((v) => {
          const s = str(v, 'status');
          const here = str(v, 'id') === str(version, 'id');
          return `<a class="minirow" style="text-decoration:none;color:inherit"
            href="${esc(href('/master/commission-schemes', { version: str(v, 'id') }))}">
            <span>${chip(STATUS[s]?.label || s, STATUS[s]?.tone || 'neutral')}
              <b>النسخة ${count(num(v, 'version'))}</b>
              ${here ? '<span class="muted">— المعروضة</span>' : ''}</span>
            <span class="muted">${esc(str(v, 'published_at').slice(0, 10) || 'لم تُنشر')}</span>
          </a>`;
        }).join('')}
      </div>`;

    wireDraft(view, str(version, 'id'), packages);
  },
};

/* ---- المسوّدة ------------------------------------------------------------- */

function draftPanel(isDraft: boolean, draft: Row | undefined, versionId: string,
                    status: string): string {
  if (!can('commission.configure')) {
    return `<div class="box" style="margin-top:12px">
      <p class="muted">العرض فقط — تغيير قواعد العمولة يحتاج صلاحية
      <code dir="ltr">commission.configure</code>.</p></div>`;
  }

  if (!isDraft) {
    return `<div class="box" style="margin-top:12px" id="draftBox">
      <h3>تغيير القواعد</h3>
      <p class="muted" style="font-size:11px;margin:0 0 10px">
        ${draft
          ? 'توجد مسوّدة قيد التحرير. تُفتح من قائمة النسخ أدناه.'
          : `التغيير يبدأ بنسخةٍ جديدة تُنسخ عن ${status === 'PUBLISHED' ? 'المنشورة' : 'المعروضة'}
             بكل شرائحها وأسعارها، ثم تُعدَّل وتُفحص وتُنشر. والمنشورة تبقى كما هي حتى تُنشر البديلة.`}</p>
      ${draft
        ? `<a class="btn gold" href="${esc(href('/master/commission-schemes', { version: str(draft, 'id') }))}">افتح المسوّدة</a>`
        : `<div class="toolbar">
            <input class="search" id="dfNotes" placeholder="سبب التغيير (اختياري)" aria-label="ملاحظة">
            <button class="btn gold" id="dfCreate">ابدأ مسوّدة</button>
          </div>`}
      <div id="dfResult"></div>
    </div>`;
  }

  return `<div class="box" style="margin-top:12px" id="draftBox" data-version="${esc(versionId)}">
    <h3>تحرير المسوّدة</h3>
    <p class="muted" style="font-size:11px;margin:0 0 10px">
      اختر «حرِّر» من الجدول لتعديل حدود شريحة، أو عدِّل سعر باقةٍ فيها.
      ولا شيء من هذا يمسّ النسخة المنشورة.</p>
    <div class="toolbar">
      <span class="muted">الشريحة: <b id="dfTier">—</b></span>
      <input class="search" type="number" id="dfMin" placeholder="من" aria-label="أقلّ عدد">
      <input class="search" type="number" id="dfMax" placeholder="إلى (فارغ = مفتوحة)" aria-label="أكثر عدد">
      <button class="btn" id="dfSaveTier">احفظ المدى</button>
    </div>
    <div class="toolbar" style="margin-top:8px">
      <select class="select" id="dfPkg" aria-label="الباقة"></select>
      <input class="search" type="number" id="dfAmount" placeholder="المبلغ" aria-label="المبلغ">
      <button class="btn" id="dfSaveRate">احفظ السعر</button>
    </div>
    <div class="toolbar" style="margin-top:8px">
      <input class="search" type="date" id="dfFrom" aria-label="تاريخ السريان">
      <button class="btn gold" id="dfPublish">انشر النسخة</button>
    </div>
    <div id="dfResult"></div>
  </div>`;
}

function wireDraft(view: View, versionId: string, packages: string[]): void {
  const box = view.el.querySelector<HTMLElement>('#draftBox');
  if (!box) return;
  const out = box.querySelector<HTMLElement>('#dfResult');
  if (!out) return;

  const create = box.querySelector<HTMLButtonElement>('#dfCreate');
  create?.addEventListener('click', async () => {
    const notes = box.querySelector<HTMLInputElement>('#dfNotes')?.value.trim() || null;
    create.disabled = true;
    out.innerHTML = loading('جارٍ إنشاء المسوّدة…');
    try {
      const res = await rpc<Row>('create_commission_draft', {
        p_request_id: crypto.randomUUID(), p_notes: notes,
      });
      if (!view.live) return;
      out.innerHTML = insight('good', `أُنشئت النسخة ${count(num(res, 'version'))}`,
        'نُسخت الشرائح والأسعار كما هي. المنشورة لم تتغيّر.');
      const id = str(res, 'version_id');
      window.setTimeout(() => {
        if (view.live) window.location.hash =
          href('/master/commission-schemes', { version: id }).slice(1);
      }, 1200);
    } catch (error) {
      if (!view.live) return;
      out.innerHTML = insight('danger', 'لم تُنشأ المسوّدة',
        error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
    } finally {
      create.disabled = false;
    }
  });

  // قائمة الباقات من المخطّط نفسه، لا من قائمةٍ مكتوبة هنا.
  const pkg = box.querySelector<HTMLSelectElement>('#dfPkg');
  if (pkg) {
    pkg.innerHTML = packages.map((p) =>
      `<option value="${esc(p)}">${esc(p)}</option>`).join('');
  }

  let tierId = '';
  const tierLabel = box.querySelector<HTMLElement>('#dfTier');
  const min = box.querySelector<HTMLInputElement>('#dfMin');
  const max = box.querySelector<HTMLInputElement>('#dfMax');

  for (const btn of view.el.querySelectorAll<HTMLButtonElement>('.tier-edit')) {
    btn.addEventListener('click', () => {
      tierId = btn.dataset['id'] || '';
      if (tierLabel) tierLabel.textContent = btn.dataset['code'] || '—';
      if (min) min.value = btn.dataset['min'] || '';
      if (max) max.value = btn.dataset['max'] || '';
      out.innerHTML = '';
    });
  }

  const run = async (button: HTMLButtonElement, label: string,
                     call: () => Promise<unknown>, done: string) => {
    if (!tierId) { out.innerHTML = insight('warn', 'اختر شريحةً أولاً'); return; }
    button.disabled = true;
    out.innerHTML = loading(`جارٍ ${label}…`);
    try {
      await call();
      if (!view.live) return;
      out.innerHTML = insight('good', done);
      window.setTimeout(() => { if (view.live) window.location.reload(); }, 1100);
    } catch (error) {
      if (!view.live) return;
      out.innerHTML = insight('danger', `لم يتم ${label}`,
        error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
    } finally {
      button.disabled = false;
    }
  };

  const saveTier = box.querySelector<HTMLButtonElement>('#dfSaveTier');
  saveTier?.addEventListener('click', () => run(saveTier, 'حفظ المدى', () =>
    rpc('update_commission_draft_tier', {
      p_tier_id: tierId,
      p_min_subscribers: Number(min?.value || 0),
      p_max_subscribers: max?.value.trim() ? Number(max.value) : null,
      p_request_id: crypto.randomUUID(),
    }), 'حُفظ المدى'));

  const saveRate = box.querySelector<HTMLButtonElement>('#dfSaveRate');
  const amount = box.querySelector<HTMLInputElement>('#dfAmount');
  saveRate?.addEventListener('click', () => {
    if (!amount?.value.trim()) { out.innerHTML = insight('warn', 'أدخل المبلغ'); return; }
    return run(saveRate, 'حفظ السعر', () =>
      rpc('update_commission_draft_rate', {
        p_tier_id: tierId,
        p_package_code: pkg?.value || '',
        p_amount: Number(amount.value),
        p_qualifies: true,
        p_request_id: crypto.randomUUID(),
      }), 'حُفظ السعر');
  });

  const publish = box.querySelector<HTMLButtonElement>('#dfPublish');
  publish?.addEventListener('click', async () => {
    const from = box.querySelector<HTMLInputElement>('#dfFrom')?.value || null;
    if (!window.confirm(
      'نشر هذه النسخة؟ تصير هي المرجع الذي يُحسب به المال، ولا تُعدَّل بعدها.')) return;
    publish.disabled = true;
    out.innerHTML = loading('جارٍ النشر…');
    try {
      await rpc('publish_commission_version', {
        p_version_id: versionId,
        p_effective_from: from,
        p_request_id: crypto.randomUUID(),
      });
      if (!view.live) return;
      out.innerHTML = insight('good', 'نُشرت النسخة',
        'صارت المرجع، وما قبلها يبقى كما حُسب به.');
      window.setTimeout(() => { if (view.live) window.location.reload(); }, 1400);
    } catch (error) {
      if (!view.live) return;
      out.innerHTML = insight('danger', 'لم تُنشر النسخة',
        error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
    } finally {
      publish.disabled = false;
    }
  });
}

export const routes: Route[] = [commissionSchemes];
