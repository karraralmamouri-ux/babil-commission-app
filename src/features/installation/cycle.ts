/**
 * دورة التنصيب الشهرية.
 *
 * عشر خطوات تُقاس من البيانات لا تُعلَن يدوياً: خطوةٌ «مكتملة» حين لا يبقى
 * فيها ما ينتظر، و«جارية» حين فيها عمل، و«لم تبدأ» حين لا مدخل لها.
 *
 * والمرشّح والجاهز يبقيان منفصلين في كل موضع. الأوّل قراءةٌ من المتبقّي
 * التاريخي، والثاني حكمٌ بعد اجتياز كل الفحوص. خلطُهما يعرض مالاً للصرف لم
 * يُفحص.
 */

import type { Route } from '../../app/router';
import { href } from '../../app/router';
import { rpc } from '../../services/api';
import { money, count } from '../../domain/money';
import { esc, loading, pageHeader, kpiRow, chip } from '../../components/ui';

type Row = Record<string, unknown>;
const num = (r: Row, k: string) => Number(r[k] || 0);
const str = (r: Row, k: string) => String(r[k] ?? '');

const STATE: Record<string, { label: string; tone: 'success' | 'warning' | 'neutral'; mark: string }> = {
  DONE:    { label: 'مكتملة', tone: 'success', mark: '✓' },
  ACTIVE:  { label: 'جارية', tone: 'warning', mark: '◉' },
  PENDING: { label: 'لم تبدأ', tone: 'neutral', mark: '○' },
};

export const cycle: Route = {
  pattern: '/installation/cycle',
  capability: 'installation.view',
  title: 'دورة التنصيب',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'أجور التنصيب', href: href('/installation') },
    { label: 'الدورة الشهرية' },
  ],
  async render(view, m) {
    const period = m.query.get('period');
    view.write(loading('جارٍ قياس خطوات الدورة…'));

    const doc = await rpc<Row>('installation_cycle_pipeline',
      period ? { p_period: period } : {});
    if (!view.live) return;

    const steps = (doc?.['steps'] || []) as Row[];
    const cand = (doc?.['candidate'] || {}) as Row;
    const ready = (doc?.['ready'] || {}) as Row;
    const hist = (doc?.['historical'] || {}) as Row;

    const done = steps.filter((s) => str(s, 'state') === 'DONE').length;
    const active = steps.filter((s) => str(s, 'state') === 'ACTIVE');
    // الخطوة الحالية: أوّل جاريةٍ بالترتيب — هي التي تنتظر عملاً الآن.
    const current = active.sort((a, b) => num(a, 'order') - num(b, 'order'))[0] || null;

    view.innerHTML = pageHeader('دورة التنصيب الشهرية',
      `${esc(str(doc || {}, 'period'))} · ${count(done)} من ${count(steps.length)} خطوة مكتملة`)

      + kpiRow([
        { label: 'الخطوة الحالية', value: current ? esc(str(current, 'label')) : 'لا خطوة جارية',
          tone: 'primary', sub: current ? esc(str(current, 'blocker') || 'قيد العمل') : '—',
          link: current ? href(str(current, 'path')) : undefined },
        { label: 'المرشّح', value: money(num(cand, 'amount')), tone: 'blue',
          sub: `${count(num(cand, 'subscribers'))} مشتركاً — قراءة لا حكم` },
        { label: 'الجاهز', value: money(num(ready, 'amount')),
          tone: num(ready, 'subscribers') ? 'green' : 'red',
          sub: num(ready, 'subscribers')
            ? `${count(num(ready, 'subscribers'))} مشتركاً اجتاز الفحوص`
            : 'لا أحد اجتاز كل الفحوص بعد',
          link: href('/installation/ready') },
        { label: 'المدفوع تاريخياً', value: money(num(hist, 'paid')), tone: 'gold',
          sub: `${count(num(hist, 'rows'))} صفّاً — لا يُدفع ثانية`,
          link: href('/reports/historical') },
      ])

      + `<div class="box" style="margin-top:14px">
        <h3>الخطوات</h3>
        <p class="muted" style="font-size:11px;margin:0 0 12px">
          حالة كل خطوة مقيسة من البيانات، لا معلَنة يدوياً.</p>
        ${steps.map((s) => {
          const st = STATE[str(s, 'state')] || STATE['PENDING'];
          const blocker = str(s, 'blocker');
          const n = num(s, 'count');
          const amt = num(s, 'amount');
          return `<div class="minirow">
            <span>
              <b style="font-family:var(--font-num)">${st ? st.mark : '○'}</b>
              <b>${esc(str(s, 'label'))}</b>
              ${chip(st ? st.label : '—', st ? st.tone : 'neutral')}
              ${blocker ? `<span class="muted">— ${esc(blocker)}</span>` : ''}
            </span>
            <span>
              ${n ? `<b>${count(n)}</b>` : ''}
              ${amt ? ` <span class="money">${money(amt)}</span>` : ''}
              <a class="smallbtn" href="${esc(href(str(s, 'path')))}">${esc(str(s, 'next_action'))}</a>
            </span>
          </div>`;
        }).join('')}
      </div>`

      + `<div class="insight warn" style="margin-top:12px"><span class="insight-dot"></span><span>
          <b>المرشّح ليس الجاهز</b>
          <small>المرشّح مشتقٌّ من المتبقّي التاريخي. لا يصير جاهزاً إلا بعد
          الفاتورة والتعليق والأهلية والهوية والعائدية — وكلها تُفحص على
          الخادم.</small></span></div>`;
  },
};

export const routes: Route[] = [cycle];
