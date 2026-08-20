/**
 * تنفيذ الاستيراد — رفع، قراءة، معاينة، اعتماد.
 *
 * آخر ما كان يُلزم فتح الشاشات السابقة. والقاعدة الحاكمة هنا أنه **لا محلِّل
 * ثانٍ**: يُستدعى `assets/js/installation-fees.js` نفسه الذي كانت تستدعيه
 * الشاشة السابقة، بقواعده في المطابقة والتكرار والمتبقّي والمرحلة. محلِّلان
 * لملفٍّ واحد ينحرفان، وأوّل انحرافٍ بينهما مالٌ يُستحقّ في أحدهما ولا
 * يُستحقّ في الآخر.
 *
 * والاعتماد يمرّ بدالة الخادم القائمة: هي التي تحسب المقبول والمكرّر
 * والمرفوض وتكتب الدفعة. المتصفّح يقرأ الملف ويعرض، ولا يقرّر.
 *
 * وct_password لا يُقرأ ولا يُخزَّن ولا يُصدَّر — لا يمرّ بهذا المسار أصلاً.
 */

import type { Route, View } from '../../app/router';
import { href } from '../../app/router';
import { rpc, can, ApiError } from '../../services/api';
import { money, count } from '../../domain/money';
import { esc, loading, pageHeader, table, chip, kpiRow, type Column } from '../../components/ui';

type Row = Record<string, unknown>;
const num = (r: Row, k: string) => Number(r[k] || 0);
const str = (r: Row, k: string) => String(r[k] ?? '');

declare global {
  interface Window {
    XLSX?: {
      read: (data: ArrayBuffer, opts: { type: string }) => XlsxBook;
      utils: { sheet_to_json: (sheet: unknown, opts: { defval: string }) => Row[] };
    };
    InstallationFees?: {
      buildImportPreview: (rows: Row[], options: Record<string, unknown>) => Row;
      buildHistoricalPreview: (rows: Row[], options: Record<string, unknown>) => Row;
      buildHistoricalImportRows: (preview: Row) => Row[];
    };
  }
}

interface XlsxBook { SheetNames: string[]; Sheets: Record<string, unknown>; }

/** بصمة الملف: تُحسب من بايتاته لا من اسمه، فالاسم يتغيّر والمحتوى لا. */
async function checksum(buffer: ArrayBuffer): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', buffer);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

type Mode = 'ENTITLEMENTS' | 'HISTORY';

interface Parsed {
  fileName: string;
  checksum: string;
  sheetName: string;
  rows: Row[];
  preview: Row | null;
}

export const importRun: Route = {
  pattern: '/system/imports/new',
  capability: 'saas.import',
  title: 'استيراد ملف',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'الاستيراد', href: href('/system/imports') },
    { label: 'ملف جديد' },
  ],
  render(view) {
    if (!can('saas.import')) {
      view.innerHTML = pageHeader('استيراد ملف')
        + `<div class="box"><p class="muted">تحتاج صلاحية <code>saas.import</code>.</p></div>`;
      return;
    }

    view.innerHTML = pageHeader('استيراد ملف',
      'يُقرأ الملف ويُعايَن قبل أيّ كتابة — والاعتماد يمرّ بالخادم')

      + `<div class="box">
        <h3>١ · نوع الملف</h3>
        <div class="toolbar">
          <select class="select" id="imMode" aria-label="نوع الاستيراد">
            <option value="ENTITLEMENTS">استحقاقات شهر — متبقٍّ لكل مشترك</option>
            <option value="HISTORY">الأساس التاريخي — دفعات مسجَّلة</option>
          </select>
          <input class="search" id="imPeriod" placeholder="الفترة YYYY-MM" dir="ltr"
            aria-label="الفترة">
          <input class="search" type="date" id="imAsOf" aria-label="تاريخ اللقطة"
            style="display:none">
        </div>
        <p class="muted" style="font-size:11px;margin-top:6px" id="imModeHint">
          استحقاقات الشهر: يكتب ما يستحقّه كل مشترك في الفترة المذكورة.</p>
      </div>

      <div class="box" style="margin-top:12px">
        <h3>٢ · الملف</h3>
        <div class="toolbar">
          <input type="file" id="imFile" class="search" accept=".xlsx,.xls,.csv"
            aria-label="ملف الاستيراد">
          <button class="btn" id="imParse">اقرأ وعايِن</button>
        </div>
        <div id="imFileInfo" class="muted" style="font-size:11px;margin-top:6px"></div>
      </div>

      <div id="imPreview"></div>

      <div class="actions" style="margin-top:12px">
        <button class="btn gold" id="imConfirm" disabled>٣ · اعتمد الاستيراد</button>
        <span class="muted" style="font-size:11px">
          لا يُكتب شيء قبل هذه الخطوة. الخادم يعيد الفرز ويكتب الدفعة.</span>
      </div>
      <div id="imResult"></div>`;

    wireImport(view);
  },
};

function wireImport(view: View): void {
  const root = view.el;
  const mode = root.querySelector<HTMLSelectElement>('#imMode');
  const period = root.querySelector<HTMLInputElement>('#imPeriod');
  const asOf = root.querySelector<HTMLInputElement>('#imAsOf');
  const hint = root.querySelector<HTMLElement>('#imModeHint');
  const file = root.querySelector<HTMLInputElement>('#imFile');
  const parse = root.querySelector<HTMLButtonElement>('#imParse');
  const info = root.querySelector<HTMLElement>('#imFileInfo');
  const host = root.querySelector<HTMLElement>('#imPreview');
  const confirm = root.querySelector<HTMLButtonElement>('#imConfirm');
  const out = root.querySelector<HTMLElement>('#imResult');
  if (!mode || !parse || !host || !confirm || !out) return;

  let parsed: Parsed | null = null;

  const syncMode = () => {
    const isHistory = mode.value === 'HISTORY';
    if (period) period.style.display = isHistory ? 'none' : '';
    if (asOf) asOf.style.display = isHistory ? '' : 'none';
    if (hint) {
      hint.textContent = isHistory
        ? 'الأساس التاريخي: يبني ما دُفع سلفاً. تاريخ اللقطة يُختار ولا يُشتقّ من الملف.'
        : 'استحقاقات الشهر: يكتب ما يستحقّه كل مشترك في الفترة المذكورة.';
    }
    parsed = null;
    confirm.disabled = true;
    host.innerHTML = '';
  };
  mode.addEventListener('change', syncMode);
  syncMode();

  parse.addEventListener('click', async () => {
    const f = file?.files?.[0];
    if (!f) { if (info) info.textContent = 'اختر ملفاً أولاً'; return; }

    const xlsx = window.XLSX;
    const fees = window.InstallationFees;
    if (!xlsx || !fees) {
      host.innerHTML = insight('danger', 'مكتبة القراءة غير محمَّلة',
        'أعِد تحميل الصفحة ثم حاول مرّةً أخرى.');
      return;
    }

    parse.disabled = true;
    host.innerHTML = loading('جارٍ قراءة الملف…');
    try {
      const buffer = await f.arrayBuffer();
      const sum = await checksum(buffer);
      const book = xlsx.read(buffer, { type: 'array' });
      const sheetName = book.SheetNames[0] || '';
      const sheet = book.Sheets[sheetName];
      const rows = xlsx.utils.sheet_to_json(sheet, { defval: '' });

      // المحلِّل نفسه الذي كانت تستدعيه الشاشة السابقة — لا نسخة ثانية.
      const preview = mode.value === 'HISTORY'
        ? fees.buildHistoricalPreview(rows, { asOfDate: asOf?.value || null })
        : fees.buildImportPreview(rows, { period: period?.value.trim() || '', existingKeys: [] });

      if (!view.live) return;
      parsed = { fileName: f.name, checksum: sum, sheetName, rows, preview };
      if (info) {
        info.textContent = `${f.name} · ${rows.length.toLocaleString('en-US')} صفّاً · `
          + `الورقة «${sheetName}» · بصمة ${sum.slice(0, 16)}…`;
      }
      host.innerHTML = renderPreview(preview, mode.value as Mode);
      confirm.disabled = acceptedCount(preview) === 0;
    } catch (error) {
      if (!view.live) return;
      host.innerHTML = insight('danger', 'تعذّرت قراءة الملف',
        error instanceof Error ? error.message : 'صيغة غير مفهومة');
    } finally {
      parse.disabled = false;
    }
  });

  confirm.addEventListener('click', async () => {
    if (!parsed || !parsed.preview) {
      out.innerHTML = insight('warn', 'عايِن أولاً', 'لا يُعتمد ما لم يُعرض أثره');
      return;
    }
    const isHistory = mode.value === 'HISTORY';
    if (!isHistory && !/^\d{4}-(0[1-9]|1[0-2])$/.test(period?.value.trim() || '')) {
      out.innerHTML = insight('warn', 'الفترة إلزامية', 'بصيغة YYYY-MM');
      return;
    }
    if (isHistory && !asOf?.value) {
      out.innerHTML = insight('warn', 'تاريخ اللقطة إلزامي', 'لا يُشتقّ من الملف');
      return;
    }

    confirm.disabled = true;
    out.innerHTML = loading('جارٍ الاعتماد على الخادم…');
    try {
      const fees = window.InstallationFees;
      const preview = parsed.preview;
      const result = isHistory
        ? await rpc<Row>('import_installation_history', {
            p_as_of_date: asOf?.value,
            p_file_name: parsed.fileName,
            p_file_checksum: parsed.checksum,
            p_rows: fees ? fees.buildHistoricalImportRows(preview) : [],
            p_request_id: crypto.randomUUID(),
          })
        : await rpc<Row>('import_installation_entitlements', {
            p_period: period?.value.trim(),
            p_file_name: parsed.fileName,
            p_file_checksum: parsed.checksum,
            p_rows: entitlementRows(preview),
            p_request_id: crypto.randomUUID(),
          });
      if (!view.live) return;

      const batch = (result?.['batch'] || result || {}) as Row;
      out.innerHTML = insight('good', 'اعتُمد الاستيراد',
        `مقبول ${count(num(batch, 'accepted'))} · مكرّر ${count(num(batch, 'duplicates'))}`
        + ` · مرفوض ${count(num(batch, 'rejected'))} من ${count(num(batch, 'source_rows'))} صفّاً`)
        + `<div class="actions" style="margin-top:10px">
            <a class="btn" href="${esc(href('/system/imports'))}">افتح مركز الاستيراد</a></div>`;
      parsed = null;
    } catch (error) {
      if (!view.live) return;
      // نصّ الخادم كما ورد: هو الذي يعرف لماذا رُفض.
      out.innerHTML = insight('danger', 'لم يُعتمد الاستيراد',
        error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
    } finally {
      confirm.disabled = false;
    }
  });
}

/** صفوف الاستحقاق بالشكل الذي تنتظره دالة الخادم. */
function entitlementRows(preview: Row): Row[] {
  const mapped = (preview['mappedRows'] || preview['accepted'] || []) as Row[];
  return mapped.map((r) => ({
    subscriber_id: r['subscriberId'] ?? r['subscriber_id'],
    subscriber_name: r['subscriberName'] ?? r['subscriber_name'],
    reseller: r['reseller'],
    zone: r['zone'] || null,
    fdt: r['fdt'] || null,
    remaining: r['remaining'],
  }));
}

function acceptedCount(preview: Row | null): number {
  if (!preview) return 0;
  const batch = (preview['batch'] || preview) as Row;
  const accepted = batch['accepted'];
  if (Array.isArray(accepted)) return accepted.length;
  const mapped = preview['mappedRows'];
  return Array.isArray(mapped) ? mapped.length : Number(accepted || 0);
}

function renderPreview(preview: Row, mode: Mode): string {
  const batch = (preview['batch'] || preview) as Row;
  const accepted = Array.isArray(batch['accepted']) ? (batch['accepted'] as Row[]) : [];
  const invalid = Array.isArray(batch['invalid']) ? (batch['invalid'] as Row[]) : [];
  const duplicates = Array.isArray(batch['duplicates']) ? (batch['duplicates'] as Row[]) : [];
  const alreadyStored = Array.isArray(preview['alreadyStored'])
    ? (preview['alreadyStored'] as Row[]) : [];
  const totalAmount = accepted.reduce((a, r) => a + Number(r['amount'] || 0), 0);

  const sample = accepted.slice(0, 25);
  const cols: Array<Column<Row>> = mode === 'HISTORY'
    ? [
      { key: 'sid', label: 'المشترك', cell: (r) => `<span dir="ltr">${esc(str(r, 'subscriberId'))}</span>` },
      { key: 'stage', label: 'المرحلة', cell: (r) => chip(str(r, 'stage') || '—', 'info') },
      { key: 'amt', label: 'المبلغ', cell: (r) => money(num(r, 'amount')), numeric: true },
      { key: 'date', label: 'التاريخ', cell: (r) => `<span dir="ltr">${esc(str(r, 'paymentDate') || '—')}</span>` },
    ]
    : [
      { key: 'sid', label: 'المشترك', cell: (r) => `<span dir="ltr">${esc(str(r, 'subscriberId'))}</span>` },
      { key: 'res', label: 'الوكيل / الأب', cell: (r) => esc(str(r, 'reseller') || '—') },
      { key: 'rem', label: 'المتبقّي', cell: (r) => money(num(r, 'remaining')), numeric: true },
      { key: 'stage', label: 'المرحلة', cell: (r) => chip(str(r, 'stage') || '—', 'info') },
      { key: 'amt', label: 'القسط', cell: (r) => money(num(r, 'amount')), numeric: true },
    ];

  return `<div class="box" style="margin-top:12px">
    <h3>المعاينة</h3>
    ${kpiRow([
      { label: 'مقبول', value: count(accepted.length), tone: 'green',
        sub: totalAmount ? money(totalAmount) : '—' },
      { label: 'مرفوض', value: count(invalid.length), tone: invalid.length ? 'red' : 'blue',
        sub: invalid.length ? 'بأسبابه أدناه' : 'لا مرفوض' },
      { label: 'مكرّر داخل الملف', value: count(duplicates.length), tone: 'gold' },
      { label: 'مسجَّل سلفاً', value: count(alreadyStored.length), tone: 'blue',
        sub: 'لن يُكتب ثانية' },
    ])}
    <p class="muted" style="font-size:11px;margin-top:8px">
      هذه قراءةٌ للملف. الخادم يعيد الفرز عند الاعتماد، وأرقامه هي المعتمدة.</p>

    ${invalid.length ? `<div class="box" style="margin-top:10px">
      <h3>المرفوض — بسببه وسطره</h3>
      ${table<Row>([
        { key: 'row', label: 'السطر', cell: (r) => `<span dir="ltr">${esc(str(r, 'sourceRow') || str(r, 'rowNumber') || '—')}</span>` },
        { key: 'sid', label: 'المشترك', cell: (r) => `<span dir="ltr">${esc(str(r, 'subscriberId') || '—')}</span>` },
        { key: 'why', label: 'السبب', cell: (r) => {
          const p = r['problems'];
          return esc(Array.isArray(p) ? p.join(' · ') : str(r, 'problem') || '—');
        } },
      ], invalid.slice(0, 25))}
      ${invalid.length > 25 ? `<p class="muted" style="font-size:11px">
        تُعرض أوّل 25 من ${count(invalid.length)}.</p>` : ''}
    </div>` : ''}

    ${sample.length ? `<div style="margin-top:10px">
      <h3 style="font-size:13px">عيّنة من المقبول</h3>
      ${table(cols, sample)}
      ${accepted.length > 25 ? `<p class="muted" style="font-size:11px">
        تُعرض أوّل 25 من ${count(accepted.length)}.</p>` : ''}
    </div>` : ''}
  </div>`;
}

function insight(tone: 'good' | 'warn' | 'danger', title: string, detail = ''): string {
  return `<div class="insight ${tone}" style="margin-top:10px"><span class="insight-dot"></span><span>
    <b>${esc(title)}</b>${detail ? `<small>${esc(detail)}</small>` : ''}</span></div>`;
}

export const routes: Route[] = [importRun];
