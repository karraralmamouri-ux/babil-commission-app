/**
 * شاشتا قرار — الملكية المعلّقة، والمشتركون بلا مرحلة.
 *
 * كلتاهما تتبع النمط نفسه: المشكلة، ثم الأثر المالي، ثم الأدلّة، ثم القرار
 * المطلوب. ولا تقترح أيٌّ منهما جواباً.
 *
 * والفرق بين شاشةٍ تعرض قراراً وشاشةٍ تعرض جدولاً هو أن الأولى تقول للمشغّل
 * ما الذي يتوقّف على حكمه. رقمٌ بلا هذا السياق يبقى رقماً يُتجاوَز.
 */

import type { Route } from '../../app/router';
import { href } from '../../app/router';
import { rpc } from '../../services/api';
import { money, count } from '../../domain/money';
import { dateTime } from '../../domain/time';
import { esc, loading, empty, errorState, pageHeader, kpiRow, chip } from '../../components/ui';

type Row = Record<string, unknown>;
const num = (r: Row, k: string) => Number(r[k] || 0);
const str = (r: Row, k: string) => String(r[k] ?? '');

/* ---- ملكية تحتاج حسم ------------------------------------------------------ */

export const ownershipDecisions: Route = {
  pattern: '/work/ownership',
  capability: 'commission.view',
  title: 'ملكية تحتاج حسم',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'مركز العمل', href: href('/work') },
    { label: 'ملكية تحتاج حسم' },
  ],
  async render(view) {
    view.innerHTML = loading('جارٍ قراءة الملكية المعلّقة…');

    let doc: Row;
    try {
      doc = await rpc<Row>('unresolved_ownership_decisions', {});
    } catch (error) {
      if (!view.live) return;
      view.innerHTML = pageHeader('ملكية تحتاج حسم')
        + errorState(error instanceof Error ? error.message : 'تعذّر التحميل', 'location.reload()');
      return;
    }
    if (!view.live) return;

    const groups = (doc['groups'] || []) as Row[];
    const total = num(doc, 'total_amount');

    if (!groups.length) {
      view.innerHTML = pageHeader('ملكية تحتاج حسم')
        + empty('كل المبالغ منسوبة إلى وكلاء معروفين', 'لا قرار معلّق هنا');
      return;
    }

    view.innerHTML = pageHeader('ملكية تحتاج حسم',
      'تفعيلات محسوبة في إجمالي الدورة ولا وكيل فعّال لها')

      /* المشكلة والأثر المالي */
      + `<div class="insight danger" style="margin-top:4px"><span class="insight-dot"></span><span>
          <b>المشكلة</b>
          <small>هذه التفعيلات دخلت حساب الدورة — المبلغ محسوب — ولم تُنسب إلى
            وكيل، لأن اسم المصدر لم يُحسم إلى عائدية. فمجموع الوكلاء يقلّ عن
            إجمالي الدورة بهذا المقدار، ولا يظهر السبب في أي شاشة.</small>
        </span></div>`

      + kpiRow([
        { label: 'الأثر المالي', value: money(total), tone: 'red',
          sub: 'محسوب وغير منسوب' },
        { label: 'قرارات', value: count(groups.length), tone: 'primary',
          sub: 'وحدة القرار: اسم المصدر' },
        { label: 'تفعيلات',
          value: count(groups.reduce((a, g) => a + num(g, 'events'), 0)), tone: 'blue' },
        { label: 'مشتركون',
          value: count(groups.reduce((a, g) => a + num(g, 'subscribers'), 0)), tone: 'gold' },
      ])

      + groups.map((g) => {
        const similar = (g['similar_source_names'] || []) as string[];
        const events = (g['events_detail'] || []) as Row[];
        return `<div class="box" style="margin-top:12px">
          <h3>اسم المصدر: <span dir="ltr">${esc(str(g, 'source_name'))}</span></h3>

          <div class="minirow">
            <span>الأثر المالي</span>
            <b class="money">${money(num(g, 'amount'))}</b></div>
          <div class="minirow">
            <span>التفعيلات · المشتركون</span>
            <b>${count(num(g, 'events'))} · ${count(num(g, 'subscribers'))}</b></div>

          <h3 style="margin-top:14px">الأدلّة</h3>
          <div class="minirow">
            <span>اسم بديل مسجَّل</span>
            <b>${str(g, 'alias_resolution')
              ? `${esc(str(g, 'alias_resolution'))}${str(g, 'alias_agent')
                  ? ' — ' + esc(str(g, 'alias_agent')) : ''}`
              : '<span class="muted">لا اسم بديل مسجَّل لهذا الاسم</span>'}</b></div>
          <div class="minirow">
            <span>أسماء مشابهة في المصدر</span>
            <b>${similar.length
              ? similar.map((s) => `<span dir="ltr">${esc(s)}</span>`).join('، ')
              : '<span class="muted">لا شبيه</span>'}</b></div>
          ${similar.length
            ? `<p class="muted" style="font-size:11px;margin:6px 0 0">
                التشابه دليلٌ يُنظر فيه، لا حكم. اسمان متقاربان قد يكونان جهةً
                واحدة وقد لا يكونان — ولا يُحسم ذلك من الإملاء.</p>`
            : ''}

          <h3 style="margin-top:14px">التفعيلات</h3>
          <div style="overflow-x:auto">
          <table class="table"><thead><tr>
            <th>المشترك</th><th>الباقة</th><th>الكابينة</th><th>المنطقة</th>
            <th>الوقت</th><th class="num">المبلغ</th>
          </tr></thead><tbody>
          ${events.map((e) => `<tr>
            <td dir="ltr">${esc(str(e, 'subscriber'))}</td>
            <td dir="ltr">${esc(str(e, 'package'))}</td>
            <td dir="ltr">${esc(str(e, 'fdt'))}</td>
            <td>${esc(str(e, 'zone') === 'new' ? 'جديدة' : 'قديمة')}</td>
            <td dir="ltr">${esc(dateTime(e['event_at']))}</td>
            <td class="num"><span class="money">${money(num(e, 'amount'))}</span></td>
          </tr>`).join('')}
          </tbody></table></div>

          <h3 style="margin-top:14px">القرار المطلوب</h3>
          <p class="muted" style="font-size:11px;margin:0 0 10px">
            حدّد عائدية هذا الاسم: وكيلٌ بعينه، أو تبعية مباشرة للشركة، أو
            يبقى معلّقاً حتى يتوفّر الدليل. والحسم يجري من شاشة الملكية وأسماء
            المصدر، وتُعاد حسبة الدورة بعده فينتقل المبلغ إلى مكانه.</p>
          <div class="actions">
            <a class="btn gold" href="${esc(href('/master/parents',
              { search: str(g, 'source_name') }))}">احسم العائدية</a>
            <a class="btn" href="${esc(href('/commissions'))}">عد إلى نتيجة الدورة</a>
          </div>
        </div>`;
      }).join('');
  },
};

/* ---- تحتاج حسم تاريخي ----------------------------------------------------- */

export const historicalDecisions: Route = {
  pattern: '/work/historical',
  capability: 'installation.view',
  title: 'تحتاج حسم تاريخي',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'مركز العمل', href: href('/work') },
    { label: 'تحتاج حسم تاريخي' },
  ],
  async render(view) {
    view.innerHTML = loading('جارٍ قراءة المشتركين غير المحسومين…');

    let doc: Row;
    try {
      doc = await rpc<Row>('historical_unresolved_subscribers', {});
    } catch (error) {
      if (!view.live) return;
      view.innerHTML = pageHeader('تحتاج حسم تاريخي')
        + errorState(error instanceof Error ? error.message : 'تعذّر التحميل', 'location.reload()');
      return;
    }
    if (!view.live) return;

    const rows = (doc['rows'] || []) as Row[];
    if (!rows.length) {
      view.innerHTML = pageHeader('تحتاج حسم تاريخي')
        + empty('كل المشتركين يقعون في مرحلة معروفة');
      return;
    }

    view.innerHTML = pageHeader('تحتاج حسم تاريخي',
      'مشتركون لا يقعون في P1..P4 ولا DONE')

      + `<div class="insight warn" style="margin-top:4px"><span class="insight-dot"></span><span>
          <b>المشكلة</b>
          <small>هؤلاء لا يظهرون في أي مجموع مرحلة، فيغيبون عن الشاشة وهم
            قائمون في الجدول. مجموع المراحل ${count(5688)} والمشتركون
            ${count(5693)} — والفرق هؤلاء. لا يُصنَّفون بلا دليل.</small>
        </span></div>`

      + kpiRow([
        { label: 'مشتركون بلا مرحلة', value: count(rows.length), tone: 'gold',
          sub: 'وحدة القرار: المشترك' },
      ])

      + rows.map((r) => {
        const history = (r['history'] || []) as Row[];
        const warnings = (r['warnings'] || []) as string[];
        return `<div class="box" style="margin-top:12px">
          <h3><span dir="ltr">${esc(str(r, 'subscriber_id'))}</span></h3>
          <div class="minirow"><span>الوكيل في المصدر</span>
            <b>${esc(str(r, 'reseller') || '—')}</b></div>
          <div class="minirow"><span>المتبقّي · المستلَم · الإجمالي</span>
            <b>${money(num(r, 'remaining'))} · ${money(num(r, 'received_total'))}
               · ${money(num(r, 'total_amount'))}</b></div>
          <div class="minirow"><span>المرحلة المحسوبة</span>
            <b>${str(r, 'current_stage')
              ? esc(str(r, 'current_stage'))
              : '<span class="muted">لا مرحلة — وهذا سبب وجوده هنا</span>'}</b></div>
          <div class="minirow"><span>الحسم · مؤهَّل للدفع</span>
            <b>${esc(str(r, 'resolution') || '—')} ·
               ${r['payment_eligible'] === true ? 'نعم' : 'لا'}</b></div>
          ${warnings.length
            ? `<div class="minirow"><span>ملاحظات المصدر</span>
                <b>${warnings.map((w) => chip(esc(w), 'warning')).join(' ')}</b></div>`
            : ''}

          <h3 style="margin-top:12px">سجلّ الدفع التاريخي</h3>
          <div class="minirow"><span>صفوف · مجموع</span>
            <b>${count(num(r, 'history_rows'))} · ${money(num(r, 'history_paid'))}</b></div>
          ${history.length
            ? history.map((h) => `<div class="minirow">
                <span>${esc(str(h, 'stage'))}</span>
                <b>${money(num(h, 'amount'))}
                   <span class="muted" dir="ltr">${esc(dateTime(h['paid_at']))}</span></b>
              </div>`).join('')
            : '<p class="muted" style="font-size:11px">لا سجلّ دفع تاريخي</p>'}

          <h3 style="margin-top:12px">القرار المطلوب</h3>
          <p class="muted" style="font-size:11px;margin:0 0 10px">
            راجع سجلّه ثم قرّر: أهو مكتمل الدفع فيكون DONE، أم بقي عليه مبلغ
            فيقع في مرحلته؟ لا يُصنَّف من رقمٍ ناقص.</p>
          <div class="actions">
            <a class="btn" href="${esc(href(
              `/installation/subscribers/${encodeURIComponent(str(r, 'subscriber_id'))}`))}">افتح ملفّ المشترك</a>
          </div>
        </div>`;
      }).join('');
  },
};

export const routes: Route[] = [ownershipDecisions, historicalDecisions];
