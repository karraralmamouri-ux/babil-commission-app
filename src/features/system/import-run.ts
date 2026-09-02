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
import { bridgeSweepAll } from './bridge-sweep';

type Row = Record<string, unknown>;
const num = (r: Row, k: string) => Number(r[k] || 0);
const str = (r: Row, k: string) => String(r[k] ?? '');

declare global {
  interface Window {
    XLSX?: {
      read: (data: ArrayBuffer, opts: { type: string }) => XlsxBook;
      utils: { sheet_to_json: (sheet: unknown, opts: { defval: string; header?: number; raw?: boolean }) => Row[] };
    };
    InstallationFees?: {
      buildImportPreview: (rows: Row[], options: Record<string, unknown>) => Row;
      buildHistoricalPreview: (rows: Row[], options: Record<string, unknown>) => Row;
      buildHistoricalImportRows: (preview: Row) => Row[];
    };
    SaasImport?: {
      parseWorkbook: (sheets: Array<{ name: string; rows: Row[] }>, options: Record<string, unknown>) => Row;
    };
  }
}

interface XlsxBook { SheetNames: string[]; Sheets: Record<string, unknown>; }

/** بصمة الملف: تُحسب من بايتاته لا من اسمه، فالاسم يتغيّر والمحتوى لا. */
async function checksum(buffer: ArrayBuffer): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', buffer);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

type Mode = 'ENTITLEMENTS' | 'HISTORY' | 'SAAS';

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
            <option value="SAAS">ملف SaaS — أحداث تفعيل و/أو لقطة مستخدمين</option>
          </select>
          <input class="search" id="imPeriod" placeholder="الفترة YYYY-MM" dir="ltr"
            aria-label="الفترة">
          <input class="search" type="date" id="imAsOf" aria-label="تاريخ اللقطة"
            style="display:none">
          <input class="search" type="datetime-local" id="imSnapshotAt"
            aria-label="وقت لقطة المستخدمين" style="display:none">
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
  const snapshotAt = root.querySelector<HTMLInputElement>('#imSnapshotAt');
  if (!mode || !parse || !host || !confirm || !out) return;

  let parsed: Parsed | null = null;

  const syncMode = () => {
    const isHistory = mode.value === 'HISTORY';
    const isSaas = mode.value === 'SAAS';
    if (period) period.style.display = (isHistory || isSaas) ? 'none' : '';
    if (asOf) asOf.style.display = isHistory ? '' : 'none';
    if (snapshotAt) snapshotAt.style.display = isSaas ? '' : 'none';
    if (hint) {
      hint.textContent = isSaas
        ? 'ملف SaaS: يُقرأ بمحلِّل التفعيل نفسه المستخدَم في المعاينة. الأحداث تُميَّز بمعرّفها لا بالمشترك، فلا إزالة تكرار على مستوى المشترك أبداً. لقطة المستخدمين — إن وُجدت — تحتاج وقت لقطة صريحاً.'
        : isHistory
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
    const saas = window.SaasImport;
    if (!xlsx || (mode.value === 'SAAS' ? !saas : !fees)) {
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

      if (mode.value === 'SAAS') {
        const sheets = book.SheetNames.map((name) => ({
          name, rows: xlsx.utils.sheet_to_json(book.Sheets[name], { defval: '' }) as Row[],
        }));
        const preview = saas!.parseWorkbook(sheets, {});
        if (!view.live) return;
        parsed = { fileName: f.name, checksum: sum, sheetName: sheets.map((s) => s.name).join(', '), rows: [], preview };
        if (info) {
          info.textContent = `${f.name} · ${sheets.length} ورقة · بصمة ${sum.slice(0, 16)}…`;
        }
        host.innerHTML = renderSaasPreview(preview);
        confirm.disabled = acceptedCount(preview, 'SAAS') === 0;
        return;
      }

      const sheetName = book.SheetNames[0] || '';
      const sheet = book.Sheets[sheetName];
      const rows = xlsx.utils.sheet_to_json(sheet, { defval: '' });

      // المحلِّل نفسه الذي كانت تستدعيه الشاشة السابقة — لا نسخة ثانية.
      const preview = mode.value === 'HISTORY'
        ? fees!.buildHistoricalPreview(rows, { asOfDate: asOf?.value || null })
        : fees!.buildImportPreview(rows, { period: period?.value.trim() || '', existingKeys: [] });

      if (!view.live) return;
      parsed = { fileName: f.name, checksum: sum, sheetName, rows, preview };
      if (info) {
        info.textContent = `${f.name} · ${rows.length.toLocaleString('en-US')} صفّاً · `
          + `الورقة «${sheetName}» · بصمة ${sum.slice(0, 16)}…`;
      }
      host.innerHTML = renderPreview(preview, mode.value as Mode);
      confirm.disabled = acceptedCount(preview, mode.value as Mode) === 0;
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
    const isSaas = mode.value === 'SAAS';
    if (!isHistory && !isSaas && !/^\d{4}-(0[1-9]|1[0-2])$/.test(period?.value.trim() || '')) {
      out.innerHTML = insight('warn', 'الفترة إلزامية', 'بصيغة YYYY-MM');
      return;
    }
    if (isHistory && !asOf?.value) {
      out.innerHTML = insight('warn', 'تاريخ اللقطة إلزامي', 'لا يُشتقّ من الملف');
      return;
    }
    const preview = parsed.preview;
    if (isSaas && Array.isArray(preview['users']) && (preview['users'] as Row[]).length
      && !snapshotAt?.value) {
      out.innerHTML = insight('warn', 'وقت لقطة المستخدمين إلزامي',
        'الملف يحمل صفّ مستخدمين، ولا يُشتقّ وقت اللقطة من الملف');
      return;
    }

    confirm.disabled = true;
    out.innerHTML = loading('جارٍ الاعتماد على الخادم…');
    try {
      if (isSaas) {
        const events = Array.isArray(preview['events']) ? (preview['events'] as Row[]) : [];
        const users = Array.isArray(preview['users']) ? (preview['users'] as Row[]) : [];
        const parts: string[] = [];

        if (events.length) {
          const batch = await importSaasEventsChunked(
            parsed.fileName, parsed.checksum, events,
            (done, total) => {
              if (!view.live) return;
              out.innerHTML = loading(total > SAAS_EVENTS_CHUNK_SIZE
                ? `جارٍ اعتماد أحداث التفعيل… (${count(done)} من ${count(total)})`
                : 'جارٍ الاعتماد على الخادم…');
            });
          // batch_totals إجماليّ الملف كله عبر كل أجزائه، لا الجزء الأخير وحده.
          const totals = (batch['batch_totals'] as Row) || batch;
          parts.push(`أحداث: مقبول ${count(num(totals, 'accepted'))} · مكرّر ${count(num(totals, 'duplicates'))}`
            + ` · مرفوض ${count(num(totals, 'rejected'))}`);

          // الاستيراد وحده لا يُنشئ حالة تنصيب. الجسر هو ما يُحوّل التفعيل
          // الخام إلى تسجيلٍ ثم حالةٍ رسمية — وبالبوابة نفسها، فلا يُسجَّل من
          // لم تُجزه. أكثر الصفوف تُمنع هنا بحق (الهوية والتصنيف واكتمال
          // المصدر تُحسم بعد الرفع)، ولذلك يُعاد المسح من مركز الاستيراد.
          //
          // ولا يُشغَّل إلا بعد أن يكتمل الاستيراد فعلاً: أيّ جزءٍ يسقط يرمي،
          // فلا يُقيَّم مرشّحو ملفٍّ نصفِ مرفوع.
          const swept = await bridgeSweepAll(str(batch, 'batch_id') || null,
            (t) => {
              if (!view.live) return;
              out.innerHTML = loading(`جارٍ تقييم المرشّحين… (سُجّل ${count(t.enrolled)}`
                + ` · بقي ${count(t.remaining)})`);
            });
          parts.push(`تسجيل: مؤهَّل ${count(swept.enrolled)}`
            + ` · بانتظار المراجعة ${count(swept.blocked)}`
            + (swept.complete ? '' : ` · بقي ${count(swept.remaining)} بلا نظر`));
        }
        if (users.length) {
          const r = await rpc<Row>('import_saas_user_snapshot', {
            p_file_name: parsed.fileName,
            p_file_checksum: parsed.checksum,
            p_parser_version: 'saas-import.js',
            p_snapshot_at: snapshotAt?.value ? new Date(snapshotAt.value).toISOString() : null,
            p_rows: users,
            p_request_id: crypto.randomUUID(),
          });
          const batch = (r?.['batch'] || {}) as Row;
          parts.push(`مستخدمون: مقبول ${count(num(batch, 'accepted'))} · مكرّر ${count(num(batch, 'duplicates'))}`
            + ` · مرفوض ${count(num(batch, 'rejected'))}`);
        }
        if (!view.live) return;
        out.innerHTML = insight('good', 'اعتُمد الاستيراد', parts.join(' — '))
          + `<div class="actions" style="margin-top:10px">
              <a class="btn" href="${esc(href('/system/imports'))}">افتح مركز الاستيراد</a></div>`;
        parsed = null;
        return;
      }

      const fees = window.InstallationFees;
      const result = isHistory
        ? await rpc<Row>('import_installation_history', {
            p_as_of_date: asOf?.value,
            p_file_name: parsed.fileName,
            p_file_checksum: parsed.checksum,
            p_rows: fees ? fees.buildHistoricalImportRows(preview) : [],
            p_request_id: crypto.randomUUID(),
          })
        : await importEntitlementsChunked(
            period?.value.trim() || '', parsed.fileName, parsed.checksum, entitlementRows(preview),
            (done, total) => {
              if (!view.live) return;
              out.innerHTML = loading(total > ENTITLEMENTS_CHUNK_SIZE
                ? `جارٍ الاعتماد على الخادم… (${count(done)} من ${count(total)})`
                : 'جارٍ الاعتماد على الخادم…');
            });
      if (!view.live) return;

      const batch = (result?.['batch'] || result || {}) as Row;
      // batch_totals إجماليّ الدفعة كلّها عبر كلّ أجزائها، لا الجزء الأخير وحده.
      const totals = (batch['batch_totals'] as Row) || batch;
      out.innerHTML = insight('good', 'اعتُمد الاستيراد',
        `مقبول ${count(num(totals, 'accepted'))} · مكرّر ${count(num(totals, 'duplicates'))}`
        + ` · مرفوض ${count(num(totals, 'rejected'))} من ${count(num(totals, 'source_rows'))} صفّاً`)
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

/** حجم الجزء في import_saas_activation_events (20261104090000).
 *
 *  تدقيق QA ما بعد الإطلاق (2026-09-02): Activations Report_Aug-2026.xlsx
 *  فيه 29,427 حدثاً، وكان يُرسَل كله في نداءٍ واحد فيعود بـ statement
 *  timeout. القياس على قاعدةٍ محلية بعد جعل الاستيعاب مجموعياً: النداء
 *  الواحد بـ30,000 صفٍّ ≈ 5.3 ثانية من ميزانية الثماني ثوانٍ — هامشٌ لا
 *  يُبنى عليه؛ والجزء بـ5,000 صفٍّ مكتمل الحقول ≈ ثانيةٌ واحدة، والملف كله
 *  بستّة أجزاء ≈ 4.4–5.7 ثانية في قياسين. المقاس محفوظٌ في
 *  tests/sql/saas-activation-large-import.sh ويُعاد قياسه في كل تشغيل. */
const SAAS_EVENTS_CHUNK_SIZE = 5000;

/** يُقسّم أحداث التفعيل إلى نداءاتٍ ضمن دفعةٍ منطقيةٍ واحدة للملف.
 *
 *  batchId هنا متغيّرٌ محليٌّ فقط: لو أُعيد تحميل الصفحة أثناء الرفع فُقِد،
 *  وتُعاد المحاولة من i=0 بمعرّفات طلبٍ جديدة. الصحّة لا تعتمد على بقائه —
 *  p_row_offset يُعلن دوماً موضع الجزء الحقيقي داخل الملف، والخادم هو من
 *  يقرّر بمدى المواضع المُستقبَلة هل هذا وارد جديدٌ أم إعادة إرسال، فلا
 *  يُعيد عدّه ولا يُعيد قراءته. وبصمة الملف تُعيده إلى دفعته نفسها، فلا
 *  تنشأ دفعةٌ ثانيةٌ لملفٍّ واحد. */
async function importSaasEventsChunked(
  fileName: string, fileChecksum: string, rows: Row[],
  onProgress: (done: number, total: number) => void,
): Promise<Row> {
  let batchId: string | null = null;
  let last: Row = {};
  for (let i = 0; i < rows.length; i += SAAS_EVENTS_CHUNK_SIZE) {
    const chunk = rows.slice(i, i + SAAS_EVENTS_CHUNK_SIZE);
    const params: Row = {
      p_file_name: fileName,
      p_file_checksum: fileChecksum,
      p_parser_version: 'saas-import.js',
      p_rows: chunk,
      p_request_id: crypto.randomUUID(),
      p_expected_rows: rows.length,
      // الإنهاء للجزء الأخير وحده: أيّ جزءٍ يسقط يترك الدفعة مفتوحةً
      // مستأنَفة، لا مقفلةً زوراً وهي منقوصة.
      p_finalize: i + chunk.length >= rows.length,
      p_row_offset: i,
    };
    if (batchId) params['p_batch_id'] = batchId;
    const r = await rpc<Row>('import_saas_activation_events', params);
    last = (r?.['batch'] || {}) as Row;
    batchId = str(last, 'batch_id') || batchId;
    onProgress(Math.min(i + chunk.length, rows.length), rows.length);
  }
  return last;
}

/** حدّ النداء الواحد في import_installation_entitlements — صار حجم دفعةٍ داخلية
 *  لا سقف ملفٍّ (20261027090000). ملفّات الاستحقاقات الحقيقية قد تتجاوزه. */
const ENTITLEMENTS_CHUNK_SIZE = 20000;

/** يُقسّم صفوف استحقاقات الشهر إلى نداءاتٍ ≤20000 ضمن دفعةٍ منطقيةٍ واحدة:
 *  النداء الأول بلا p_batch_id ينشئ الدفعة، وكلّ نداءٍ لاحقٍ يُلحِق بها عبر
 *  batch_id الذي أعاده النداء السابق. يعيد استجابة آخر نداءٍ — تحمل
 *  batch_totals لإجماليّ الدفعة كلّها، لا الجزء الأخير وحده.
 *
 *  تدقيق QA ما بعد الإطلاق (2026-09-02، إغلاق عوائق Codex #2): كل نداءٍ
 *  ناجحٍ كان يُقفل الدفعة `completed` فوراً — فجزءٌ لاحقٌ فاشلٌ يترك الدفعة
 *  مقفلةً زوراً وهي منقوصة (20261031090000). الآن p_finalize صريحة: false
 *  لكل جزءٍ ما عدا الأخير، وp_expected_rows تُعلَن دوماً فيتحقّق الخادم من
 *  اكتمال العدد قبل القفل — لا إنهاء صامتٌ ولا إنهاءٌ مبكِّر.
 *
 *  إغلاق عوائق Codex الأخير (20261101090000): batchId هنا متغيّرٌ محليٌّ فقط
 *  — لو أُعيد تحميل الصفحة أثناء الرفع يُفقَد، وتُعاد المحاولة من i=0 بمعرّف
 *  طلبٍ جديد. الصحّة لم تعد تعتمد على بقاء هذا المتغيّر: p_row_offset يُعلن
 *  دوماً موضع هذا الجزء الحقيقي داخل الملف (i نفسها)، والخادم هو من يقرّر
 *  — عبر مدى المواضع المُستقبلة فعلياً لهذه الدفعة — هل هذا الجزء وارد
 *  جديدٌ أم إعادة إرسالٍ لِما استُقبل من قبل، فلا يُعيد عدّه في الحالتين. */
async function importEntitlementsChunked(
  period: string, fileName: string, fileChecksum: string, rows: Row[],
  onProgress: (done: number, total: number) => void,
): Promise<Row> {
  let batchId: string | null = null;
  let last: Row = {};
  for (let i = 0; i < rows.length; i += ENTITLEMENTS_CHUNK_SIZE) {
    const chunk = rows.slice(i, i + ENTITLEMENTS_CHUNK_SIZE);
    const isLast = i + chunk.length >= rows.length;
    const params: Row = {
      p_period: period,
      p_file_name: fileName,
      p_file_checksum: fileChecksum,
      p_rows: chunk,
      p_request_id: crypto.randomUUID(),
      p_expected_rows: rows.length,
      p_finalize: isLast,
      p_row_offset: i,
    };
    if (batchId) params['p_batch_id'] = batchId;
    last = await rpc<Row>('import_installation_entitlements', params);
    batchId = str((last['batch'] || {}) as Row, 'batch_id') || batchId;
    onProgress(Math.min(i + chunk.length, rows.length), rows.length);
  }
  return last;
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

function acceptedCount(preview: Row | null, mode: Mode): number {
  if (!preview) return 0;
  if (mode === 'SAAS') {
    const events = Array.isArray(preview['events']) ? (preview['events'] as Row[]).length : 0;
    const users = Array.isArray(preview['users']) ? (preview['users'] as Row[]).length : 0;
    return events + users;
  }
  const batch = (preview['batch'] || preview) as Row;
  const accepted = batch['accepted'];
  if (Array.isArray(accepted)) return accepted.length;
  const mapped = preview['mappedRows'];
  return Array.isArray(mapped) ? mapped.length : Number(accepted || 0);
}

/** معاينة ملف SaaS: عدّاد لكل ورقة، وما أُسقط بسببه، بلا أي كتابة بعد. */
function renderSaasPreview(preview: Row): string {
  const sheetResults = Array.isArray(preview['sheetResults']) ? (preview['sheetResults'] as Row[]) : [];
  const events = Array.isArray(preview['events']) ? (preview['events'] as Row[]) : [];
  const users = Array.isArray(preview['users']) ? (preview['users'] as Row[]) : [];
  const unparsedDates = num(preview, 'unparsedDates');
  const secretsDropped = num(preview, 'secretsDropped');
  const duplicateCount = num(preview, 'duplicateCount');

  return `<div class="box" style="margin-top:12px">
    <h3>المعاينة</h3>
    ${kpiRow([
      { label: 'أحداث تفعيل', value: count(events.length), tone: 'green' },
      { label: 'لقطة مستخدمين', value: count(users.length), tone: 'blue' },
      { label: 'مكرّر عبر الأوراق', value: count(duplicateCount), tone: duplicateCount ? 'gold' : 'blue' },
      { label: 'تاريخ غير مفهوم', value: count(unparsedDates), tone: unparsedDates ? 'red' : 'green',
        sub: unparsedDates ? 'يُستبعد من كل حساب لاحق' : 'كل تاريخ فُهم' },
    ])}
    <p class="muted" style="font-size:11px;margin-top:8px">
      ${secretsDropped ? `أُسقط ${count(secretsDropped)} عموداً سرّياً قبل القراءة — لا يُخزَّن ولا يُعرض. ` : ''}
      هذه قراءةٌ للملف. الخادم يعيد الفرز ويكتب التكرار على مستوى الحدث لا المشترك.</p>

    ${sheetResults.length ? `<div style="margin-top:10px">
      <h3 style="font-size:13px">الأوراق</h3>
      ${table<Row>([
        { key: 'sheet', label: 'الورقة', cell: (r) => esc(str(r, 'sheet')) },
        { key: 'kind', label: 'النوع', cell: (r) => {
          const k = str(r, 'kind');
          return k === 'REJECTED' ? chip('مرفوضة — ' + str(r, 'reason'), 'critical')
            : chip(k === 'ACTIVATION_EVENTS' ? 'أحداث تفعيل' : 'لقطة مستخدمين', 'info');
        } },
        { key: 'rows', label: 'صفوف الملف', cell: (r) => count(num(r, 'rows')), numeric: true },
        { key: 'imp', label: 'مقبول', cell: (r) => count(num(r, 'imported')), numeric: true },
        { key: 'dup', label: 'مكرّر', cell: (r) => count(num(r, 'duplicates')), numeric: true },
        { key: 'rej', label: 'مرفوض', cell: (r) => count(num(r, 'rejected')), numeric: true },
      ], sheetResults)}
    </div>` : ''}
  </div>`;
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
