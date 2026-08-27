/**
 * تصحيح التفعيلات.
 *
 * ثلاث طبقات لا اثنتان: المصدر كما ورد، والتصحيح فوقه، والمحرّك يقرأ
 * الاثنين. ولذلك لا يُعدَّل هنا رقمٌ محسوب ولا صفٌّ مستورَد — يُسجَّل ما
 * استُبعد وما أُضيف، ثم يُعاد الحساب.
 *
 * ولماذا لا يُحرَّر الرقم مباشرةً في الجدول؟ لأن الرقم ناتج: عدد الأحداث،
 * وعدد المشتركين الفريدين، والشريحة المشتقّة منهما، والمبلغ المشتقّ منها.
 * تحريرُ الناتج يترك مدخلاته تقول شيئاً وناتجَها يقول غيره، ولا يبقى بعد
 * شهرٍ ما يُراجَع.
 *
 * والإضافة تلزمها هوية مشترك — لا «زد واحداً». أساس الشريحة عددُ المشتركين
 * الفريدين، فزيادةٌ مجهولة تزيد الأحداث ولا يُعرف أثرها في الشريحة.
 */

import type { Route, View } from '../../app/router';
import { href } from '../../app/router';
import { rpc, envelope, select, can, ApiError } from '../../services/api';
import { count } from '../../domain/money';
import { currentCycleId } from '../../domain/cycle';
import {
  esc, loading, empty, pageHeader, table, pager, kpiRow, chip, type Column,
} from '../../components/ui';

type Row = Record<string, unknown>;
const num = (r: Row, k: string) => Number(r[k] || 0);
const str = (r: Row, k: string) => String(r[k] ?? '');

function insight(tone: 'good' | 'warn' | 'danger', title: string, detail = ''): string {
  return `<div class="insight ${tone}" style="margin-top:10px"><span class="insight-dot"></span><span>
    <b>${esc(title)}</b>${detail ? `<small>${esc(detail)}</small>` : ''}</span></div>`;
}

export const corrections: Route = {
  pattern: '/commissions/corrections',
  capability: 'commission.view',
  title: 'تصحيح التفعيلات',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'عمولات الوكلاء', href: href('/commissions') },
    { label: 'تصحيح التفعيلات' },
  ],
  async render(view, m) {
    const limit = 50;
    const offset = Number(m.query.get('offset') || 0);
    view.innerHTML = loading('جارٍ قراءة التصحيحات…');

    // القائمة للاختيار الصريح، والافتراضي من الخادم: مسوّدةٌ فارغة أحدثُ
    // فترةً كانت تسحب الشاشة إليها فتُعرض تصحيحات دورةٍ لا أحد يقصدها.
    const [list, current]: [Row[], string | null] = await Promise.all([
      select<Row[]>('commission_cycles?select=id,name,status&order=period_start.desc'),
      currentCycleId(),
    ]);
    if (!view.live) return;
    if (!list?.length) { view.innerHTML = empty('لا دورة بعد'); return; }

    const cycleId = m.query.get('cycle') || current || str(list[0] || {}, 'id');
    const cycle = list.find((c) => str(c, 'id') === cycleId) || list[0] || {};

    const args: Record<string, unknown> = {
      p_cycle_id: cycleId, p_limit: limit, p_offset: offset,
    };
    if (m.query.get('scope_type')) args['p_scope_type'] = m.query.get('scope_type');
    if (m.query.get('scope_id')) args['p_scope_id'] = m.query.get('scope_id');

    if (view.signal.aborted) return;
    const raw = await rpc<Row>('page_activation_corrections', args);
    if (!view.live) return;
    const page = envelope<Row>(raw);

    // إجماليان خادميّان على كامل المجموعة المُرشَّحة، لا على صفحة الخمسين
    // الحالية — وإلا اختلف الرقم المعروض بتغيّر حجم الصفحة أو الإزاحة.
    const excluded = num(raw, 'active_exclusions');
    const added = num(raw, 'active_additions');
    const locked = ['FINALIZED', 'PARTIALLY_PAID', 'PAID', 'CLOSED']
      .includes(str(cycle, 'status'));

    const columns: Array<Column<Row>> = [
      { key: 'type', label: 'النوع', cell: (r) =>
        str(r, 'correction_type') === 'EXCLUDE'
          ? chip('استبعاد', 'critical') : chip('إضافة', 'success') },
      { key: 'what', label: 'المقصود', cell: (r) =>
        str(r, 'correction_type') === 'EXCLUDE'
          ? `<span dir="ltr">${esc(str(r, 'source_event_id'))}</span>
             <div class="muted" dir="ltr">${esc(str(r, 'subscriber'))}</div>`
          : `<span dir="ltr">${esc(str(r, 'subscriber_username'))}</span>
             <div class="muted" dir="ltr">${esc(str(r, 'package_code'))}
               · ${esc(str(r, 'event_at').replace('T', ' ').slice(0, 16))}</div>` },
      { key: 'scope', label: 'النطاق', cell: (r) =>
        `${esc(str(r, 'scope_type') || '—')}${str(r, 'scope_id') ? ':' + esc(str(r, 'scope_id')) : ''}` },
      { key: 'reason', label: 'السبب', cell: (r) => esc(str(r, 'reason')) },
      { key: 'who', label: 'الفاعل', cell: (r) =>
        `<span dir="ltr">${esc(str(r, 'actor_email'))}</span>
         <div class="muted" dir="ltr">${esc(str(r, 'created_at').replace('T', ' ').slice(0, 16))}</div>` },
      { key: 'status', label: 'الحالة', cell: (r) =>
        str(r, 'status') === 'ACTIVE' ? chip('فعّال', 'success')
          : `${chip('مُلغى', 'neutral')}<div class="muted">${esc(str(r, 'revoke_reason'))}</div>` },
      { key: 'act', label: '', cell: (r) =>
        can('commission.manage_cycle') && str(r, 'status') === 'ACTIVE' && !locked
          ? `<button class="smallbtn corr-revoke" data-id="${esc(str(r, 'id'))}">ألغِ</button>`
          : '' },
    ];

    view.innerHTML = pageHeader('تصحيح التفعيلات',
      `${esc(str(cycle, 'name'))} — المصدر لا يُمسّ، والتصحيح يُسجَّل فوقه`,
      chip(str(cycle, 'status'), locked ? 'neutral' : 'info'))

      + kpiRow([
        { label: 'استبعادات فعّالة', value: count(excluded),
          tone: excluded ? 'red' : 'green', sub: 'أحداث لا تُحتسب' },
        { label: 'إضافات فعّالة', value: count(added),
          tone: added ? 'gold' : 'green', sub: 'أحداث مُتحقَّق منها' },
        { label: 'كل التصحيحات', value: count(page.total), tone: 'primary' },
      ])

      + (locked
        ? insight('warn', 'هذه الدورة مُقفلة على التصحيح',
            `حالتها ${str(cycle, 'status')} — ما حُسب به مالٌ نهائيّ لا يُصحَّح هنا.`)
        : '')

      + `<div class="insight warn" style="margin-top:12px"><span class="insight-dot"></span><span>
          <b>التصحيح لا يُغيّر الملفّ المستورَد</b>
          <small>صفّ الملفّ يبقى كما ورد. التصحيح طبقةٌ فوقه تُقرأ عند كل حساب،
            فيبقى الفرق بين ما وصل وما اعتُمد مرئياً ومُدقَّقاً.</small></span></div>`

      + (locked ? '' : correctionPanel(cycleId, m.query.get('exclude'), m.query.get('fdt')))

      + (page.rows.length ? table(columns, page.rows) : empty('لا تصحيحات في هذه الدورة'))
      + pager(page.total, limit, offset, '/commissions/corrections', m.query);

    wireCorrections(view, cycleId);
  },
};

function correctionPanel(cycleId: string, presetEvent: string | null,
                         presetFdt: string | null): string {
  if (!can('commission.manage_cycle')) {
    return `<div class="box" style="margin-top:12px">
      <p class="muted">العرض فقط — التصحيح يحتاج صلاحية
      <code dir="ltr">commission.manage_cycle</code>.</p></div>`;
  }
  return `<div class="box" style="margin-top:12px" id="corrBox" data-cycle="${esc(cycleId)}">
    <h3>استبعد حدثاً</h3>
    <p class="muted" style="font-size:11px;margin:0 0 10px">
      يُشار إلى الحدث بعينه، لا إلى عددٍ يُطرح: «انقص واحداً» لا يُبقي أثراً
      يُراجَع. ومعرّف الحدث يُنسخ من
      <a href="${esc(href('/master/mapping'))}">أحداث الكابينة</a>.</p>
    <div class="toolbar">
      <input class="search" id="exEvent" placeholder="معرّف الحدث" aria-label="معرّف الحدث"
        dir="ltr" value="${esc(presetEvent || '')}">
      <input class="search" id="exReason" placeholder="السبب (إلزامي)" aria-label="سبب الاستبعاد">
      <button class="btn gold" id="exApply">استبعد</button>
    </div>
    <div id="exResult"></div>

    <h3 style="margin-top:16px">أضِف تفعيلاً مُتحقَّقاً منه</h3>
    <p class="muted" style="font-size:11px;margin:0 0 10px">
      المشترك إلزامي: أساس الشريحة عددُ المشتركين الفريدين، فإضافةٌ بلا مشترك
      تزيد الأحداث ولا يُعرف أثرها في الشريحة. والوقت يجب أن يقع داخل نافذة
      الدورة — الخادم يرفض ما عداه.</p>
    <div class="toolbar">
      <input class="search" id="adUser" placeholder="اسم المشترك" aria-label="اسم المشترك" dir="ltr">
      <select class="select" id="adPkg" aria-label="الباقة">
        <option value="P-35000">P-35000</option>
        <option value="P-45000">P-45000</option>
        <option value="P-65000">P-65000</option>
      </select>
      <input class="search" type="datetime-local" id="adAt" aria-label="وقت التفعيل">
      <input class="search" id="adFdt" placeholder="الكابينة" aria-label="الكابينة" dir="ltr"
        value="${esc(presetFdt || '')}">
      <input class="search" id="adParent" placeholder="الأب (إن لزم)" aria-label="الأب" dir="ltr">
      <input class="search" id="adReason" placeholder="السبب (إلزامي)" aria-label="سبب الإضافة">
      <button class="btn gold" id="adApply">أضِف</button>
    </div>
    <div id="adResult"></div>
  </div>`;
}

function wireCorrections(view: View, cycleId: string): void {
  const box = view.el.querySelector<HTMLElement>('#corrBox');

  // إعادة الحساب بعد كل تصحيح: الرقم المعروض يجب أن يتبع التصحيح فوراً،
  // وإلا قرأ المشغّل رقماً قديماً وظنّ أن التصحيح لم يقع.
  const recalc = async () => rpc('calculate_commission_cycle', {
    p_cycle_id: cycleId, p_finalize: false, p_request_id: crypto.randomUUID(),
  });

  if (box) {
    const exEvent = box.querySelector<HTMLInputElement>('#exEvent');
    const exReason = box.querySelector<HTMLInputElement>('#exReason');
    const exApply = box.querySelector<HTMLButtonElement>('#exApply');
    const exOut = box.querySelector<HTMLElement>('#exResult');

    exApply?.addEventListener('click', async () => {
      if (!exEvent || !exReason || !exOut) return;
      if (!exEvent.value.trim()) { exOut.innerHTML = insight('warn', 'معرّف الحدث إلزامي'); return; }
      if (!exReason.value.trim()) {
        exOut.innerHTML = insight('warn', 'السبب إلزامي',
          'استبعادٌ بلا سبب لا يُفهم بعد شهر');
        return;
      }
      if (!window.confirm(
        `استبعاد الحدث ${exEvent.value.trim()} من حساب هذه الدورة؟ الملفّ المستورَد لا يتغيّر.`)) return;
      exApply.disabled = true;
      exOut.innerHTML = loading('جارٍ الاستبعاد وإعادة الحساب…');
      try {
        const res = await rpc<Row>('exclude_activation_event', {
          p_cycle_id: cycleId,
          p_source_event_id: exEvent.value.trim(),
          p_reason: exReason.value.trim(),
          p_request_id: crypto.randomUUID(),
        });
        await recalc();
        if (!view.live) return;
        exOut.innerHTML = insight('good', 'استُبعد الحدث وأُعيد الحساب',
          `المشترك ${str(res, 'subscriber_key')} · الباقة ${str(res, 'package_code')}`);
        window.setTimeout(() => { if (view.live) window.location.reload(); }, 1500);
      } catch (error) {
        if (!view.live) return;
        exOut.innerHTML = insight('danger', 'لم يُستبعد الحدث',
          error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
      } finally {
        exApply.disabled = false;
      }
    });

    const adApply = box.querySelector<HTMLButtonElement>('#adApply');
    const adOut = box.querySelector<HTMLElement>('#adResult');
    adApply?.addEventListener('click', async () => {
      if (!adOut) return;
      const user = box.querySelector<HTMLInputElement>('#adUser')?.value.trim() || '';
      const pkg = box.querySelector<HTMLSelectElement>('#adPkg')?.value || '';
      const at = box.querySelector<HTMLInputElement>('#adAt')?.value || '';
      const fdt = box.querySelector<HTMLInputElement>('#adFdt')?.value.trim() || '';
      const parent = box.querySelector<HTMLInputElement>('#adParent')?.value.trim() || '';
      const reason = box.querySelector<HTMLInputElement>('#adReason')?.value.trim() || '';

      if (!user) {
        adOut.innerHTML = insight('warn', 'المشترك إلزامي',
          'الشريحة تُحسب بعدد المشتركين الفريدين — لا تُقبل زيادة مجهولة');
        return;
      }
      if (!at) { adOut.innerHTML = insight('warn', 'وقت التفعيل إلزامي'); return; }
      if (!fdt) { adOut.innerHTML = insight('warn', 'الكابينة إلزامية'); return; }
      if (!reason) { adOut.innerHTML = insight('warn', 'السبب إلزامي'); return; }
      if (!window.confirm(
        `إضافة تفعيل للمشترك ${user} على الكابينة ${fdt}؟ يدخل حساب هذه الدورة.`)) return;

      adApply.disabled = true;
      adOut.innerHTML = loading('جارٍ الإضافة وإعادة الحساب…');
      try {
        await rpc<Row>('add_activation_correction', {
          p_cycle_id: cycleId,
          p_subscriber_username: user,
          p_package_code: pkg,
          p_event_at: new Date(at).toISOString(),
          p_fdt_code: fdt,
          p_raw_parent: parent || null,
          p_reason: reason,
          p_request_id: crypto.randomUUID(),
        });
        await recalc();
        if (!view.live) return;
        adOut.innerHTML = insight('good', 'أُضيف التفعيل وأُعيد الحساب');
        window.setTimeout(() => { if (view.live) window.location.reload(); }, 1500);
      } catch (error) {
        if (!view.live) return;
        adOut.innerHTML = insight('danger', 'لم يُضَف التفعيل',
          error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
      } finally {
        adApply.disabled = false;
      }
    });
  }

  for (const btn of view.el.querySelectorAll<HTMLButtonElement>('.corr-revoke')) {
    btn.addEventListener('click', async () => {
      const reason = window.prompt('سبب الإلغاء (يُسجَّل في التدقيق):');
      if (!reason || !reason.trim()) return;
      btn.disabled = true;
      try {
        await rpc('revoke_activation_correction', {
          p_correction_id: btn.dataset['id'],
          p_reason: reason.trim(),
          p_request_id: crypto.randomUUID(),
        });
        await recalc();
        if (view.live) window.location.reload();
      } catch (error) {
        btn.disabled = false;
        window.alert(error instanceof ApiError ? error.message : 'تعذّر الإلغاء');
      }
    });
  }
}

export const routes: Route[] = [corrections];
