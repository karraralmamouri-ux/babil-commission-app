/**
 * أحداث الكابينة في الدورة.
 *
 * الرقم «41» لا يُراجَع بوصفه رقماً. المشغّل الذي يعدّ 40 ويرى 41 لا ينفعه
 * أن يُقال له إن الحساب صحيح؛ ينفعه أن يرى الواحد والأربعين واحداً واحداً
 * بمشتركه وباقته ووقته وصفّه في الملفّ المصدر، فيؤشّر بنفسه على الزائد.
 *
 * والمعروض هنا مخرَج المحرّك نفسه (`commission_event_entitlements`) لا
 * إعادة اشتقاق له: ما يُعرض هو ما حُسب، بحكم التعريف لا بحكم التطابق.
 */

import type { Route } from '../../app/router';
import { href } from '../../app/router';
import { rpc, can } from '../../services/api';
import { money, count } from '../../domain/money';
import { esc, loading, empty, pageHeader, table, pager, kpiRow, chip, type Column } from '../../components/ui';

type Row = Record<string, unknown>;
const num = (r: Row, k: string) => Number(r[k] || 0);
const str = (r: Row, k: string) => String(r[k] ?? '');

export const fdtEvents: Route = {
  pattern: '/master/fdts/:code/events',
  capability: 'commission.view',
  title: 'أحداث الكابينة في الدورة',
  breadcrumb: (m) => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'ربط الوكلاء والكابينات', href: href('/master/mapping') },
    { label: `كابينة ${m.params['code'] ?? ''}` },
  ],
  async render(view, m) {
    const code = m.params['code'] as string;
    const limit = 200;
    const offset = Number(m.query.get('offset') || 0);
    view.innerHTML = loading('جارٍ قراءة أحداث الدورة…');

    const doc = await rpc<Row>('fdt_cycle_events', {
      p_code: code, p_limit: limit, p_offset: offset,
    });
    if (!view.live) return;

    const rows = (doc['rows'] || []) as Row[];
    const total = num(doc, 'total');
    const lifetime = num(doc, 'lifetime_events');
    const subs = num(doc, 'unique_subscribers');
    const corrections = num(doc, 'corrections');

    const columns: Array<Column<Row>> = [
      { key: 'sub', label: 'المشترك', cell: (r) =>
        `<b dir="ltr">${esc(str(r, 'username') || str(r, 'subscriber_key'))}</b>
         ${r['manual'] === true ? chip('مُضاف يدوياً', 'warning') : ''}` },
      { key: 'pkg', label: 'الباقة', cell: (r) => `<span dir="ltr">${esc(str(r, 'package_code'))}</span>` },
      { key: 'tier', label: 'الشريحة', cell: (r) => esc(str(r, 'tier_code') || '—') },
      { key: 'amount', label: 'المبلغ', cell: (r) => money(num(r, 'amount')), numeric: true },
      { key: 'at', label: 'الوقت', cell: (r) =>
        `<span dir="ltr">${esc(str(r, 'event_at').replace('T', ' ').slice(0, 16))}</span>` },
      { key: 'parent', label: 'الأب', cell: (r) =>
        `<span dir="ltr">${esc(str(r, 'raw_parent') || '—')}</span>` },
      // شاهد المصدر: الملفّ والورقة والصفّ ورقم المعاملة. بهذا يُراجَع الصفّ
      // في الملفّ الأصلي بلا بحثٍ يدوي.
      { key: 'src', label: 'الشاهد', cell: (r) => r['manual'] === true
        ? '<span class="muted">تصحيح يدوي — لا صفّ مصدر</span>'
        : `<span class="muted" dir="ltr">${esc(str(r, 'source_filename'))}
           · ${esc(str(r, 'source_sheet'))}:${esc(str(r, 'source_row'))}</span>
           <div class="muted" dir="ltr">${esc(str(r, 'transaction_id'))}</div>` },
      { key: 'fix', label: '', cell: (r) => can('commission.manage_cycle') && r['manual'] !== true
        ? `<a class="smallbtn" href="${esc(href('/commissions/corrections', {
            exclude: str(r, 'activation_event_id'), fdt: code }))}">استبعد</a>`
        : '' },
    ];

    view.innerHTML = pageHeader(`كابينة ${esc(code)} — أحداث الدورة`,
      'هذه هي الأحداث التي صنعت رقم الدورة، كما أنتجها المحرّك')

      + kpiRow([
        { label: 'تفعيلات الدورة', value: count(total), tone: 'primary',
          sub: 'ما يُحسب عليه المال' },
        { label: 'مشتركون فريدون للدورة', value: count(subs), tone: 'blue',
          sub: 'أساس الشريحة' },
        { label: 'إجمالي تاريخي', value: count(lifetime), tone: 'blue',
          sub: 'كل ما وصل منذ أوّل ملفّ — ليس رقم الشهر' },
        { label: 'تصحيحات فعّالة', value: count(corrections),
          tone: corrections ? 'gold' : 'green',
          sub: corrections ? 'استبعاد أو إضافة' : 'لا تصحيح' },
      ])

      + (lifetime !== total
        ? `<div class="insight warn" style="margin-top:12px"><span class="insight-dot"></span><span>
            <b>الرقمان مختلفان عمداً</b>
            <small>${count(total)} تفعيلاً في نافذة الدورة، و${count(lifetime)} إجمالاً منذ
              أوّل ملفّ. الأول وحده يدخل حساب العمولة.</small></span></div>`
        : '')

      + (rows.length ? table(columns, rows) : empty('لا أحداث لهذه الكابينة في الدورة'))
      + pager(total, limit, offset, `/master/fdts/${encodeURIComponent(code)}/events`, m.query)

      + (can('commission.manage_cycle')
        ? `<div class="box" style="margin-top:12px">
            <p class="muted" style="font-size:11px;margin:0">
              رأيتَ حدثاً لا يخصّ هذه الدورة؟ استبعاده يمرّ بـ
              <a href="${esc(href('/commissions/corrections'))}">تصحيح التفعيلات</a> —
              المصدر لا يُمسّ، ويُسجَّل من استبعده ولماذا.</p></div>`
        : '');
  },
};

export const routes: Route[] = [fdtEvents];
