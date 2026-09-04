/**
 * رفعُ مصدر الشهر من `/installation/monthly`: قراءةٌ ثم اعتماد، وثلاثُ صيغ.
 *
 * ثلاثةُ انحدارات يحرسها هذا الملف، وكلُّها وقعت أو كادت:
 *
 *   • **الكتابة قبل المعاينة.** كانت ضغطةٌ واحدة تقرأ الملف وتكتبه معاً.
 *     والأحداث الخام سجلٌّ لا يُنسَخ فوقه ولا يُحذف، فملفٌ خاطئ يدخل مرّةً
 *     ويبقى. فصارتا خطوتين: القراءة في المتصفّح لا تنادي الخادم أصلاً.
 *   • **سقوطُ CSV.** المُنتقي كان `.xlsx,.xls` بينما مركز الاستيراد يقبل
 *     `.csv` أيضاً، والمحلِّل نفسه يقرؤها. فحُرم المشغّل صيغةً معتمدة بلا
 *     سببٍ إلا سهو سطرٍ في الواجهة.
 *   • **مُحلِّلٌ ثانٍ.** أسهل ما في الأمر أن تُعيد الشاشة قراءة الملف بطريقتها،
 *     فيصير لملفٍ واحدٍ مصدرا حسابٍ يختلفان يوماً ما.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const monthly = fs.readFileSync(
  path.join(root, 'src', 'features', 'installation', 'monthly.ts'), 'utf8');
const importRun = fs.readFileSync(
  path.join(root, 'src', 'features', 'system', 'import-run.ts'), 'utf8');

/** جسمُ دالّةٍ مُصدَّرة، من توقيعها إلى الدالّة التي تليها. */
function exportedFunction(source, name) {
  const start = source.indexOf(`export async function ${name}(`);
  assert.notEqual(start, -1, `الدالّة ${name} غير مُصدَّرة`);
  const next = source.indexOf('\nexport ', start + 1);
  return source.slice(start, next === -1 ? source.length : next);
}

test('مُنتقي ملف الشهر يقبل الصيغ الثلاث المعتمدة، وCSV منها', () => {
  const accept = monthly.match(/id="mcFile"[^>]*accept="([^"]+)"/s);
  assert.ok(accept, 'لا سمة accept على مُنتقي ملف الشهر');
  const formats = accept[1].split(',').map((s) => s.trim());
  assert.deepEqual(formats.sort(), ['.csv', '.xls', '.xlsx']);
});

test('مُنتقي مركز الاستيراد يقبل الصيغ نفسها — لا شاشةَ أضيق من أختها', () => {
  const accept = importRun.match(/id="imFile"[^>]*accept="([^"]+)"/s);
  assert.ok(accept, 'لا سمة accept على مُنتقي مركز الاستيراد');
  assert.deepEqual(accept[1].split(',').map((s) => s.trim()).sort(),
    ['.csv', '.xls', '.xlsx']);
});

test('القراءة لا تكتب: لا نداءَ خادمٍ في مسار المعاينة', () => {
  const parse = exportedFunction(importRun, 'parseMonthlyActivationFile');
  assert.doesNotMatch(parse, /\brpc\s*\(/);
  assert.doesNotMatch(parse, /importSaasEventsChunked/);
  assert.doesNotMatch(parse, /bridgeSweepAll/);
  assert.doesNotMatch(parse, /\bfetch\s*\(/);
  // وتقرأ بالمحلِّل القائم وحده.
  assert.match(parse, /SaasImport/);
  assert.match(parse, /parseWorkbook/);
});

test('الاعتماد وحده يكتب، وبمسار الاستيراد القائم نفسه', () => {
  const commit = exportedFunction(importRun, 'commitMonthlyActivationFile');
  assert.match(commit, /importSaasEventsChunked/);
  assert.match(commit, /bridgeSweepAll/);
  // ولا يُعيد التحليل: يكتب ما عُوين، لا ما يقرؤه من جديد.
  assert.doesNotMatch(commit, /parseWorkbook/);
});

test('الشاشة تفصل الزرّين، ولا تكتب إلا من زرّ الاعتماد', () => {
  assert.match(monthly, /id="mcParse">اقرأ وعايِن</);
  assert.match(monthly, /id="mcCommit"[^>]*disabled>اعتمد مصدر الشهر</);
  // زرّ القراءة يستدعي المحلِّل، وزرّ الاعتماد وحده يستدعي الكاتب.
  const parseHandler = monthly.slice(monthly.indexOf("parse.addEventListener('click'"),
    monthly.indexOf("commit.addEventListener('click'"));
  assert.match(parseHandler, /parseMonthlyActivationFile/);
  assert.doesNotMatch(parseHandler, /commitMonthlyActivationFile/);
});

test('تبديل الملف بعد القراءة يُسقط المعاينة ويُعطّل الاعتماد', () => {
  assert.match(monthly, /file\.addEventListener\('change', reset\)/);
  assert.match(monthly, /commit\.disabled = true/);
  // ولا يُعتمَد ملفٌ لم يُعاين.
  assert.match(monthly, /if \(!parsed\) \{/);
});

test('المعاينة تعرض ما يحتاجه القرار قبل الكتابة', () => {
  for (const needle of [
    'p.fileName', 'p.sourceRowCount', 'p.events.length', 'p.duplicateCount',
    'p.rejectedCount', 'p.unparsedDates', 'p.period', 'p.months',
  ]) {
    assert.ok(monthly.includes(needle), `المعاينة لا تعرض ${needle}`);
  }
  // وتفصيلُ الأوراق بمُصيّر مركز الاستيراد نفسه — لا عرضَ ثانٍ لنفس الأرقام.
  assert.match(monthly, /renderSaasPreview\(p\.raw\)/);
  assert.match(monthly, /لم يُكتب على الخادم شيء بعد/);
});

test('شهر المعاينة بمنطقة العمل الوحيدة في الواجهة، لا بثابتٍ ثانٍ', () => {
  assert.match(importRun, /import \{ businessMonth \} from '\.\.\/\.\.\/domain\/time'/);
  assert.doesNotMatch(importRun, /Asia\/Baghdad/);
  assert.doesNotMatch(monthly, /Asia\/Baghdad/);
});

/* ---- وCSV تُقرأ فعلاً، لا أن تُقبَل في المُنتقي وحده ---------------------
 *
 * سمةُ `accept` تفتح نافذة الاختيار ولا تَعِد بشيء بعدها. فالاختبار التالي
 * يمرّ الملفَ في الطريق نفسه الذي تمرّ به الشاشة: `XLSX.read(buffer,
 * {type:'array'})` ثم `parseWorkbook` — بالمحلِّل المُورَّد نفسه. */

const XLSX = require(path.join(root, 'assets', 'vendor', 'xlsx.full.min.js'));
const SaasImport = require(path.join(root, 'assets', 'js', 'saas-import.js'));

test('ملف CSV يمرّ بالمحلِّل القائم ويُخرج أحداث تفعيل بتواريخها', () => {
  const csv = [
    'id,username,created_at,activations_count,parent,profile_name',
    '1,csv-user-a,2026-07-01 00:30:00,1,r.fixture.agent,P-35000',
    '2,csv-user-b,2026-07-31 23:30:00,1,r.fixture.agent,P-45000',
  ].join('\n');

  // نفسُ شكل النداء في `parseMonthlyActivationFile`: بايتات، لا نصّ.
  // نفسُ خيارات القراءة في `WORKBOOK_READ`: بايتات، وcellDates. وبدونها
  // تصل خليةُ التاريخ رقماً تسلسلياً فتسقط كلُّ تواريخ CSV بلا استثناء.
  const book = XLSX.read(new Uint8Array(Buffer.from(csv, 'utf8')),
    { type: 'array', cellDates: true });
  const sheets = book.SheetNames.map((name) => ({
    name, rows: XLSX.utils.sheet_to_json(book.Sheets[name], { defval: '' }),
  }));
  const preview = SaasImport.parseWorkbook(sheets, {});

  assert.equal(preview.events.length, 2, 'CSV لم تُخرج حدثين');
  assert.equal(preview.unparsedDates, 0, 'تواريخ CSV لم تُفهَم');
  assert.equal(preview.sourceRowCount, 2);
  assert.deepEqual(preview.events.map((e) => e.username_key).sort(),
    ['csv-user-a', 'csv-user-b']);
  // والطوابع مفهومة فعلاً: تُخزَّن بتوقيت UTC مع نسبة الملف إلى +03:00.
  // فمنتصفُ ليل بغداد يسبق UTC، ولذلك أوّلُ تمّوزٍ محلّياً هو الثلاثون من
  // حزيران عالمياً. الشهرُ يُشتقّ بالتوقيت المحلّي لا بالنصّ الخام.
  assert.deepEqual(
    preview.events.map((e) => String(e.event_created_at)).sort(),
    ['2026-06-30T21:30:00.000Z', '2026-07-31T20:30:00.000Z']);
  const month = (v) => new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Baghdad', year: 'numeric', month: '2-digit',
  }).format(new Date(v));
  preview.events.forEach((e) => {
    assert.equal(month(e.event_created_at), '2026-07',
      'طرفا الشهر لم يقعا في تمّوزٍ محلّيّاً — الإزاحة ضاعت');
  });
});

test('خيارات قراءة المصنَّف واحدةٌ في الشاشتين، وcellDates منها', () => {
  assert.ok(importRun.includes(
    "const WORKBOOK_READ = { type: 'array', cellDates: true } as const;"),
  'خيارات القراءة ليست ثابتاً واحداً');
  // ولا قراءةَ بخياراتٍ خاصّةٍ بشاشة: النداءان كلاهما على الثابت نفسه.
  assert.ok(!importRun.includes('xlsx.read(buffer, {'),
    'قراءةٌ بخياراتٍ مكتوبةٍ في موضعها بدل الثابت المشترك');
  assert.equal(importRun.split('xlsx.read(buffer, WORKBOOK_READ)').length - 1, 2);
});
