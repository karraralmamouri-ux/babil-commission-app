/**
 * نقل العائدية — من تاريخٍ فصاعداً.
 *
 * الشاشة تُظهر أثر النقل قبل وقوعه: كم حدثاً يبقى عند المالك السابق، وكم
 * ينتقل، وهل هناك تنصيبٌ جارٍ يجعل استحقاق المراحل الباقية سؤالاً تجارياً.
 *
 * وما لا تفعله الشاشة مذكورٌ فيها صراحةً: لا تحرّك أجور تنصيب، ولا تكتب
 * داخل دورة محسومة، ولا تغيّر اسم الأب. الأولان يرفضهما الخادم أيضاً؛
 * والقول هنا لئلّا يُكتشف الرفض بعد الضغط.
 */

import type { View } from '../../app/router';
import { rpc, can, ApiError } from '../../services/api';
import { money, count } from '../../domain/money';
import { esc, loading, chip } from '../../components/ui';

type Row = Record<string, unknown>;
const num = (r: Row, k: string) => Number(r[k] || 0);
const str = (r: Row, k: string) => String(r[k] ?? '');

const OWNERSHIP: Array<{ value: string; label: string }> = [
  { value: 'RESELLER', label: 'وكيل' },
  { value: 'DIRECT_COMPANY', label: 'الشركة' },
  { value: 'NEEDS_REVIEW', label: 'تحتاج مراجعة' },
];

const LABEL: Record<string, string> = Object.fromEntries(OWNERSHIP.map((o) => [o.value, o.label]));

/** يُدرَج في التبويب، ثم يُملأ بعد قراءة المعاينة. */
export function transferPanel(): string {
  return `<div id="transferHost">${loading('جارٍ قراءة العائدية…')}</div>`;
}

function todayLocal(): string {
  // حقل التاريخ يريد YYYY-MM-DD بالتوقيت المحلي، وtoISOString يعطي UTC.
  const d = new Date();
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

export async function wireTransfer(view: View, subscriberKey: string): Promise<void> {
  const host = view.el.querySelector<HTMLElement>('#transferHost');
  if (!host) return;

  const draw = async (target: string, agentId: string, from: string) => {
    let preview: Row | null = null;
    let error = '';
    try {
      preview = await rpc<Row>('transfer_preview', {
        p_username_key: subscriberKey,
        p_ownership: target || 'NEEDS_REVIEW',
        p_agent_id: target === 'RESELLER' && agentId ? agentId : null,
        p_effective_from: from ? new Date(`${from}T00:00:00`).toISOString() : null,
      });
    } catch (e) {
      error = e instanceof ApiError ? e.message : 'تعذّرت قراءة المعاينة';
    }
    if (!view.live) return;
    host.innerHTML = render(preview, target, agentId, from, error);
    await wire(target);
  };

  const render = (p: Row | null, target: string, agentId: string, from: string, error: string): string => {
    const cur = (p?.['current'] || null) as Row | null;
    const inst = (p?.['installation'] || null) as Row | null;
    const blocked = (p?.['blocked_by'] || null) as Row | null;
    const decision = (p?.['business_decision'] || null) as Row | null;
    const editable = can('subscriber.correct_attribution');

    return `
      <div class="grid2">
        <div class="box">
          <h3>العائدية الحالية</h3>
          <div class="minirow"><span class="muted">التصنيف</span>
            <b>${cur ? esc(LABEL[str(cur, 'ownership_type')] || str(cur, 'ownership_type')) : 'لم تُسجَّل بعد'}</b></div>
          <div class="minirow"><span class="muted">أحداث قبل التاريخ</span>
            <b>${count(num(p || {}, 'events_before'))}</b></div>
          <div class="minirow"><span class="muted">أحداث بعده</span>
            <b>${count(num(p || {}, 'events_after'))}</b></div>
          <p class="muted" style="font-size:11px;margin-top:8px">
            ما قبل التاريخ يبقى للمالك السابق. النقل لا يُعيد كتابة الماضي.</p>
        </div>
        <div class="box">
          <h3>أجور التنصيب</h3>
          ${inst
            ? `<div class="minirow"><span class="muted">المرحلة</span><b>${esc(str(inst, 'stage') || '—')}</b></div>
               <div class="minirow"><span class="muted">الوكيل وقت التسجيل</span>
                 <b>${esc(str(inst, 'enrolled_agent_name') || '—')}</b></div>
               <div class="minirow"><span class="muted">المقبوض حتى الآن</span>
                 <b class="money">${money(num(inst, 'paid_so_far'))}</b></div>
               <div class="insight warn" style="margin-top:8px"><span class="insight-dot"></span><span>
                 <b>لا تنتقل مع العائدية</b>
                 <small>من نفّذ المراحل يبقى صاحبها. النقل يخصّ العمولة وحدها.</small></span></div>`
            : '<p class="muted">لا تسجيل تنصيب لهذا المشترك</p>'}
        </div>
      </div>

      ${blocked ? `<div class="insight danger" style="margin-top:12px"><span class="insight-dot"></span><span>
          <b>لا يمكن النقل إلى هذا التاريخ</b>
          <small>يقع داخل دورة ${esc(str(blocked, 'cycle_name'))} وحالتها
            ${esc(str(blocked, 'cycle_status'))}. المال المحسوم لا يُعاد حسابه.</small>
        </span></div>` : ''}

      ${decision ? `<div class="insight warn" style="margin-top:12px"><span class="insight-dot"></span><span>
          <b>قرار تجاري مطلوب — NEEDS_BUSINESS_DECISION</b>
          <small>${esc(str(decision, 'question'))}
            المرحلة ${esc(str(decision, 'stage') || '—')}،
            والمقبوض ${money(num(decision, 'paid_so_far'))} لـ${esc(str(decision, 'enrolled_agent_name') || '—')}.
            النظام لا يختار — يُسجَّل السؤال ويُحسم إدارياً.</small>
        </span></div>` : ''}

      ${error ? `<div class="insight danger" style="margin-top:12px"><span class="insight-dot"></span><span>
          <b>تعذّرت المعاينة</b><small>${esc(error)}</small></span></div>` : ''}

      <div class="box" style="margin-top:12px">
        <h3>نقل العائدية</h3>
        ${editable ? `
          <div class="toolbar">
            <select class="select" id="trTarget" aria-label="العائدية الجديدة">
              <option value="">— العائدية الجديدة —</option>
              ${OWNERSHIP.map((o) => `<option value="${esc(o.value)}"${o.value === target ? ' selected' : ''}>${esc(o.label)}</option>`).join('')}
            </select>
            <select class="select" id="trAgent" aria-label="الوكيل"
              style="${target === 'RESELLER' ? '' : 'display:none'}">
              <option value="">— جارٍ تحميل الوكلاء —</option>
            </select>
            <input class="search" type="date" id="trFrom" aria-label="ساري من"
              value="${esc(from || todayLocal())}">
            <input class="search" id="trReason" placeholder="سبب النقل (إلزامي)" aria-label="سبب النقل">
            <button class="btn gold" id="trApply"${blocked ? ' disabled' : ''}>نفّذ النقل</button>
          </div>
          <p class="muted" style="font-size:11px;margin-top:6px">
            التاريخ حدٌّ: ما قبله للمالك السابق وما بعده للجديد. اسم الأب لا يتغيّر.</p>
          <div id="trResult"></div>`
        : `<p class="muted">تحتاج صلاحية <code>subscriber.correct_attribution</code> لنقل العائدية.</p>`}
      </div>`;
  };

  const wire = async (target: string) => {
    const t = view.el.querySelector<HTMLSelectElement>('#trTarget');
    const agent = view.el.querySelector<HTMLSelectElement>('#trAgent');
    const from = view.el.querySelector<HTMLInputElement>('#trFrom');
    const reason = view.el.querySelector<HTMLInputElement>('#trReason');
    const apply = view.el.querySelector<HTMLButtonElement>('#trApply');
    const out = view.el.querySelector<HTMLElement>('#trResult');
    if (!t || !agent || !from || !apply || !out) return;

    if (target === 'RESELLER') {
      try {
        const list = await rpc<Row[]>('list_agents_for_pick', {});
        if (!view.live) return;
        agent.innerHTML = '<option value="">— اختر الوكيل —</option>'
          + (list || []).map((a) => `<option value="${esc(str(a, 'id'))}">${esc(str(a, 'official_name'))}</option>`).join('');
      } catch {
        agent.innerHTML = '<option value="">تعذّر تحميل الوكلاء</option>';
      }
    }

    // كل تغيير يُعيد قراءة المعاينة: الأثر يُرى قبل التنفيذ لا بعده.
    const reread = () => void draw(t.value, agent.value, from.value);
    t.addEventListener('change', reread);
    agent.addEventListener('change', reread);
    from.addEventListener('change', reread);

    apply.addEventListener('click', async () => {
      if (!t.value) {
        out.innerHTML = insight('warn', 'اختر العائدية الجديدة');
        return;
      }
      if (t.value === 'RESELLER' && !agent.value) {
        out.innerHTML = insight('warn', 'النقل إلى وكيل يحتاج وكيلاً محدَّداً');
        return;
      }
      const why = reason?.value.trim() || '';
      if (!why) {
        out.innerHTML = insight('warn', 'النقل يحتاج سبباً مكتوباً — يُحفظ في التدقيق');
        return;
      }

      apply.disabled = true;
      out.innerHTML = loading('جارٍ تنفيذ النقل…');
      try {
        const result = await rpc<Row>('transfer_subscriber', {
          p_username_key: subscriberKey,
          p_ownership: t.value,
          p_agent_id: t.value === 'RESELLER' ? agent.value : null,
          p_effective_from: new Date(`${from.value}T00:00:00`).toISOString(),
          p_company_parent: null,
          p_reason: why,
          p_request_id: crypto.randomUUID(),
        });
        if (!view.live) return;
        const pending = (result?.['business_decision'] || null) as Row | null;
        out.innerHTML = insight('good',
          result?.['idempotent'] === true ? 'هذا النقل مسجَّل مسبقاً' : 'نُفِّذ النقل',
          pending
            ? 'وبقي قرار تجاري معلّق حول مراحل التنصيب — يظهر في مركز العمل.'
            : 'أجور التنصيب لم تتحرّك.');
        window.setTimeout(() => { if (view.live) void draw('', '', from.value); }, 1200);
      } catch (error) {
        if (!view.live) return;
        out.innerHTML = insight('danger', 'لم يُنفَّذ النقل',
          error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
      } finally {
        apply.disabled = false;
      }
    });
  };

  await draw('', '', todayLocal());
}

function insight(tone: 'good' | 'warn' | 'danger', title: string, detail = ''): string {
  return `<div class="insight ${tone}" style="margin-top:10px"><span class="insight-dot"></span><span>
    <b>${esc(title)}</b>${detail ? `<small>${esc(detail)}</small>` : ''}</span></div>`;
}

/** شارة العائدية للاستعمال في رؤوس الشاشات. */
export function ownershipBadge(type: string): string {
  const tone: 'info' | 'warning' | 'brand' = type === 'RESELLER' ? 'info'
    : type === 'NEEDS_REVIEW' ? 'warning' : 'brand';
  return chip(LABEL[type] || type || '—', tone);
}
