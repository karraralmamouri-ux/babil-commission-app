/**
 * مركز العمل — ما ينتظر قراراً.
 *
 * المجموعات ليست تصنيفاً جمالياً بل وحدةَ قرار: كل مجموعة يحسمها فعلٌ واحد
 * على كائنٍ واحد. 22,724 صفَّ استثناءٍ تحسمها 119 كابينة؛ عرضُها صفّاً صفّاً
 * يجعل العمل مستحيلاً، وعرضُها بوحدة حسمها يجعله يوماً واحداً.
 *
 * والترتيب بأثقل ما ينتظر لا بأكثره صفوفاً: المال أولاً حين يُعرف، ثم عدد
 * المشتركين المتأثّرين. أبٌ واحد بلا حسم قد يفوق ألف صفٍّ في الأثر.
 */

import type { Route } from '../../app/router';
import { href } from '../../app/router';
import { rpc, select } from '../../services/api';
import { money, count } from '../../domain/money';
import { esc, loading, empty, pageHeader, kpiRow, chip } from '../../components/ui';

type Row = Record<string, unknown>;
const num = (r: Row, k: string) => Number(r[k] || 0);
const str = (r: Row, k: string) => String(r[k] ?? '');

/** الدور المسؤول: يُعرض كي لا تنتظر المجموعةُ من لا يملك حسمها. */
const ROLE_TONE: Record<string, 'info' | 'warning' | 'brand'> = {
  'المحاسبة': 'warning',
  'العمليات': 'info',
  'الإدارة': 'brand',
  'إدارة البيانات المرجعية': 'info',
};

export const workCenter: Route = {
  pattern: '/work',
  capability: 'report.view',
  title: 'تحتاج إجراء',
  breadcrumb: () => [{ label: 'الرئيسية', href: href('/') }, { label: 'تحتاج إجراء' }],
  async render(view) {
    view.write(loading('جارٍ جمع ما ينتظر قراراً…'));

    const [doc, cycles] = await Promise.all([
      rpc<Row>('product_action_center', {}),
      select<Row[]>('commission_cycles?select=id,name,status&order=period_start.desc&limit=1'),
    ]);
    if (!view.live) return;

    const groups = (doc?.['groups'] || []) as Row[];
    const cycle = (cycles || [])[0];

    const open = groups.filter((g) => num(g, 'decisions') > 0);
    const totalDecisions = open.reduce((a, g) => a + num(g, 'decisions'), 0);
    const totalSubscribers = open.reduce((a, g) => a + num(g, 'subscribers'), 0);
    const knownAmount = open.reduce((a, g) => a + num(g, 'amount'), 0);

    // الأثقل أولاً: المال حين يُعرف، ثم المشتركون المتأثّرون.
    const ordered = [...open].sort((a, b) => {
      const byAmount = num(b, 'amount') - num(a, 'amount');
      if (byAmount !== 0) return byAmount;
      return num(b, 'subscribers') - num(a, 'subscribers');
    });
    const done = groups.filter((g) => num(g, 'decisions') === 0);

    view.innerHTML = pageHeader('تحتاج إجراء',
      cycle ? `الدورة الجارية: ${esc(str(cycle, 'name'))}` : 'لا دورة جارية')

      + kpiRow([
        { label: 'قرارات تنتظر', value: count(totalDecisions), tone: 'primary',
          sub: `${count(open.length)} مجموعة` },
        { label: 'مشتركون متأثّرون', value: count(totalSubscribers), tone: 'blue' },
        { label: 'مال ينتظر قراراً', value: knownAmount ? money(knownAmount) : '—', tone: 'red',
          sub: knownAmount ? 'حيث يُعرف المبلغ' : 'لا مبلغ محسوب بعد' },
        { label: 'مجموعات محسومة', value: count(done.length), tone: 'green',
          sub: done.length ? 'لا شيء ينتظر فيها' : '—' },
      ])

      + (ordered.length
        ? ordered.map((g) => {
            const role = str(g, 'role');
            return `<div class="box" style="margin-top:12px">
              <div class="minirow" style="border:0;padding-top:0">
                <span>
                  <b style="font-size:14px">${esc(str(g, 'label'))}</b>
                  ${chip(role, ROLE_TONE[role] || 'info')}
                  <div class="muted" style="font-size:11px;margin-top:2px">
                    وحدة القرار: ${esc(str(g, 'unit'))}</div>
                </span>
                <span style="text-align:end">
                  <b style="font-size:18px">${count(num(g, 'decisions'))}</b>
                  <div class="muted" style="font-size:11px">قراراً</div>
                </span>
              </div>
              <div class="minirow">
                <span class="muted">الأثر</span>
                <span>
                  ${num(g, 'subscribers') ? `<b>${count(num(g, 'subscribers'))}</b> مشتركاً` : ''}
                  ${num(g, 'events') ? ` · <b>${count(num(g, 'events'))}</b> حدثاً` : ''}
                  ${num(g, 'amount') ? ` · <b class="money">${money(num(g, 'amount'))}</b>` : ''}
                </span>
              </div>
              <div class="actions" style="margin-top:10px">
                <a class="btn gold" href="${esc(href(str(g, 'path')))}">${esc(str(g, 'next_action'))}</a>
              </div>
            </div>`;
          }).join('')
        : empty('لا شيء ينتظر قراراً', 'كل المجموعات محسومة'))

      // المحسوم يُعرض أيضاً: صفرٌ معلومٌ خيرٌ من غيابٍ يُقرأ نسياناً.
      + (done.length
        ? `<div class="box" style="margin-top:16px">
            <h3>محسومة</h3>
            ${done.map((g) => `<div class="minirow">
              <span class="muted">${esc(str(g, 'label'))}</span>
              <span>${chip('لا شيء ينتظر', 'success')}</span></div>`).join('')}
          </div>`
        : '');
  },
};

export const routes: Route[] = [workCenter];
