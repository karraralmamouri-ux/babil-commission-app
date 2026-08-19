/**
 * سجلّ التدقيق.
 *
 * الجدول كان يُكتب فيه ولا يُقرأ منه: لا شاشة تعرضه. وسجلٌّ لا يُقرأ لا يردع
 * ولا يُطمئن — وجوده وعدمه سواء عند المراجعة.
 *
 * تُعرض الأفعال بأسماء فاعليها لا بمعرّفاتهم، ومع قيمتَي «قبل» و«بعد» جنباً
 * إلى جنب: التغيير يُقرأ تغييراً لا حالةً جديدة.
 */

import type { Route } from '../../app/router';
import { href } from '../../app/router';
import { rpc, pageRpc } from '../../services/api';
import { count } from '../../domain/money';
import {
  esc, loading, empty, pageHeader, table, pager, chip,
  filterBar, wireFilters, type Column,
} from '../../components/ui';

type Row = Record<string, unknown>;
const str = (r: Row, k: string) => String(r[k] ?? '');

/** أسماء الأفعال بالعربية. المجهول يُعرض كما هو لا يُخفى. */
const ACTION_AR: Record<string, string> = {
  'commission.payment.recorded': 'تسجيل دفعة عمولة',
  'commission.month.published': 'اعتماد شهر عمولات',
  'installation.history.imported': 'استيراد تاريخ التنصيب',
  'settings.import.saved': 'حفظ إعدادات الاستيراد',
  'master.parent.classified': 'تصنيف أب',
  'subscriber.ownership.transferred': 'نقل عائدية مشترك',
};

/** الأفعال التي تحرّك مالاً أو تحسم عائدية تُميَّز بصرياً. */
const WEIGHTY = /payment|published|transferred|classified|reversed|finalize/i;

const when = (v: unknown) => String(v ?? '').replace('T', ' ').slice(0, 16);

export const auditLog: Route = {
  pattern: '/audit',
  capability: 'audit.view',
  title: 'سجلّ التدقيق',
  breadcrumb: () => [{ label: 'الرئيسية', href: href('/') }, { label: 'سجلّ التدقيق' }],
  async render(view, m) {
    const limit = 50;
    const offset = Number(m.query.get('offset') || 0);
    view.innerHTML = loading('جارٍ تحميل السجلّ…');

    const args: Record<string, unknown> = { p_limit: limit, p_offset: offset };
    for (const [q, p] of [['action', 'p_action'], ['actor', 'p_actor'],
      ['entity', 'p_entity'], ['search', 'p_search']] as const) {
      const v = m.query.get(q);
      if (v) args[p] = v;
    }

    const [page, facets] = await Promise.all([
      pageRpc<Row>('page_audit_logs', args, view.signal),
      rpc<Row>('audit_facets', {}).catch(() => null),
    ]);
    if (!view.live) return;

    const actions = ((facets?.['actions'] || []) as Row[]).map((a) => ({
      value: str(a, 'value'),
      label: `${ACTION_AR[str(a, 'value')] || str(a, 'value')} (${count(Number(a['n'] || 0))})`,
    }));
    const actors = ((facets?.['actors'] || []) as Row[]).map((a) => ({
      value: str(a, 'value'),
      label: `${str(a, 'label')} (${count(Number(a['n'] || 0))})`,
    }));

    const columns: Array<Column<Row>> = [
      { key: 'when', label: 'الوقت', cell: (r) => `<span dir="ltr">${esc(when(r['created_at']))}</span>` },
      { key: 'action', label: 'الفعل', cell: (r) => {
        const a = str(r, 'action');
        return `${esc(ACTION_AR[a] || a)}${WEIGHTY.test(a) ? ` ${chip('مؤثِّر', 'warning')}` : ''}`;
      } },
      { key: 'who', label: 'الفاعل', cell: (r) =>
        esc(str(r, 'actor_name') || str(r, 'actor_email') || 'النظام') },
      { key: 'what', label: 'الحقل', cell: (r) => esc(str(r, 'field') || '—') },
      // «قبل ← بعد» في خلية واحدة: التغيير يُقرأ تغييراً.
      { key: 'change', label: 'التغيير', cell: (r) => {
        const before = str(r, 'old_value');
        const after = str(r, 'new_value');
        if (!before && !after) return '<span class="muted">—</span>';
        return `<span class="muted">${esc(before || '—')}</span> ← <b>${esc(after || '—')}</b>`;
      } },
      { key: 'extra', label: 'التفصيل', cell: (r) => {
        const x = str(r, 'extra');
        return x ? `<span class="muted" dir="ltr" style="font-size:10px">${esc(x)}</span>` : '—';
      } },
    ];

    view.innerHTML = pageHeader('سجلّ التدقيق',
      'من فعل ماذا ومتى — بأسماء الفاعلين لا بمعرّفاتهم')
      + filterBar([
        { key: 'search', label: 'بحث في التفصيل', type: 'search' },
        { key: 'action', label: 'الأفعال', type: 'select', options: actions },
        { key: 'actor', label: 'الفاعلين', type: 'select', options: actors },
      ], '/audit', m.query)
      + (page.outOfRange
        ? `<div class="insight warn"><span class="insight-dot"></span><span><b>الصفحة خارج المدى</b>
           <small>السجلّ فيه ${count(page.total)} قيداً. عُد إلى الصفحة الأولى.</small></span></div>`
        : '')
      + (page.rows.length ? table(columns, page.rows) : empty('لا قيود مطابقة'))
      + pager(page.total, limit, offset, '/audit', m.query);

    wireFilters(view.el);
  },
};

export const routes: Route[] = [auditLog];
