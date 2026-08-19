/**
 * الرئيسية — النظرة التنفيذية.
 *
 * تبقى لوحةً، وهذا صحيح. الفرق أنها صارت شاشةَ البداية لا التطبيقَ كلَّه:
 * كل رقم فيها يقود إلى سجلاته.
 */

import type { Route } from '../../app/router';
import { href } from '../../app/router';
import { rpc, select } from '../../services/api';
import { money, count } from '../../domain/money';
import { esc, loading, empty, pageHeader, kpiRow, chip, projectedTag } from '../../components/ui';

type Row = Record<string, unknown>;
const num = (r: Row, k: string) => Number(r[k] || 0);

const FINAL = new Set(['FINALIZED', 'PARTIALLY_PAID', 'PAID', 'CLOSED']);

export const home: Route = {
  pattern: '/',
  capability: 'report.view',
  title: 'الرئيسية',
  breadcrumb: () => [{ label: 'الرئيسية' }],
  async render(view) {
    view.write(loading('جارٍ تحميل النظرة التنفيذية…'));

    const cycles = (await select<Row[]>('commission_cycles?select=id,name,status&order=period_start.desc&limit=1')) || [];
    const cycle = cycles[0];
    if (!cycle) { view.write(empty('لا توجد دورة بعد', 'ابدأ باستيراد ملف التفعيلات')); return; }

    const cycleId = String(cycle['id']);
    const status = String(cycle['status']);
    const projected = !FINAL.has(status);

    const [summary, impact, company] = await Promise.all([
      rpc<Row>('report_management_summary', { p_cycle_id: cycleId }).catch(() => null),
      rpc<Row[]>('report_commission_exception_impact', { p_cycle_id: cycleId }).catch(() => null),
      rpc<Row>('company_parent_breakdown', {}).catch(() => null),
    ]);

    const g = (summary?.['global'] || {}) as Row;
    const c = (summary?.['commission'] || {}) as Row;
    const t = (c['totals'] || {}) as Row;
    const x = (c['exceptions'] || {}) as Row;
    const inst = (summary?.['installation'] || {}) as Row;

    const blocked = (impact || []).reduce((a, r) => a + num(r, 'indicative_amount'), 0);
    const blockingCount = num(x, 'blocking');

    view.innerHTML = pageHeader('النظرة التنفيذية',
      `${esc(String(cycle['name']))}`,
      projected ? projectedTag() : chip('معتمدة', 'success'))

      // الترتيب مقصود: المستحق أولاً لأنه السؤال الأول، والموقوف آخراً ظاهراً
      // دائماً حتى لا يُقرأ المتبقي على أنه كل ما تبقّى.
      + kpiRow([
        { label: 'إجمالي المستحق', value: money(num(g, 'total_obligations')), tone: 'primary',
          sub: 'عمولات وأجور تنصيب', link: href(`/commissions/cycles/${cycleId}`) },
        { label: 'المدفوع', value: money(num(g, 'total_paid')), tone: 'green',
          link: href('/finance/payment-batches') },
        { label: 'المتبقي', value: money(num(g, 'total_remaining')), tone: 'blue',
          link: href(`/commissions/cycles/${cycleId}/payout`) },
        { label: 'الموقوف / قيد المراجعة',
          value: blocked ? money(blocked) : '—', tone: 'red',
          sub: blockingCount ? `${count(blockingCount)} استثناء حاجب — مبلغ مؤشِّر` : 'لا يُصرف قبل الحسم',
          link: href('/exceptions', { blocking: 'true' }) },
      ])

      + `<div class="grid2">
        <div class="box">
          <h3>◎ عمولات الوكلاء</h3>
          <div class="split-money">
            <div class="part released"><span class="k">محسوب</span>
              <span class="v">${money(num(t, 'gross'))}</span></div>
            <div class="part blocked"><span class="k">موقوف (مؤشِّر)</span>
              <span class="v">${blocked ? money(blocked) : '—'}</span></div>
            <div class="part exposure"><span class="k">النطاقات</span>
              <span class="v">${count(num(t, 'scopes'))}</span></div>
          </div>
          <div class="minirow" style="margin-top:10px">
            <span class="muted">أساس الشريحة — مشتركون فريدون</span>
            <b>${count(num(t, 'unique_activated_subscribers'))}</b></div>
          <div class="minirow"><span class="muted">الأحداث المؤهَّلة</span>
            <b>${count(num(t, 'qualifying_events'))}</b></div>
          <div class="actions" style="margin-top:10px">
            <a class="btn" href="${esc(href(`/commissions/cycles/${cycleId}/scopes`))}">النطاقات</a>
            <a class="btn" href="${esc(href(`/commissions/cycles/${cycleId}/review`))}">المراجعة</a>
          </div>
        </div>

        <div class="box">
          <h3>⚙ أجور التنصيب</h3>
          <div class="split-money">
            <div class="part released"><span class="k">مستحق</span>
              <span class="v">${money(num(inst, 'due'))}</span></div>
            <div class="part blocked"><span class="k">موقوف</span>
              <span class="v">${money(num(inst, 'held'))}</span></div>
            <div class="part exposure"><span class="k">مدفوع تاريخياً</span>
              <span class="v">${money(num(inst, 'historical_paid'))}</span></div>
          </div>
          <div class="minirow" style="margin-top:10px">
            <span class="muted">المشتركون</span><b>${count(num(inst, 'subscribers'))}</b></div>
          <div class="minirow"><span class="muted">التسجيلات</span>
            <b>${count(num(inst, 'enrollments'))}</b></div>
          <div class="actions" style="margin-top:10px">
            <a class="btn" href="${esc(href('/installation/subscribers'))}">سجلّ المشتركين</a>
            <a class="btn" href="${esc(href('/installation/holds'))}">الموقوفون</a>
          </div>
        </div>
      </div>`

      // مشتركو الشركة.
      //
      // بطاقة واحدة بالمجموع، وتحتها تفصيلٌ بأسماء الآباء كما وردت من المصدر:
      // FTTH_Users يظل FTTH_Users، وhrins.office يظل hrins.office. لا أسماء
      // مثبَّتة في الواجهة — أبٌ شركاتيّ جديد يظهر تلقائياً بلا نشر جديد.
      + (() => {
        const parents = Array.isArray(company?.['parents'])
          ? (company['parents'] as Row[]) : [];
        const total = company ? Number(company['total_subscribers'] || 0) : null;
        return `<section style="margin-top:16px">
          <h2 style="font-size:14px;color:var(--navy);margin:0 0 10px">مشتركو الشركة</h2>
          <div class="grid2">
            <a class="card kpi-primary" href="${esc(href('/master/parents', { ownership: 'DIRECT_COMPANY' }))}"
               style="text-decoration:none">
              <div class="label">تابعون للشركة مباشرةً</div>
              <div class="value">${total === null ? '—' : count(total)}</div>
              <div class="sub">مشترك · لا عمولة وكيل ولا مساهمة في شريحة</div>
            </a>
            <div class="box">
              <h3>حسب الأب — بالأسماء الأصلية</h3>
              ${parents.length
                ? parents.map((p) => `<a class="minirow" style="text-decoration:none;color:inherit"
                    href="${esc(href("/master/parents/" + encodeURIComponent(String(p['parent_name'] ?? ''))))}">
                    <span class="num" style="direction:ltr;text-align:left">${esc(String(p['parent_name'] ?? ''))}</span>
                    <b>${count(Number(p['subscribers'] || 0))}</b></a>`).join('')
                : '<p class="muted">لا آباء مصنَّفين للشركة بعد</p>'}
              <div class="muted" style="font-size:10px;margin-top:8px">
                الاسم كما ورد في المصدر. التصنيف لا يُعيد التسمية.</div>
            </div>
          </div>
        </section>`;
      })();

  },
};

export const routes: Route[] = [home];
