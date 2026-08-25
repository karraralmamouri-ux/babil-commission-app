/**
 * مطابقة الهوية — تشغيل bootstrap_subscriber_identities() ومراجعة نتيجتها.
 *
 * «مطابقة الهوية» ليست «مشترك جديد». التشغيل يربط ما وصل من SaaS بسجلّ
 * installation_subscribers القائم فقط؛ لا يُنشئ مشتركاً، ولا استحقاقاً،
 * ولا دفعة، ولا يُعيد فتح مطابقةٍ محسومة. من بقي غير مطابَق (UNMATCHED)
 * أو بمطابقتين متعارضتين (CONFLICT) يُعرض هنا بدليله — والحسم قرارٌ بشري
 * خارج هذه الشاشة، لا نتيجة تشغيلٍ تلقائي.
 *
 * هذه الشاشة نفسها هي وجهة قرار «تعارض هوية» في مركز القرار — لا شاشة
 * موازية جديدة، تصحيحُ مسارٍ واحد في action_center().
 */

import type { Route, View } from '../../app/router';
import { href } from '../../app/router';
import { rpc, pageRpc, can, ApiError } from '../../services/api';
import { count } from '../../domain/money';
import {
  esc, loading, empty, pageHeader, table, pager, kpiRow, chip,
  filterBar, wireFilters, type Column,
} from '../../components/ui';

type Row = Record<string, unknown>;
const str = (r: Row, k: string) => String(r[k] ?? '');

const STATUS_AR: Record<string, string> = {
  MATCHED: 'مطابَق', CONFLICT: 'تعارض', UNMATCHED: 'غير مطابَق', NEEDS_REVIEW: 'يحتاج مراجعة',
};
const STATUS_TONE: Record<string, 'success' | 'critical' | 'warning' | 'neutral'> = {
  MATCHED: 'success', CONFLICT: 'critical', UNMATCHED: 'warning', NEEDS_REVIEW: 'warning',
};

function insight(tone: 'good' | 'warn' | 'danger', title: string, detail = ''): string {
  return `<div class="insight ${tone}" style="margin-top:10px"><span class="insight-dot"></span><span>
    <b>${esc(title)}</b>${detail ? `<small>${esc(detail)}</small>` : ''}</span></div>`;
}

export const identities: Route = {
  pattern: '/system/identities',
  capability: 'subscriber.match',
  title: 'مطابقة الهوية',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'مطابقة الهوية' },
  ],
  async render(view, m) {
    const limit = 50;
    const offset = Number(m.query.get('offset') || 0);
    view.innerHTML = loading('جارٍ تحميل الهويات…');

    const args: Record<string, unknown> = { p_limit: limit, p_offset: offset };
    for (const [q, p] of [['status', 'p_status'], ['classification', 'p_source_classification'],
      ['search', 'p_search']] as const) {
      const v = m.query.get(q);
      if (v) args[p] = v;
    }

    const [conflictTotal, unmatchedTotal, matchedTotal, page] = await Promise.all([
      pageRpc<Row>('page_subscriber_identities', { p_status: 'CONFLICT', p_limit: 1 }, view.signal),
      pageRpc<Row>('page_subscriber_identities', { p_status: 'UNMATCHED', p_limit: 1 }, view.signal),
      pageRpc<Row>('page_subscriber_identities', { p_status: 'MATCHED', p_limit: 1 }, view.signal),
      pageRpc<Row>('page_subscriber_identities', args, view.signal),
    ]);
    if (!view.live) return;

    const columns: Array<Column<Row>> = [
      { key: 'user', label: 'مستخدم SaaS', cell: (r) =>
        `<span dir="ltr">${esc(str(r, 'username') || str(r, 'saas_user_id'))}</span>` },
      { key: 'status', label: 'الحالة', cell: (r) =>
        chip(STATUS_AR[str(r, 'identity_status')] || str(r, 'identity_status'),
          STATUS_TONE[str(r, 'identity_status')] || 'neutral') },
      { key: 'sub', label: 'المشترك المرتبط', cell: (r) => str(r, 'installation_subscriber_key')
        ? `<a dir="ltr" href="${esc(href(`/installation/subscribers/${encodeURIComponent(str(r, 'installation_subscriber_key'))}`))}">${esc(str(r, 'installation_subscriber_key'))}</a>`
        : '<span class="muted">—</span>' },
      { key: 'agent', label: 'الوكيل الفعّال', cell: (r) => esc(str(r, 'effective_agent_name') || '—') },
      { key: 'src', label: 'التصنيف', cell: (r) => esc(str(r, 'source_classification')) },
      { key: 'parent', label: 'الأب الخام', cell: (r) => esc(str(r, 'raw_parent') || '—') },
      { key: 'method', label: 'طريقة المطابقة', cell: (r) => esc(str(r, 'match_method') || '—') },
    ];

    view.innerHTML = pageHeader('مطابقة الهوية',
      'ربط ما وصل من SaaS بسجلّ المشتركين القائم — لا يُنشئ مشتركاً جديداً')
      + kpiRow([
        { label: 'مطابَق', value: count(Number(matchedTotal.total || 0)), tone: 'green' },
        { label: 'تعارض', value: count(Number(conflictTotal.total || 0)), tone: 'red' },
        { label: 'غير مطابَق', value: count(Number(unmatchedTotal.total || 0)), tone: 'gold' },
      ])
      + bootstrapPanel()
      + filterBar([
        { key: 'search', label: 'بحث بالمستخدم أو الأب', type: 'search' },
        { key: 'status', label: 'الحالة', type: 'select', options: [
          { value: 'MATCHED', label: 'مطابَق' }, { value: 'CONFLICT', label: 'تعارض' },
          { value: 'UNMATCHED', label: 'غير مطابَق' }, { value: 'NEEDS_REVIEW', label: 'يحتاج مراجعة' },
        ] },
        { key: 'classification', label: 'التصنيف', type: 'select', options: [
          { value: 'RESELLER', label: 'موزّع' }, { value: 'DIRECT_COMPANY', label: 'شركة مباشرة' },
          { value: 'UNKNOWN_PARENT', label: 'أب غير معروف' },
        ] },
      ], '/system/identities', m.query)
      + (page.rows.length ? table(columns, page.rows) : empty('لا هويات مطابقة لهذه التصفية'))
      + pager(page.total, limit, offset, '/system/identities', m.query);

    wireFilters(view.el);
    wireBootstrap(view);
  },
};

function bootstrapPanel(): string {
  if (!can('subscriber.match')) return '';
  return `<div class="box" style="margin:12px 0" id="bootstrapBox">
    <h3>تشغيل مطابقة الهوية</h3>
    <div class="insight warn"><span class="insight-dot"></span><span>
      <b>مطابقة الهوية ليست مشتركاً جديداً</b>
      <small>التشغيل يربط مستخدمي SaaS بسجلّ المشتركين القائم فقط. لا يُنشئ
        مشتركاً، ولا استحقاقاً، ولا دفعة، ولا يُعيد فتح مطابقةٍ موجودة —
        الإدراج يتجاهل ما هو مطابَق مسبقاً. إعادة التشغيل آمنة.</small></span></div>
    <button class="btn gold" id="bootstrapRun" style="margin-top:10px">شغّل المطابقة الآن</button>
    <div id="bootstrapResult"></div>
  </div>`;
}

function wireBootstrap(view: View): void {
  const btn = view.el.querySelector<HTMLButtonElement>('#bootstrapRun');
  const out = view.el.querySelector<HTMLElement>('#bootstrapResult');
  if (!btn || !out) return;

  btn.addEventListener('click', async () => {
    if (!window.confirm('تشغيل مطابقة الهوية الآن؟ لن يُنشأ أي مشترك أو استحقاق جديد.')) return;
    btn.disabled = true;
    out.innerHTML = loading('جارٍ تشغيل المطابقة…');
    try {
      const res = await rpc<Row>('run_identity_bootstrap', { p_request_id: crypto.randomUUID() });
      if (!view.live) return;
      const r = (res?.['result'] || {}) as Row;
      out.innerHTML = insight('good',
        res?.['replayed'] === true ? 'هذا التشغيل مسجَّل مسبقاً' : 'انتهت المطابقة',
        `أُنشئ ${count(Number(r['identities_created'] || 0))} — إجمالي ${count(Number(r['identities_total'] || 0))}` +
        ` · مطابَق ${count(Number(r['matched_to_registry'] || 0))} · تعارض ${count(Number(r['conflicts'] || 0))}` +
        ` · غير مطابَق ${count(Number(r['unmatched'] || 0))}`);
      window.setTimeout(() => { if (view.live) window.location.reload(); }, 1800);
    } catch (error) {
      if (!view.live) return;
      out.innerHTML = insight('danger', 'تعذّر التشغيل',
        error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
    } finally {
      btn.disabled = false;
    }
  });
}

export const routes: Route[] = [identities];
