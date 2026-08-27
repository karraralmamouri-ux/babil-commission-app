// LIVE-07: مُنتقي الوكيل في شاشة نقل العائدية يعود فارغاً بعد كل إعادة رسم.
//
// السبب: draw() كانت تنادي wire(target) بلا الوكيل المُختار، فتُعاد قائمة
// <option> من الصفر بلا selected — فيبدو الاختيار قد سقط رغم أنه لم يتغيّر.
// الإصلاح: agentId يُمرَّر عبر السلسلة كلّها — reread() يقرأه من agent.value
// الحيّ، draw() يستقبله، wire() يبنيه في القائمة الجديدة.
//
// الاختبار الأول يُثبت السلسلة نصّاً (لا تُكتشف الوصلة المفقودة إلا هكذا:
// كل حلقة بمفردها صحيحة، والعطل في الوصل بينها). والثاني يُنفِّذ تعبير بناء
// <option> فعلياً كما هو في المصدر — لا نسخة مُعاد كتابتها يدوياً.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const transfer = fs.readFileSync(path.join(root, 'src', 'features', 'ownership', 'transfer.ts'), 'utf8')
  .split('\r\n').join('\n');

test('agentId يُمرَّر عبر draw → wire، ومن agent.value الحيّ عند كل إعادة قراءة', () => {
  // draw تستقبل agentId وتُمرِّره لـwire — لا تعيد بناء القائمة بلا معرفة من كان مختاراً.
  assert.match(transfer, /const draw = async \(target: string, agentId: string, from: string\) => \{/);
  assert.match(transfer, /await wire\(target, agentId\);/);
  assert.match(transfer, /const wire = async \(target: string, agentId: string\) => \{/);

  // وإعادة القراءة عند أي تغيير تقرأ الوكيل المختار حالياً من الـDOM الحيّ،
  // لا من إغلاقٍ قديم قد يحمل قيمة الفتح الأولى.
  assert.match(transfer, /const reread = \(\) => void draw\(t\.value, agent\.value, from\.value\);/);
});

test('القائمة المُعاد بناؤها تُعلِّم خيار الوكيل المختار فعلياً، لا الأول ولا لا شيء', () => {
  const start = transfer.indexOf('(list || []).map((a) => {');
  const end = transfer.indexOf("}).join('');", start) + "}).join('');".length;
  assert.ok(start > 0 && end > start, 'تعبير بناء قائمة <option> لم يوجد بالشكل المتوقَّع');
  const mapExpr = transfer.slice(start, end);

  const str = (r, k) => String(r[k] ?? '');
  const esc = (v) => String(v ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;');

  const list = [
    { id: 'agent-1', official_name: 'وكيل واحد' },
    { id: 'agent-2', official_name: 'وكيل اثنان' },
  ];

  const run = (agentId) => new Function('list', 'str', 'esc', 'agentId', `return ${mapExpr}`)(list, str, esc, agentId);

  const htmlNoneSelected = run('');
  assert.doesNotMatch(htmlNoneSelected, /selected/);

  const htmlAgent2Selected = run('agent-2');
  const options = htmlAgent2Selected.split('<option').slice(1);
  const withSelected = options.filter((o) => /selected/.test(o));
  assert.equal(withSelected.length, 1, 'خيارٌ واحد بالضبط يجب أن يُعلَّم');
  assert.match(withSelected[0], /value="agent-2"/);
});
