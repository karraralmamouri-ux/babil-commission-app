/**
 * الرئيسية — النظرة التنفيذية.
 *
 * تجيب بترتيبٍ مقصود لا ببطاقاتٍ متساوية:
 *
 *   ١ · الوضع المالي     — كم مستحقّ، كم مدفوع، كم موقوف
 *   ٢ · تحتاج إجراء      — ما ينتظر قراراً، بوحدة قراره
 *   ٣ · الدورات الجارية  — أين نقف في العمولة والتنصيب
 *   ٤ · ما يسند ذلك      — مشتركو الشركة
 *
 * البطاقة المتساوية مع كل شيء لا تقول شيئاً: حين يتساوى «المدفوع» بصرياً مع
 * «عدد الآباء» يضيع السؤال الأول. فالمال أولاً وبحجمٍ أكبر، ثم ما يحجبه.
 *
 * وكل رقمٍ يقود إلى سجلّه — الرقم الذي لا يُفتح رقمٌ ميّت.
 */

import type { Route } from '../../app/router';
import { href } from '../../app/router';
import { rpc } from '../../services/api';
import { money, count } from '../../domain/money';
import { readCycleResult } from '../../domain/cycle';
import { esc, loading, pageHeader, chip, projectedTag } from '../../components/ui';

type Row = Record<string, unknown>;
const num = (r: Row, k: string) => Number(r[k] || 0);
const str = (r: Row, k: string) => String(r[k] ?? '');

const FINAL = new Set(['FINALIZED', 'PARTIALLY_PAID', 'PAID', 'CLOSED']);

/** بطاقة مالية — أكبر خطّاً، لأنها تجيب السؤال الأول. */
function moneyCard(label: string, value: string, sub: string, tone: string, link?: string): string {
  const inner = `<div class="label">${esc(label)}</div>
    <div class="value" style="font-size:25px">${value}</div>
    <div class="sub">${esc(sub)}</div>`;
  const cls = `card ${tone}`;
  return link
    ? `<a class="${cls}" href="${esc(link)}" style="text-decoration:none;color:inherit">${inner}</a>`
    : `<div class="${cls}">${inner}</div>`;
}

function sectionTitle(text: string): string {
  return `<h2 style="font-size:12px;color:var(--muted);margin:0 0 10px;
    font-weight:700;letter-spacing:.02em">${esc(text)}</h2>`;
}

export const home: Route = {
  pattern: '/',
  capability: 'report.view',
  title: 'الرئيسية',
  breadcrumb: () => [{ label: 'الرئيسية' }],
  async render(view) {
    view.write(loading('جارٍ تحميل النظرة التنفيذية…'));

    /* أيّ دورة؟ الخادم يقرّر، لا الشاشة.
     *
     * كانت الشاشة تختار بنفسها: `order=period_start.desc&limit=1`. وتلك قاعدة
     * ثانية موازية لقاعدة الخادم — وحين فُتحت مسوّدة آب الفارغة اختارتها
     * القاعدتان معاً فاختفت تموز خلفها وعادت البطاقات أصفاراً. الحكم الآن في
     * مكانٍ واحد: `current_commission_cycle_id()` لا تعدّ المسوّدة التي لم
     * يُشغَّل حسابها دورةً عاملة.
     *
     * ونتيجة الدورة تُقرأ بعقدها الواحد لا بتقرير الإدارة: التقرير كان يُقرأ
     * بمفتاحٍ لا ينتجه، فتصير البطاقات شرطات. */
    const [result, action, pipeline, company] = await Promise.all([
      readCycleResult(),
      rpc<Row>('product_action_center', {}),
      rpc<Row>('installation_cycle_pipeline', {}),
      rpc<Row>('company_parent_breakdown', {}),
    ]);
    if (!view.live) return;

    /* لا دورة عاملة = لم تبدأ، لا صفر.
     *
     * الصفر المعروض في خانة مالٍ يُقرأ مالاً. فحين لا تُرجع القاعدة دورةً
     * عاملة تُقال الحقيقة باسمها، ويبقى ما لا يعتمد على الدورة ظاهراً. */
    const cycleId = result ? result.cycle.id : '';
    const status = result ? result.cycle.status : '';
    const projected = !FINAL.has(status);

    const cycleTotals = result?.totals;
    const unresolvedAmount = result?.unresolved_ownership.amount ?? 0;
    const blockingDecisions = (result?.blockers ?? [])
      .reduce((a, b) => a + b.subscribers, 0);

    const groups = (action?.['groups'] || []) as Row[];
    const open = groups.filter((r) => num(r, 'decisions') > 0)
      .sort((a, b) => (num(b, 'amount') - num(a, 'amount'))
        || (num(b, 'subscribers') - num(a, 'subscribers')));
    const decisions = open.reduce((a, r) => a + num(r, 'decisions'), 0);
    const blockedMoney = open.reduce((a, r) => a + num(r, 'amount'), 0);

    const steps = (pipeline?.['steps'] || []) as Row[];
    const current = steps.filter((s) => str(s, 'state') === 'ACTIVE')
      .sort((a, b) => num(a, 'order') - num(b, 'order'))[0] || null;
    const cand = (pipeline?.['candidate'] || {}) as Row;
    const ready = (pipeline?.['ready'] || {}) as Row;
    const hist = (pipeline?.['historical'] || {}) as Row;

    const parents = (company?.['parents'] || []) as Row[];
    const companyTotal = company ? Number(company['total_subscribers'] || 0) : null;

    view.innerHTML = pageHeader('النظرة التنفيذية',
      result ? esc(result.cycle.name) : 'لا دورة عمولة عاملة',
      result
        ? (projected ? projectedTag() : chip('معتمدة', 'success'))
        : chip('لم تبدأ', 'neutral'))

      /* ١ · العمولات — بالمعنى المالي لا بالحالة التقنية.
       *
       * «إجمالي المستحق» كانت تسميةً خاطئة لدورةٍ قيد المراجعة: الرقم محسوب
       * ولم يُعتمد، وتسميتُه مستحقّاً تجعله يبدو التزاماً نهائياً. الأربعة
       * هنا مراتب: محسوب ← معتمد ← جاهز ← مدفوع، ولكلٍّ منها معنى مختلف. */
      + `<section style="margin-top:4px">
        ${sectionTitle('العمولات')}
        ${!result ? `<div class="insight warn">
            <span class="insight-dot"></span><span>
            <b>لا دورة عمولة عاملة</b>
            <small>لا توجد دورة تجاوزت المسوّدة أو شُغِّل حسابها. المسوّدة الفارغة
              لا تُعرض نتيجةً، ولا يُعرض عنها صفر. افتح دورة أو شغّل حسابها.</small></span>
            <a class="btn gold" style="margin-inline-start:auto"
               href="${esc(href('/commissions'))}">دورات العمولة</a>
          </div>` : `
        <div class="cards cards-4">
          ${moneyCard('عمولات محسوبة', cycleTotals ? money(cycleTotals.gross) : 'لم تُحسب بعد',
            projected ? 'قيد المراجعة — لم تُعتمد' : 'معتمدة',
            'kpi-primary', href('/commissions'))}
          ${moneyCard('معتمد', cycleTotals ? money(cycleTotals.approved) : 'لم تُحسب بعد',
            cycleTotals?.approved ? 'مثبَّت بلقطة' : 'لم يُعتمد بعد', 'blueline',
            href(`/commissions/cycles/${cycleId}/review`))}
          ${moneyCard('جاهز للصرف', cycleTotals ? money(cycleTotals.ready) : 'لم تُحسب بعد',
            cycleTotals?.ready ? 'متحقق خادمياً من قابلية الصرف' : 'لا نطاق جاهز', 'greenline', href('/finance/payment-batches'))}
          ${moneyCard('مدفوع', cycleTotals ? money(cycleTotals.paid) : 'لم تُحسب بعد',
            'مُرحَّل في الدفتر', 'greenline', href('/reports/payments'))}
        </div>
        ${blockingDecisions
          ? `<div class="insight danger" style="margin-top:10px">
              <span class="insight-dot"></span><span>
              <b>${count(blockingDecisions)} اشتراكاً متأثراً عبر الأسباب</b>
              <small>قد يتكرر المشترك بين أكثر من سبب؛ لا يُقرأ هذا الجمع كعدد قرارات فريد.</small></span>
              <a class="btn gold" style="margin-inline-start:auto"
                 href="${esc(href(`/commissions/cycles/${cycleId}/review`))}">راجع دورة العمولة</a>
            </div>`
          : ''}
        ${unresolvedAmount
          ? `<div class="insight warn" style="margin-top:10px">
              <span class="insight-dot"></span><span>
              <b>ملكية تحتاج حسم — ${money(unresolvedAmount)}</b>
              <small>محسوبة في الإجمالي وغير منسوبة إلى وكيل.</small></span>
              <a class="btn" style="margin-inline-start:auto"
                 href="${esc(href('/work/ownership'))}">افتح القرار</a>
            </div>`
          : ''}`}
      </section>`

      /* ٢ · تحتاج إجراء */
      + `<section style="margin-top:20px">
        ${sectionTitle('تحتاج إجراء')}
        <div class="box">
          ${open.length ? `
            <div class="minirow" style="border-bottom:1px solid var(--line);padding-top:0">
              <span><b style="font-size:15px">${count(decisions)} قراراً ينتظر</b>
                <div class="muted" style="font-size:11px">في ${count(open.length)} مجموعة</div></span>
              <a class="btn gold" href="${esc(href('/work'))}">افتح مركز العمل</a>
            </div>
            ${open.slice(0, 4).map((r) => `<a class="minirow"
                style="text-decoration:none;color:inherit" href="${esc(href(str(r, 'path')))}">
                <span><b>${esc(str(r, 'label'))}</b>
                  <span class="muted">— ${esc(str(r, 'unit'))} · ${esc(str(r, 'role'))}</span></span>
                <span><b>${count(num(r, 'decisions'))}</b>
                  ${num(r, 'amount') ? ` <span class="money">${money(num(r, 'amount'))}</span>` : ''}
                </span></a>`).join('')}`
          : '<p class="muted">لا شيء ينتظر قراراً</p>'}
        </div>
      </section>`

      /* ٣ · الدورات الجارية */
      + `<section style="margin-top:20px">
        ${sectionTitle('الدورات الجارية')}
        <div class="grid2">
          <div class="box">
            <h3>◎ عمولات الوكلاء</h3>
            <div class="split-money">
              <div class="part released"><span class="k">محسوب</span>
                <span class="v">${cycleTotals ? money(cycleTotals.gross) : 'لم تُحسب بعد'}</span></div>
              <div class="part blocked"><span class="k">اشتراكات متأثرة عبر الأسباب</span>
                <span class="v">${count(blockingDecisions)}</span></div>
              <div class="part exposure"><span class="k">أساس التير</span>
                <span class="v">${count(result?.volumes.tier_basis ?? 0)}</span></div>
            </div>
            <div class="minirow" style="margin-top:10px">
              <span class="muted">التفعيلات المؤهَّلة</span>
              <b>${result ? count(result.volumes.qualifying_events) : 'لم تُحسب بعد'}</b></div>
            <div class="actions" style="margin-top:10px">
              ${result
                ? `<a class="btn" href="${esc(href(`/commissions/cycles/${cycleId}/scopes`))}">النطاقات</a>`
                : ''}
              <a class="btn" href="${esc(href('/exceptions', { blocking: 'true' }))}">الاستثناءات</a>
            </div>
          </div>

          <div class="box">
            <h3>⊞ أجور التنصيب</h3>
            <div class="split-money">
              <div class="part exposure"><span class="k">مرشّح</span>
                <span class="v">${money(num(cand, 'amount'))}</span></div>
              <div class="part released"><span class="k">جاهز</span>
                <span class="v">${money(num(ready, 'amount'))}</span></div>
              <div class="part blocked"><span class="k">مدفوع تاريخياً</span>
                <span class="v">${money(num(hist, 'paid'))}</span></div>
            </div>
            <div class="minirow" style="margin-top:10px">
              <span class="muted">الخطوة الحالية</span>
              <b>${current ? esc(str(current, 'label')) : '—'}</b></div>
            ${current && str(current, 'blocker')
              ? `<div class="minirow"><span class="muted">ما يحجبها</span>
                 <b>${esc(str(current, 'blocker'))}</b></div>` : ''}
            <div class="actions" style="margin-top:10px">
              <a class="btn" href="${esc(href('/installation/cycle'))}">الدورة</a>
              <a class="btn" href="${esc(href('/installation/ready'))}">جاهز للصرف</a>
            </div>
          </div>
        </div>
      </section>`

      /* ٤ · مشتركو الشركة — بالأسماء الأصلية */
      + `<section style="margin-top:20px">
        ${sectionTitle('مشتركو الشركة')}
        <div class="grid2">
          <a class="card kpi-primary" href="${esc(href('/master/parents', { ownership: 'DIRECT_COMPANY' }))}"
             style="text-decoration:none">
            <div class="label">تابعون للشركة مباشرةً</div>
            <div class="value">${companyTotal === null ? '—' : count(companyTotal)}</div>
            <div class="sub">مشترك · لا عمولة وكيل ولا مساهمة في شريحة</div>
          </a>
          <div class="box">
            <h3>حسب الأب — بالأسماء الأصلية</h3>
            ${parents.length
              ? parents.map((p) => `<a class="minirow" style="text-decoration:none;color:inherit"
                  href="${esc(href('/master/parents/' + encodeURIComponent(String(p['parent_name'] ?? ''))))}">
                  <span class="parent-name" dir="ltr">${esc(String(p['parent_name'] ?? ''))}</span>
                  <b>${count(Number(p['subscribers'] || 0))}</b></a>`).join('')
              : '<p class="muted">لا آباء مصنَّفين للشركة بعد</p>'}
            <div class="muted" style="font-size:10px;margin-top:8px">
              الاسم كما ورد في المصدر. التصنيف لا يُعيد التسمية.</div>
          </div>
        </div>
      </section>`;
  },
};

export const routes: Route[] = [home];
