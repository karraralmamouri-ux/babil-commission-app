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
import { dateTime } from '../../domain/time';
import { rpc, pageRpc } from '../../services/api';
import { count } from '../../domain/money';
import {
  esc, loading, empty, pageHeader, table, pager, chip,
  filterBar, wireFilters, type Column,
} from '../../components/ui';

type Row = Record<string, unknown>;
const str = (r: Row, k: string) => String(r[k] ?? '');

/**
 * أسماء الأفعال بالعربية. المجهول يُعرض كما هو لا يُخفى — لكن القائمة هنا
 * شاملة لكل فعلٍ فعليّ يُسجَّل في audit_logs عبر كل migration حالياً
 * (تدقيق QA 2026-09-01، طلب #8)، فلا يبقى فعلٌ حقيقيٌّ خارجها إلا فعلٌ
 * مستقبليٌّ لم يُضَف بعد.
 */
const ACTION_AR: Record<string, string> = {
  'commission.payment.recorded': 'تسجيل دفعة عمولة',
  'commission.month.published': 'اعتماد شهر عمولات',
  'installation.history.imported': 'استيراد تاريخ التنصيب',
  'settings.import.saved': 'حفظ إعدادات الاستيراد',
  'master.parent.classified': 'تصنيف أب',
  'subscriber.ownership.transferred': 'نقل عائدية مشترك',
  'installation.batch.imported': 'استيراد دفعة أجور تنصيب',
  'installation.invoice.audited': 'تدقيق فاتورة تنصيب',
  'installation.payment.recorded': 'تسجيل دفعة تنصيب',
  'report.exported': 'تصدير تقرير',
  'master.agent.saved': 'حفظ بيانات وكيل',
  'master.package.saved': 'حفظ بيانات باقة',
  'admin.user.updated': 'تعديل بيانات مستخدم',
  'commission.version.drafted': 'إنشاء مسودّة نسخة عمولات',
  'commission.draft.tier.changed': 'تعديل تير في مسودّة العمولات',
  'commission.draft.rate.changed': 'تعديل سعر في مسودّة العمولات',
  'installation.invoice.reviewed': 'مراجعة فاتورة تنصيب',
  'commission.cycle.finalized': 'اعتماد دورة عمولات نهائياً',
  'commission.cycle.opened': 'فتح دورة عمولات',
  'commission.cycle.cancelled': 'إلغاء دورة عمولات',
  'installation.hold.placed': 'تعليق تنصيب',
  'commission.batch.posted': 'ترحيل دفعة عمولات',
  'commission.activation.excluded': 'استبعاد تفعيل من العمولة',
  'commission.activation.added': 'إضافة تفعيل يدوياً',
  'commission.activation.correction.revoked': 'إلغاء تصحيح تفعيل',
  'installation.batch.paid': 'صرف دفعة أجور تنصيب',
  'installation.entitlements.materialized': 'بناء استحقاقات التنصيب',
  'installation.stage.advanced': 'تقدّم مرحلة التنصيب',
  'installation.enrollment.bulk_bridged': 'تسجيل جماعي من ملف التفعيل',
  'installation.batch.created': 'إنشاء دفعة أجور تنصيب',
  'installation.batch.cancelled': 'إلغاء دفعة أجور تنصيب',
  'installation.enrollment.created': 'تسجيل مشترك في التنصيب',
  'installation.cycle.closed': 'إغلاق دورة تنصيب',
  'installation.cycle.reopened': 'إعادة فتح دورة تنصيب',
  'commission.cycle.closed': 'إغلاق دورة عمولات',
  'commission.cycle.reopened': 'إعادة فتح دورة عمولات',
  'commission.exception.resolved': 'حلّ استثناء عمولة',
  'saas.import_batch.voided': 'إبطال دفعة استيراد SaaS',
  'commission.scheme.published': 'اعتماد مخطط عمولات',
  'commission.cycle.recalculated': 'إعادة احتساب دورة عمولات',
  'installation.invoice.bulk_uploaded': 'رفع فواتير تنصيب دفعة واحدة',
  'installation.manual_exception.created': 'تسجيل استثناء تنصيب يدوي',
  'installation.manual_exception.resolved': 'حلّ استثناء تنصيب يدوي',
  'import.completeness.declared': 'تأكيد اكتمال استيراد',
  'installation.hold.released': 'رفع تعليق تنصيب',
  'installation.hold.bulk_applied': 'تعليق تنصيب جماعي',
  'installation.grace.overridden': 'تجاوز مهلة تنصيب',
  'financial.reversed': 'عكس قيد مالي',
  'financial.corrected': 'تصحيح قيد مالي',
  'scheme.version.published': 'اعتماد نسخة مخطط',
  'identity.bootstrap.run': 'تشغيل مطابقة الهويات',
  'permission.changed': 'تعديل صلاحية',
  'saas.activation_events.imported': 'استيراد أحداث تفعيل SaaS',
  'saas.user_snapshot.imported': 'استيراد لقطة مستخدمي SaaS',
  'integration.odoo.invoice.checked': 'فحص فاتورة أودو',
  'master.fdt.classified': 'تصنيف FDT',
  'master.fdt.bulk_classified': 'تصنيف FDT جماعي',
  'commission.row.updated': 'تعديل صفّ عمولة',
  'commission.free_p1.threshold_set': 'ضبط حدّ Free P1',
  'commission.free_p1.granted': 'منح Free P1',
};

/** الأفعال التي تحرّك مالاً أو تحسم عائدية تُميَّز بصرياً. */
const WEIGHTY = /payment|published|transferred|classified|reversed|finalize/i;

const when = (v: unknown) => dateTime(v ?? '');

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
      rpc<Row>('audit_facets', {}),
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
      { key: 'who', label: 'من؟', cell: (r) =>
        `<b>${esc(str(r, 'actor_name') || str(r, 'actor_email') || 'النظام')}</b>` },
      { key: 'when', label: 'متى؟', cell: (r) => `<span dir="ltr">${esc(when(r['created_at']))}</span>
        <div class="muted table-hint">بتوقيت بغداد</div>` },
      { key: 'action', label: 'الفعل', cell: (r) => {
        const a = str(r, 'action');
        return `${esc(ACTION_AR[a] || a)}${WEIGHTY.test(a) ? ` ${chip('مؤثِّر', 'warning')}` : ''}`;
      } },
      { key: 'entity', label: 'أي كيان؟', cell: (r) => `<b>${esc(str(r, 'entity_label') || str(r, 'entity_type') || '—')}</b>
        ${str(r, 'field') ? `<div class="muted table-hint">${esc(str(r, 'field'))}</div>` : ''}` },
      { key: 'before', label: 'قبل', cell: (r) => esc(str(r, 'old_value') || '—') },
      { key: 'after', label: 'بعد', cell: (r) => `<b>${esc(str(r, 'new_value') || '—')}</b>` },
      { key: 'why', label: 'لماذا؟', cell: (r) => {
        // لا عمود reason أو note في audit_logs؛ السبب الفعلي مكتوبٌ داخل extra.
        const extra = str(r, 'extra');
        return `${esc(extra || '—')}<details class="technical-detail"><summary>تفاصيل تقنية</summary>
          <code>${esc(str(r, 'action'))}</code>
          <span dir="ltr">Entity: ${esc(str(r, 'entity_id') || '—')}</span>
          <span dir="ltr">Request: ${esc(str(r, 'request_id') || '—')}</span></details>`;
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
