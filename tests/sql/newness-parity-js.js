// جانب المتصفّح من اختبار التكافؤ.
//
// يستدعي classifyNewness الحقيقية من assets/js/saas-import.js — لا نسخة
// منها هنا، وإلا لاختُبرت النسخة بدل ما يعمل فعلاً.

const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..', '..');
const { classifyNewness } = require(path.join(root, 'assets', 'js', 'saas-import.js'));
const spec = JSON.parse(
  fs.readFileSync(path.join(root, 'tests', 'fixtures', 'newness-cases.json'), 'utf8'));

const packageCategory = new Map(Object.entries(spec.packages));

for (const c of spec.cases) {
  const out = classifyNewness({
    registryPreexisting: c.registryPreexisting,
    identityStatus: c.identityStatus,
    sourceCompleteness: c.completeness,
    events: c.events.map((e) => ({
      profile_name: e.profile_name,
      activations_count: e.activations_count,
      canceled: e.canceled,
    })),
    packageCategory,
  });

  // ويُتحقَّق أن الحالة نفسها ما زالت تعني ما وُضعت له: انحرافُ القاعدتين
  // معاً عن التوقّع المكتوب لا يُخفيه التطابق بينهما.
  if (out.classification !== c.expect.classification || out.reason_code !== c.expect.reason_code) {
    console.error(`FAILED: ${c.key} — JS قال ${out.classification}/${out.reason_code}`
      + ` والمتوقَّع ${c.expect.classification}/${c.expect.reason_code}`);
    process.exit(1);
  }

  console.log([
    c.key,
    out.classification,
    out.reason_code,
    out.lifetime_activations_count === null ? '' : out.lifetime_activations_count,
    out.observed_event_count,
    out.qualifying_paid_event_count,
    out.registry_preexisting ? 't' : 'f',
    out.source_completeness,
  ].join('|'));
}
