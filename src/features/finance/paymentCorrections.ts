/**
 * تصحيح/عكس دفعة مالية مسجَّلة — لوحة عامة تُستدعى من أي شاشة تعرض سطراً
 * مدفوعاً (استحقاق تنصيب، أو مستقبلاً سطر عمولة).
 *
 * لا حساب هنا. `reverse_financial_entry` و`correct_financial_entry` هما
 * مصدر الحقيقة الوحيد: الأصل يبقى سجلّاً في الدفتر ولا يُمسّ أبداً، والعكس
 * أو التصحيح يُضيف حركةً معاكسة أو بديلة فوقه. هذا يختلف عن «تصحيح
 * التفعيلات» في شاشة العمولات — ذاك يُعدّل أيّ حدثٍ يدخل حساب دورة لم
 * تُقفَل بعد؛ هذا يُصحّح دفعةً وقعت فعلاً، عبر الدفتر المالي وحده.
 *
 * الأمان لا يعتمد على هذه الواجهة: الخادم يتحقّق من دور admin مباشرةً في
 * كلا الإجراءين. القدرتان payment.correct وpayment.reverse هنا لإخفاء
 * الزرّ عمّن لن يُسمَح له أصلاً، لا لفرض القرار.
 */

import type { View } from '../../app/router';
import { rpc, can, ApiError } from '../../services/api';
import { esc, loading } from '../../components/ui';
import { money } from '../../domain/money';

type Row = Record<string, unknown>;
export type FinancialDomain = 'installation' | 'commission';

export function canReversePayment(hasCapability: boolean, alreadyPaid: boolean): boolean {
  return hasCapability && alreadyPaid;
}

export function canCorrectPayment(hasCapability: boolean, alreadyPaid: boolean): boolean {
  return hasCapability && alreadyPaid;
}

/** خلية الإجراءات — تُدرَج في عمود جدول أي سطر مدفوع. فارغة بلا قدرة. */
export function correctionActionsCell(
  domain: FinancialDomain,
  sourceId: string,
  alreadyPaid: boolean,
  amount: number,
): string {
  const showCorrect = canCorrectPayment(can('payment.correct'), alreadyPaid);
  const showReverse = canReversePayment(can('payment.reverse'), alreadyPaid);
  if (!showCorrect && !showReverse) return '';
  return `<div class="toolbar" style="gap:4px;flex-wrap:nowrap">
    ${showCorrect ? `<button class="smallbtn correction-action" data-action="correct"
        data-domain="${esc(domain)}" data-id="${esc(sourceId)}" data-amount="${amount}">تصحيح</button>` : ''}
    ${showReverse ? `<button class="smallbtn correction-action" data-action="reverse"
        data-domain="${esc(domain)}" data-id="${esc(sourceId)}" data-amount="${amount}">عكس</button>` : ''}
  </div>`;
}

function insight(tone: 'good' | 'warn' | 'danger', title: string, detail = ''): string {
  return `<div class="insight ${tone}" style="margin-top:10px"><span class="insight-dot"></span><span>
    <b>${esc(title)}</b>${detail ? `<small>${esc(detail)}</small>` : ''}</span></div>`;
}

function confirmPanel(action: 'correct' | 'reverse', amount: number): string {
  const title = action === 'reverse' ? 'عكس الدفعة' : 'تصحيح الدفعة';
  return `<div class="box" id="corrConfirm">
    <h3>${title}</h3>
    <div class="minirow"><span class="muted">المبلغ الأصلي</span><b class="money">${money(amount)}</b></div>
    <p class="muted" style="font-size:11px;margin:10px 0 8px">
      ${action === 'reverse'
        ? 'الأصل يبقى سجلّاً لا يُمسّ. تُضاف حركة معاكسة بنفس المبلغ، فيصير صافي هذه الدفعة صفراً. هذا لا يُلغى تلقائياً — عكسه يحتاج قراراً جديداً لاحقاً.'
        : 'الأصل يبقى سجلّاً لا يُمسّ. تُضاف حركتان فوقه: عكسٌ للأصل ثم بديلٌ بالقيمة الصحيحة، فيصير الصافي هو المصحَّح.'}
      السبب إلزاميٌّ ويُحفظ في التدقيق.</p>
    ${action === 'correct' ? `
    <div class="toolbar">
      <input class="search" id="corrAmount" type="number" min="1" step="1"
        placeholder="المبلغ الصحيح (اتركه فارغاً إن لم يتغيّر)" aria-label="المبلغ الصحيح">
      <input class="search" id="corrAgent" placeholder="الاسم الصحيح (اتركه فارغاً إن لم يتغيّر)"
        aria-label="الاسم الصحيح">
    </div>` : ''}
    <div class="toolbar" style="margin-top:8px">
      <input class="search" id="corrReason" placeholder="السبب (إلزامي)" aria-label="السبب">
      <button class="btn gold" id="corrConfirmBtn">تأكيد ${action === 'reverse' ? 'العكس' : 'التصحيح'}</button>
      <button class="btn" id="corrCancelBtn">إلغاء</button>
    </div>
    <div id="corrResult"></div>
  </div>`;
}

/** حاوية اللوحة — تُدرَج مرّةً أسفل الجدول في الشاشة المستدعية. */
export const CORRECTION_BOX_ID = 'paymentCorrectionBox';
export function correctionBox(): string {
  return `<div id="${CORRECTION_BOX_ID}" style="margin-top:12px"></div>`;
}

/**
 * تُستدعى مرّةً بعد رسم الشاشة. النقر مُفوَّض من جذرها، فيعمل حتى لو أُعيد
 * رسم الجدول لاحقاً (بحث أو تصفّح) دون إعادة توصيل.
 */
export function wireCorrectionActions(view: View): void {
  const container = view.el.querySelector<HTMLElement>(`#${CORRECTION_BOX_ID}`);
  if (!container) return;

  view.el.addEventListener('click', (ev) => {
    const btn = (ev.target as HTMLElement)?.closest<HTMLButtonElement>('.correction-action');
    if (!btn || !view.el.contains(btn)) return;
    const action = (btn.dataset['action'] || 'reverse') as 'correct' | 'reverse';
    const domain = (btn.dataset['domain'] || 'installation') as FinancialDomain;
    const sourceId = btn.dataset['id'] || '';
    const amount = Number(btn.dataset['amount'] || 0);

    container.innerHTML = confirmPanel(action, amount);
    const reason = container.querySelector<HTMLInputElement>('#corrReason');
    const amountInput = container.querySelector<HTMLInputElement>('#corrAmount');
    const agentInput = container.querySelector<HTMLInputElement>('#corrAgent');
    const confirm = container.querySelector<HTMLButtonElement>('#corrConfirmBtn');
    const cancel = container.querySelector<HTMLButtonElement>('#corrCancelBtn');
    const out = container.querySelector<HTMLElement>('#corrResult');
    if (!confirm || !cancel || !out) return;

    cancel.addEventListener('click', () => { container.innerHTML = ''; });

    confirm.addEventListener('click', async () => {
      const why = reason?.value.trim() || '';
      if (!why) { out.innerHTML = insight('warn', 'السبب إلزامي', 'يُحفظ في التدقيق'); return; }

      const correctedAmount = amountInput?.value.trim() ? Number(amountInput.value) : null;
      const correctedAgent = agentInput?.value.trim() || null;
      if (action === 'correct' && correctedAmount === null && !correctedAgent) {
        out.innerHTML = insight('warn', 'لا تغيير مُدخَل',
          'يجب تغيير المبلغ أو الاسم أو كليهما — وإلا فلا شيء يُصحَّح');
        return;
      }

      confirm.disabled = true;
      out.innerHTML = loading(action === 'reverse' ? 'جارٍ العكس…' : 'جارٍ التصحيح…');
      try {
        const result = action === 'reverse'
          ? await rpc<Row>('reverse_financial_entry', {
              p_domain: domain, p_source_id: sourceId, p_reason: why,
              p_request_id: crypto.randomUUID(),
            })
          : await rpc<Row>('correct_financial_entry', {
              p_domain: domain, p_source_id: sourceId, p_reason: why,
              p_corrected_agent_name: correctedAgent,
              p_corrected_amount: correctedAmount,
              p_request_id: crypto.randomUUID(),
            });
        if (!view.live) return;
        out.innerHTML = result?.['replayed'] === true
          ? insight('good', 'مُنفَّذ مسبقاً', 'لم يتغيّر شيء إضافي')
          : insight('good', action === 'reverse' ? 'عُكست الدفعة' : 'صُحِّحت الدفعة',
              'الأصل باقٍ في الدفتر — هذه حركة جديدة فوقه.');
        window.setTimeout(() => { if (view.live) window.location.reload(); }, 1200);
      } catch (error) {
        if (!view.live) return;
        out.innerHTML = insight('danger', action === 'reverse' ? 'لم تُعكس الدفعة' : 'لم تُصحَّح الدفعة',
          error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
      } finally {
        confirm.disabled = false;
      }
    });
  });
}
