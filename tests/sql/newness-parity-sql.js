// جانب الخادم من اختبار التكافؤ: يبني صفوفاً مكافئة للحالات ثم يقرأها
// بـclassify_newness الحقيقية. المخرج SQL يُغذّى إلى psql.
//
// كل حالة تحصل على دفعة استيراد خاصّة بها، لأن اكتمال المصدر خاصّية
// الدفعة لا الحدث.

const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..', '..');
const spec = JSON.parse(
  fs.readFileSync(path.join(root, 'tests', 'fixtures', 'newness-cases.json'), 'utf8'));

const q = (s) => `'${String(s).replace(/'/g, "''")}'`;
const uuid = (n) => `'70000000-0000-0000-0000-${String(n).padStart(12, '0')}'`;

const out = [];
out.push(`\\set ON_ERROR_STOP on`);
out.push(`\\pset tuples_only on`);
out.push(`\\pset format unaligned`);
out.push(`begin;`);

out.push(`insert into auth.users (id, email) values (${uuid(1)}, 'np@fixture.invalid')
  on conflict do nothing;`);
out.push(`insert into public.profiles (id, full_name, email, role, is_active)
  values (${uuid(1)}, 'NP', 'np@fixture.invalid', 'admin', true)
  on conflict (id) do update set role='admin', is_active=true;`);

for (const [code, category] of Object.entries(spec.packages)) {
  out.push(`insert into public.packages (code, name, semantic_category)
    values (${q(code)}, ${q(code)}, ${q(category)})
    on conflict (code) do update set semantic_category = excluded.semantic_category;`);
}

let n = 10;
let ev = 0;
for (const c of spec.cases) {
  const batch = uuid(++n);
  out.push(`insert into public.saas_import_batches
    (id, source_kind, source_filename, source_checksum, parser_version, completeness_status, status, imported_by)
    values (${batch}, 'ACTIVATION_EVENTS', ${q(c.key + '.xlsx')}, ${q('sha-' + c.key)}, 'test',
            ${q(c.completeness)}, 'imported', ${uuid(1)})
    on conflict do nothing;`);

  if (c.registryPreexisting) {
    out.push(`insert into public.installation_subscribers
      (subscriber_id, reseller, fdt, start_date, total_amount, created_by)
      values (${q(c.key)}, 'NP', 'NP-FDT', date '2026-01-01', 0, ${uuid(1)})
      on conflict do nothing;`);
  }

  out.push(`insert into public.subscriber_identities
    (username, identity_status, match_method, source_classification)
    values (${q(c.key)}, ${q(c.identityStatus)}, 'EXACT_USERNAME', 'RESELLER')
    on conflict do nothing;`);

  for (const e of c.events) {
    out.push(`insert into public.saas_activation_events
      (import_batch_id, saas_event_id, username, profile_name, canceled,
       activations_count, raw_parent, event_created_at)
      values (${batch}, ${q('NP-EV-' + (++ev))}, ${q(c.key)}, ${q(e.profile_name)},
              ${e.canceled ? 'true' : 'false'}, ${e.activations_count},
              'np.parent', timestamptz '2027-03-01 10:00+03')
      on conflict do nothing;`);
  }
}

out.push(`set local role authenticated;`);
out.push(`set local request.jwt.claim.sub = ${uuid(1)};`);

for (const c of spec.cases) {
  // الأعمدة بترتيب جانب JS نفسه ليُقارَن السطران حرفياً.
  out.push(`select concat_ws('|',
    d ->> 'username_key',
    d ->> 'classification',
    d ->> 'reason_code',
    coalesce(d ->> 'lifetime_activations_count', ''),
    d ->> 'observed_event_count',
    d ->> 'qualifying_paid_event_count',
    case when (d ->> 'registry_preexisting')::boolean then 't' else 'f' end,
    d ->> 'source_completeness')
  from (select public.classify_newness(${q(c.key)}) d) t;`);
}

out.push(`rollback;`);
process.stdout.write(out.join('\n') + '\n');
