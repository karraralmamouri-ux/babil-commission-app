// نسخة قاعدة البيانات الحقيقية عند الطلب: لا نختبر pg_dump نفسه (لا بيئة حقيقية
// هنا)، بل حواجز الأمان التي يجب أن تمنعه من التنفيذ أصلاً حين ينقص أي شرط —
// نفس نمط tests/project-guards.test.js لكن للسكربت الجديد.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const REPO = path.join(__dirname, '..');
const STAGING_REF = 'unohqhxubraelqgjhxgh';
const PRODUCTION_REF = 'fbgffpxpskjzgheheikd';

function runDump(args, env = {}) {
  const childEnv = { ...process.env, ...env };
  for (const name of [
    'SUPABASE_DB_URL', 'SUPABASE_STAGING_PROJECT_REF', 'SUPABASE_PRODUCTION_PROJECT_REF',
    'ALLOW_STAGING_DUMP', 'ALLOW_PRODUCTION_DUMP',
  ]) {
    if (!(name in env)) delete childEnv[name];
  }
  const result = spawnSync(process.execPath, [path.join(REPO, 'scripts', 'dump-database.mjs'), ...args], {
    encoding: 'utf8',
    env: childEnv,
  });
  return { code: result.status, out: `${result.stdout}${result.stderr}` };
}

test('بلا --target صحيح: رفض ولا محاولة تنفيذ', () => {
  const missing = runDump([]);
  assert.notEqual(missing.code, 0);
  assert.match(missing.out, /Usage:/);

  const bogus = runDump(['--target', 'nowhere']);
  assert.notEqual(bogus.code, 0);
  assert.match(bogus.out, /Usage:/);
});

test('بلا SUPABASE_DB_URL: رفض صريح، لا تخمين ولا اتصال افتراضي', () => {
  const result = runDump(['--target', 'staging'], {
    SUPABASE_STAGING_PROJECT_REF: STAGING_REF,
    ALLOW_STAGING_DUMP: 'true',
  });
  assert.notEqual(result.code, 0);
  assert.match(result.out, /REFUSING.*SUPABASE_DB_URL/);
});

test('بلا علم السماح الصريح: رفض حتى مع اتصال ومرجع صحيحين', () => {
  const result = runDump(['--target', 'staging'], {
    SUPABASE_DB_URL: `postgresql://postgres.${STAGING_REF}:pw@aws-0-x.pooler.supabase.com:6543/postgres`,
    SUPABASE_STAGING_PROJECT_REF: STAGING_REF,
  });
  assert.notEqual(result.code, 0);
  assert.match(result.out, /REFUSING.*ALLOW_STAGING_DUMP/);
});

test('اتصال يشير إلى مشروع آخر غير المرجع المُعلَن: رفض', () => {
  // نفس الفخ الذي يحرس منه assert-staging-project-ref.mjs: الرابط الصحيح لا
  // يعني أن سلسلة الاتصال الفعلية تشير إلى المشروع نفسه.
  const result = runDump(['--target', 'staging'], {
    SUPABASE_DB_URL: `postgresql://postgres.${PRODUCTION_REF}:pw@aws-0-x.pooler.supabase.com:6543/postgres`,
    SUPABASE_STAGING_PROJECT_REF: STAGING_REF,
    ALLOW_STAGING_DUMP: 'true',
  });
  assert.notEqual(result.code, 0);
  assert.match(result.out, /REFUSING/);
  assert.match(result.out, /does not appear to reference project/);
});

test('production وstaging لا يتشاركان علم السماح — تفعيل أحدهما لا يفتح الآخر', () => {
  const result = runDump(['--target', 'production'], {
    SUPABASE_DB_URL: `postgresql://postgres.${PRODUCTION_REF}:pw@aws-0-x.pooler.supabase.com:6543/postgres`,
    SUPABASE_PRODUCTION_PROJECT_REF: PRODUCTION_REF,
    ALLOW_STAGING_DUMP: 'true', // النية الخاطئة عمداً: أذن لـstaging لا لـproduction
  });
  assert.notEqual(result.code, 0);
  assert.match(result.out, /REFUSING.*ALLOW_PRODUCTION_DUMP/);
});

test('سلسلة الاتصال لا تُطبع أبداً — لا في رسائل النجاح المفترضة ولا الرفض', () => {
  const secret = 'sUpEr-sEcReT-pAsSwOrD-token';
  const result = runDump(['--target', 'staging'], {
    SUPABASE_DB_URL: `postgresql://postgres.${STAGING_REF}:${secret}@aws-0-x.pooler.supabase.com:6543/postgres`,
    SUPABASE_STAGING_PROJECT_REF: STAGING_REF,
    ALLOW_STAGING_DUMP: 'true',
  });
  assert.doesNotMatch(result.out, new RegExp(secret));
});

test('كل سكربت npm يمسّ Staging أو Production يستدعي حارسه أولاً', () => {
  const pkg = JSON.parse(fs.readFileSync(path.join(REPO, 'package.json'), 'utf8'));
  assert.match(pkg.scripts['dump:staging'], /^npm run guard:staging-ref &&/);
  assert.match(pkg.scripts['dump:production'], /^npm run guard:project-ref &&/);
});

test('السكربت يستخدم pg_dump بصيغة custom لا `supabase db dump` النصية', () => {
  // الأخيرة لا تدعم pg_restore --list الانتقائي المطلوب لاستبعاد DEFAULT ACL
  // — راجع docs/STAGING.md.
  const src = fs.readFileSync(path.join(REPO, 'scripts', 'dump-database.mjs'), 'utf8');
  assert.match(src, /'pg_dump'/);
  assert.match(src, /--format=custom/);
  assert.doesNotMatch(src, /supabase['"]\s*,\s*\[['"]db['"]\s*,\s*['"]dump/);
});
