/**
 * التعليقات: العرض، والتعليق بالجملة من ملف.
 *
 * الشاشة تقول عن كل تعليق ما يحتاجه من يقرأه: نوعه، وسببه، ومتى بدأ، ومتى
 * ينتهي إن كان مؤقّتاً، ومن وضعه، ومن أيّ مصدر — فردياً أم من ملفٍ باسمه.
 *
 * والرفع بالجملة يمرّ بمعاينة قبل أن يُطبَّق شيء: من الذي سيُعلَّق فعلاً، ومن
 * سيُترك ولماذا. مطالبةُ المشغّل بتعليق مئتَي مشترك واحداً واحداً وعنده
 * قائمتهم ليست حرصاً بل عطل.
 */

import type { Route, View } from '../../app/router';
import { href } from '../../app/router';
import { rpc, pageRpc, can, ApiError } from '../../services/api';
import { count } from '../../domain/money';
import { dateTime } from '../../domain/time';
import {
  esc, loading, empty, pageHeader, table, pager, chip,
  filterBar, wireFilters, type Column,
} from '../../components/ui';

type Row = Record<string, unknown>;
const str = (r: Row, k: string) => String(r[k] ?? '');
const when = (v: unknown) => (v ? dateTime(v) : '—');

const PERMANENCE_AR: Record<string, string> = {
  PERMANENT: 'دائم',
  TEMPORARY: 'مؤقّت',
};

const SOURCE_AR: Record<string, string> = {
  INDIVIDUAL: 'فردي',
  BULK: 'ملف',
};

/* ---- سجلّ التعليقات ------------------------------------------------------ */

export const holds: Route = {
  pattern: '/installation/holds',
  capability: 'installation.view',
  title: 'التعليقات',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'أجور التنصيب', href: href('/installation') },
    { label: 'التعليقات' },
  ],
  async render(view, m) {
    const limit = 50;
    const offset = Number(m.query.get('offset') || 0);
    view.innerHTML = loading('جارٍ تحميل التعليقات…');

    const args: Record<string, unknown> = { p_limit: limit, p_offset: offset };
    for (const [q, p] of [['status', 'p_status'], ['permanence', 'p_permanence'],
      ['source', 'p_source'], ['search', 'p_search']] as const) {
      const v = m.query.get(q);
      if (v) args[p] = v;
    }

    const page = await pageRpc<Row>('page_installation_holds', args, view.signal);
    if (!view.live) return;

    const columns: Array<Column<Row>> = [
      { key: 'sid', label: 'المشترك', cell: (r) =>
        `<a dir="ltr" href="${esc(href(`/installation/subscribers/${encodeURIComponent(str(r, 'subscriber_id'))}`))}">${esc(str(r, 'subscriber_id'))}</a>` },
      { key: 'kind', label: 'نوع الحجب', cell: (r) => {
        const p = str(r, 'permanence');
        return chip(PERMANENCE_AR[p] || p, p === 'PERMANENT' ? 'critical' : 'warning');
      } },
      { key: 'reason', label: 'السبب', cell: (r) =>
        esc(str(r, 'reason_note') || str(r, 'reason_label') || str(r, 'reason_code')) },
      { key: 'from', label: 'البداية', cell: (r) => `<span dir="ltr">${esc(when(r['created_at']))}</span>` },
      { key: 'until', label: 'الانتهاء', cell: (r) =>
        str(r, 'permanence') === 'TEMPORARY'
          ? `<span dir="ltr">${esc(when(r['expires_at']))}</span>`
          : '<span class="muted">لا ينتهي</span>' },
      { key: 'who', label: 'من علّق', cell: (r) => esc(str(r, 'created_by_email') || '—') },
      { key: 'src', label: 'المصدر', cell: (r) => {
        const s = str(r, 'source');
        const file = str(r, 'upload_filename');
        return `${esc(SOURCE_AR[s] || s)}${file ? ` <span class="muted" dir="ltr">${esc(file)}</span>` : ''}`;
      } },
      { key: 'state', label: 'الحالة', cell: (r) => {
        if (r['effective'] === true) return chip('ساري', 'critical');
        if (str(r, 'status') === 'RELEASED') return chip('مرفوع', 'success');
        return chip('انقضى', 'neutral');
      } },
    ];

    view.innerHTML = pageHeader('التعليقات',
      'التعليق يمنع الصرف ولا يمسّ ما دُفع')
      + `<div class="actions" style="margin-bottom:12px">
          <a class="btn gold" href="${esc(href('/installation/holds/bulk'))}">تعليق بالجملة من ملف</a>
        </div>`
      + filterBar([
        { key: 'search', label: 'بحث بالمشترك أو السبب', type: 'search' },
        { key: 'status', label: 'الحالة', type: 'select', options: [
          { value: 'EFFECTIVE', label: 'ساري' },
          { value: 'EXPIRED', label: 'انقضى' },
          { value: 'RELEASED', label: 'مرفوع' },
        ] },
        { key: 'permanence', label: 'النوع', type: 'select', options: [
          { value: 'PERMANENT', label: 'دائم' },
          { value: 'TEMPORARY', label: 'مؤقّت' },
        ] },
        { key: 'source', label: 'المصدر', type: 'select', options: [
          { value: 'INDIVIDUAL', label: 'فردي' },
          { value: 'BULK', label: 'ملف' },
        ] },
      ], '/installation/holds', m.query)
      + (page.outOfRange
        ? `<div class="insight warn"><span class="insight-dot"></span><span><b>الصفحة خارج المدى</b>
           <small>المجموعة فيها ${count(page.total)} تعليقاً.</small></span></div>`
        : '')
      + (page.rows.length ? table(columns, page.rows) : empty('لا تعليقات'))
      + pager(page.total, limit, offset, '/installation/holds', m.query);

    wireFilters(view.el);
  },
};

/* ---- التعليق بالجملة ----------------------------------------------------- */

const BUCKET_AR: Record<string, string> = {
  valid: 'سيُعلَّق',
  unknown: 'معرّف غير معروف',
  already_held: 'مُعلَّق سلفاً',
  already_done: 'أنهى مراحله',
  already_paid: 'مدفوع',
};

const BUCKET_TONE: Record<string, 'success' | 'critical' | 'warning' | 'neutral'> = {
  valid: 'success',
  unknown: 'critical',
  already_held: 'warning',
  already_done: 'neutral',
  already_paid: 'neutral',
};

export const bulkHold: Route = {
  pattern: '/installation/holds/bulk',
  capability: 'installation.hold',
  title: 'تعليق بالجملة',
  breadcrumb: () => [
    { label: 'الرئيسية', href: href('/') },
    { label: 'أجور التنصيب', href: href('/installation') },
    { label: 'التعليقات', href: href('/installation/holds') },
    { label: 'تعليق بالجملة' },
  ],
  render(view) {
    view.innerHTML = pageHeader('تعليق بالجملة',
      'ارفع ملفاً فيه معرّفات المشتركين — يُعايَن قبل أن يُطبَّق شيء')

      + `<div class="box">
        <h3>١ · الملف</h3>
        <p class="muted" style="font-size:11px;margin:0 0 8px">
          العمود المطلوب واحد: معرّف المشترك. وإن حمل الملف عمود سبب أو تاريخ
          انتهاء فسيُقرآن؛ وإلّا فقيمةٌ واحدة تُختار هنا وتسري على الجميع.
          الصيغ المقبولة: CSV أو نصّ بمعرّف في كل سطر.</p>
        <div class="toolbar">
          <input type="file" id="bhFile" accept=".csv,.txt" class="search"
            aria-label="ملف المعرّفات">
          <button class="btn" id="bhParse">اقرأ الملف</button>
        </div>
        <textarea id="bhIds" class="search" rows="5" dir="ltr"
          style="width:100%;margin-top:10px;font-family:ui-monospace,Consolas,monospace"
          placeholder="أو الصق المعرّفات هنا، واحداً في كل سطر"
          aria-label="معرّفات المشتركين"></textarea>
        <div id="bhFileInfo" class="muted" style="font-size:11px;margin-top:6px"></div>
      </div>

      <div class="box" style="margin-top:12px">
        <h3>٢ · نوع الحجب وسببه</h3>
        <div class="toolbar">
          <select class="select" id="bhPermanence" aria-label="نوع الحجب">
            <option value="PERMANENT">دائم — لا ينتهي تلقائياً</option>
            <option value="TEMPORARY">مؤقّت — ينتهي بتاريخ</option>
          </select>
          <input class="search" type="datetime-local" id="bhUntil"
            aria-label="ينتهي في" style="display:none">
          <input class="search" id="bhReason" placeholder="سبب الحجب (إلزامي)"
            aria-label="سبب الحجب">
        </div>
        <p class="muted" style="font-size:11px;margin-top:6px">
          الدائم لا ينقضي بنفسه، ورفعه يحتاج صلاحية
          <code>installation.release_hold</code>.</p>
      </div>

      <div class="actions" style="margin-top:12px">
        <button class="btn" id="bhPreview">٣ · عايِن</button>
        <button class="btn gold" id="bhApply" disabled>٤ · طبّق التعليق</button>
      </div>

      <div id="bhResult" style="margin-top:12px"></div>`;

    wireBulkHold(view);
  },
};

function parseIds(text: string): string[] {
  // سطرٌ لكل معرّف، أو CSV بعمودٍ أوّل. العنوان يُسقَط إن بدا عنواناً.
  const rows = text.split(/\r?\n/)
    .map((line) => (line.split(/[,;\t]/)[0] || '').trim())
    .filter(Boolean);
  if (rows.length && /^(subscriber[\s_-]?id|id|المشترك|معرّف)$/i.test(rows[0] as string)) {
    rows.shift();
  }
  return rows;
}

function wireBulkHold(view: View): void {
  const root = view.el;
  const file = root.querySelector<HTMLInputElement>('#bhFile');
  const parse = root.querySelector<HTMLButtonElement>('#bhParse');
  const ids = root.querySelector<HTMLTextAreaElement>('#bhIds');
  const info = root.querySelector<HTMLElement>('#bhFileInfo');
  const permanence = root.querySelector<HTMLSelectElement>('#bhPermanence');
  const until = root.querySelector<HTMLInputElement>('#bhUntil');
  const reason = root.querySelector<HTMLInputElement>('#bhReason');
  const preview = root.querySelector<HTMLButtonElement>('#bhPreview');
  const apply = root.querySelector<HTMLButtonElement>('#bhApply');
  const out = root.querySelector<HTMLElement>('#bhResult');
  if (!ids || !permanence || !until || !preview || !apply || !out) return;

  let filename = '';
  let previewed: string[] = [];

  permanence.addEventListener('change', () => {
    until.style.display = permanence.value === 'TEMPORARY' ? '' : 'none';
  });

  parse?.addEventListener('click', () => {
    const f = file?.files?.[0];
    if (!f) { if (info) info.textContent = 'اختر ملفاً أولاً'; return; }
    filename = f.name;
    const reader = new FileReader();
    reader.onload = () => {
      ids.value = String(reader.result || '');
      const n = parseIds(ids.value).length;
      if (info) info.textContent = `${f.name} — ${n.toLocaleString('en-US')} معرّفاً`;
    };
    reader.readAsText(f, 'utf-8');
  });

  preview.addEventListener('click', async () => {
    const list = parseIds(ids.value);
    if (!list.length) {
      out.innerHTML = insight('warn', 'لا معرّفات', 'ارفع ملفاً أو الصق المعرّفات');
      return;
    }
    preview.disabled = true;
    out.innerHTML = loading('جارٍ المعاينة…');
    try {
      const doc = await rpc<Row>('preview_bulk_hold', { p_ids: list });
      if (!view.live) return;
      previewed = list;
      out.innerHTML = renderPreview(doc);
      // لا يُفتح التطبيق إلا إذا كان هناك ما يُطبَّق فعلاً.
      const counts = (doc?.['counts'] || {}) as Record<string, number>;
      apply.disabled = Number(counts['valid'] || 0) === 0;
    } catch (error) {
      if (!view.live) return;
      out.innerHTML = insight('danger', 'تعذّرت المعاينة',
        error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
    } finally {
      preview.disabled = false;
    }
  });

  apply.addEventListener('click', async () => {
    if (!can('installation.hold')) {
      out.innerHTML = insight('warn', 'لا صلاحية', 'التعليق يحتاج installation.hold');
      return;
    }
    const why = reason?.value.trim() || '';
    if (!why) {
      out.innerHTML = insight('warn', 'السبب إلزامي', 'يُحفظ مع كل تعليق ويظهر في التدقيق');
      return;
    }
    if (permanence.value === 'TEMPORARY' && !until.value) {
      out.innerHTML = insight('warn', 'المؤقّت يحتاج تاريخ انتهاء');
      return;
    }
    if (!previewed.length) {
      out.innerHTML = insight('warn', 'عايِن أولاً', 'لا يُطبَّق شيء قبل أن يُعرض أثره');
      return;
    }

    apply.disabled = true;
    out.innerHTML = loading('جارٍ تطبيق التعليق…');
    try {
      const result = await rpc<Row>('apply_bulk_hold', {
        p_ids: previewed,
        p_permanence: permanence.value,
        p_reason_code: 'MANUAL_REVIEW',
        p_note: why,
        p_filename: filename || 'لصق يدوي',
        p_expires_at: permanence.value === 'TEMPORARY'
          ? new Date(until.value).toISOString() : null,
        p_request_id: crypto.randomUUID(),
      });
      if (!view.live) return;
      out.innerHTML = result?.['idempotent'] === true
        ? insight('good', 'هذا الرفع مسجَّل مسبقاً', 'لم يُعلَّق أحد مرّةً ثانية')
        : insight('good', `عُلِّق ${count(Number(result?.['applied'] || 0))} مشتركاً`,
            `تُرك ${count(Number(result?.['skipped'] || 0))} — مجهول أو مُعلَّق سلفاً أو أنهى مراحله.`)
          + `<div class="actions" style="margin-top:10px">
              <a class="btn" href="${esc(href('/installation/holds'))}">افتح السجلّ</a></div>`;
    } catch (error) {
      if (!view.live) return;
      out.innerHTML = insight('danger', 'لم يُطبَّق التعليق',
        error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
    } finally {
      apply.disabled = false;
    }
  });
}

function renderPreview(doc: Row | null): string {
  const counts = (doc?.['counts'] || {}) as Record<string, number>;
  const rows = (doc?.['rows'] || []) as Row[];
  const submitted = Number(doc?.['submitted'] || 0);
  const duplicate = Number(doc?.['duplicate'] || 0);

  const order = ['valid', 'unknown', 'already_held', 'already_done', 'already_paid'];
  const chips = order
    .filter((k) => Number(counts[k] || 0) > 0)
    .map((k) => `<div class="minirow">
      <span>${chip(BUCKET_AR[k] || k, BUCKET_TONE[k] || 'neutral')}</span>
      <b>${count(Number(counts[k]))}</b></div>`).join('');

  return `<div class="box">
    <h3>المعاينة</h3>
    <div class="minirow"><span class="muted">في الملف</span><b>${count(submitted)}</b></div>
    ${duplicate ? `<div class="minirow"><span class="muted">مكرّر داخل الملف</span>
      <b>${count(duplicate)}</b></div>` : ''}
    ${chips}
    <p class="muted" style="font-size:11px;margin-top:8px">
      لن يُعلَّق إلا ما هو في «سيُعلَّق». الباقي يُترك كما هو، ولا شيء يُحذف.</p>
    ${rows.length ? table<Row>([
      { key: 'id', label: 'المعرّف', cell: (r) => `<span dir="ltr">${esc(str(r, 'subscriber_id'))}</span>` },
      { key: 'b', label: 'النتيجة', cell: (r) => {
        const b = str(r, 'bucket');
        return chip(BUCKET_AR[b] || b, BUCKET_TONE[b] || 'neutral');
      } },
      { key: 'stage', label: 'المرحلة التالية', cell: (r) => esc(str(r, 'next_stage') || '—') },
      { key: 'times', label: 'مرّات وروده', cell: (r) => count(Number(r['times'] || 1)), numeric: true },
    ], rows.slice(0, 200)) : ''}
    ${rows.length > 200
      ? `<p class="muted" style="font-size:11px">تُعرض أوّل 200 صفّاً من ${count(rows.length)}.</p>`
      : ''}
  </div>`;
}

function insight(tone: 'good' | 'warn' | 'danger', title: string, detail = ''): string {
  return `<div class="insight ${tone}"><span class="insight-dot"></span><span>
    <b>${esc(title)}</b>${detail ? `<small>${esc(detail)}</small>` : ''}</span></div>`;
}

/* ---- تعليق مشترك واحد من ملفّه ------------------------------------------- */

/**
 * اللوحة تُدرَج في تبويب «الإيقافات» داخل ملفّ المشترك.
 *
 * القواعد نفسها التي تحكم الرفع بالجملة، لأن الطريقين يُنتجان الأثر نفسه:
 * منعُ الصرف. اختلافُ الشاشتين لا يبرّر اختلاف الشروط.
 */
export function holdPanel(subscriberId: string): string {
  if (!can('installation.hold')) {
    return `<div class="box" style="margin-top:12px">
      <p class="muted">تحتاج صلاحية <code>installation.hold</code> لتعليق الصرف.</p></div>`;
  }
  return `<div class="box" style="margin-top:12px" id="holdBox"
      data-subscriber="${esc(subscriberId)}">
    <h3>تعليق الصرف</h3>
    <p class="muted" style="font-size:11px;margin:0 0 10px">
      يمنع دخول أيّ استحقاق غير مدفوع في دفعة. لا يمسّ ما دُفع.</p>
    <div class="toolbar">
      <select class="select" id="hpPermanence" aria-label="نوع الحجب">
        <option value="PERMANENT">دائم — لا ينتهي تلقائياً</option>
        <option value="TEMPORARY">مؤقّت — ينتهي بتاريخ</option>
      </select>
      <input class="search" type="datetime-local" id="hpUntil"
        aria-label="ينتهي في" style="display:none">
      <input class="search" id="hpReason" placeholder="سبب الحجب (إلزامي)"
        aria-label="سبب الحجب">
      <button class="btn gold" id="hpApply">علّق</button>
    </div>
    <div id="hpResult"></div>
  </div>`;
}

export function wireHoldPanel(view: View): void {
  const box = view.el.querySelector<HTMLElement>('#holdBox');
  if (!box) return;
  const subscriberId = box.dataset['subscriber'] || '';
  const permanence = box.querySelector<HTMLSelectElement>('#hpPermanence');
  const until = box.querySelector<HTMLInputElement>('#hpUntil');
  const reason = box.querySelector<HTMLInputElement>('#hpReason');
  const apply = box.querySelector<HTMLButtonElement>('#hpApply');
  const out = box.querySelector<HTMLElement>('#hpResult');
  if (!permanence || !until || !apply || !out) return;

  permanence.addEventListener('change', () => {
    until.style.display = permanence.value === 'TEMPORARY' ? '' : 'none';
  });

  apply.addEventListener('click', async () => {
    const why = reason?.value.trim() || '';
    if (!why) {
      out.innerHTML = insight('warn', 'السبب إلزامي', 'يُحفظ مع التعليق ويظهر في التدقيق');
      return;
    }
    if (permanence.value === 'TEMPORARY' && !until.value) {
      out.innerHTML = insight('warn', 'المؤقّت يحتاج تاريخ انتهاء');
      return;
    }
    apply.disabled = true;
    out.innerHTML = loading('جارٍ التعليق…');
    try {
      const result = await rpc<Row>('place_hold_v2', {
        p_subscriber_id: subscriberId,
        p_permanence: permanence.value,
        p_reason_code: 'MANUAL_REVIEW',
        p_note: why,
        p_stage_code: null,
        p_expires_at: permanence.value === 'TEMPORARY'
          ? new Date(until.value).toISOString() : null,
        p_request_id: crypto.randomUUID(),
      });
      if (!view.live) return;
      out.innerHTML = result?.['idempotent'] === true
        ? insight('good', 'المشترك معلَّق سلفاً', 'لم يُضَف تعليق ثانٍ')
        : insight('good', 'عُلِّق الصرف', 'لا يدخل أيّ استحقاق غير مدفوع في دفعة.');
      window.setTimeout(() => { if (view.live) window.location.reload(); }, 1200);
    } catch (error) {
      if (!view.live) return;
      out.innerHTML = insight('danger', 'لم يُعلَّق',
        error instanceof ApiError ? error.message : 'خطأ غير متوقّع');
    } finally {
      apply.disabled = false;
    }
  });
}

export const routes: Route[] = [holds, bulkHold];
