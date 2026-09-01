/**
 * نسخة احتياطية يدوية عند الطلب لقاعدة بيانات Supabase الحقيقية (Staging أو
 * Production) — لا نسخ مجدولة تلقائياً بعد (راجع R-015 في docs/RISK_REGISTER.md
 * وقرار خطة Supabase المدفوعة/PITR في docs/BUSINESS_DECISIONS_REQUIRED.md).
 *
 * يُصدر custom-format dump عبر pg_dump مباشرة (لا `supabase db dump`، التي
 * تنتج SQL نصياً فقط ولا تدعم pg_restore --list الانتقائي المستخدم لاستبعاد
 * DEFAULT ACL — الإجراء المُختبر فعلياً وموثَّق في docs/STAGING.md).
 *
 * سلسلة الاتصال لا تُقرأ من .env ولا من أي ملف؛ تُقرأ من متغيّر بيئة عند
 * التشغيل فقط، ولا تُطبع أبداً — لا في stdout ولا في رسائل الخطأ.
 */

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const TARGETS = {
  staging: {
    refVar: 'SUPABASE_STAGING_PROJECT_REF',
    allowVar: 'ALLOW_STAGING_DUMP',
  },
  production: {
    refVar: 'SUPABASE_PRODUCTION_PROJECT_REF',
    allowVar: 'ALLOW_PRODUCTION_DUMP',
  },
};

function usage() {
  console.error(
    'Usage: SUPABASE_DB_URL=... SUPABASE_<TARGET>_PROJECT_REF=... ALLOW_<TARGET>_DUMP=true \\\n' +
    '       node scripts/dump-database.mjs --target staging|production\n' +
    '\n' +
    'Never pass the connection string on the command line — it would land in shell\n' +
    'history and process listings. Export it as an environment variable instead.'
  );
}

function parseTarget(argv) {
  const flagIndex = argv.indexOf('--target');
  const value = flagIndex === -1 ? undefined : argv[flagIndex + 1];
  if (!value || !(value in TARGETS)) {
    usage();
    process.exit(1);
  }
  return value;
}

function requireEnv(name) {
  const value = process.env[name];
  if (!value) {
    console.error(`REFUSING: ${name} is required and was not set.`);
    process.exit(1);
  }
  return value;
}

function main() {
  const target = parseTarget(process.argv.slice(2));
  const { refVar, allowVar } = TARGETS[target];

  const dbUrl = requireEnv('SUPABASE_DB_URL');
  const projectRef = requireEnv(refVar);
  const allow = process.env[allowVar];

  if (allow !== 'true') {
    console.error(`REFUSING: ${allowVar}=true is required to dump ${target}. This is a deliberate friction — not a default-on operation.`);
    process.exit(1);
  }

  if (!dbUrl.includes(projectRef)) {
    console.error(
      `REFUSING: SUPABASE_DB_URL does not appear to reference project ${projectRef} ` +
      `(${refVar}). Re-check which project this connection string points to before dumping ${target}.`
    );
    process.exit(1);
  }

  const backupsDir = path.join(process.cwd(), 'backups');
  fs.mkdirSync(backupsDir, { recursive: true });

  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const outFile = path.join(backupsDir, `${target}-public-${stamp}.dump`);

  console.log(`Dumping schema+data for ${target} (project ${projectRef}) to ${outFile} ...`);

  try {
    execFileSync(
      'pg_dump',
      [dbUrl, '--schema=public', '--format=custom', '--no-owner', '--file', outFile],
      { stdio: ['ignore', 'pipe', 'pipe'] },
    );
  } catch (error) {
    // execFileSync يُرفق سلسلة الاتصال داخل spawnargs عند الفشل، ومعالج
    // node الافتراضي لاستثناء غير ملتقَط يطبع الكائن كاملاً — فتُطبع كلمة
    // المرور في stderr. لذلك: لا رمي الخطأ الأصلي مطلقاً، رسالة مُقتضَبة فقط.
    const detail = (error.stderr || error.message || '').toString().replaceAll(dbUrl, '<redacted>');
    console.error(`REFUSING: pg_dump failed for ${target}.\n${detail}`);
    process.exit(1);
  }

  const bytes = fs.readFileSync(outFile);
  const checksum = createHash('sha256').update(bytes).digest('hex');

  console.log(`OK: ${bytes.length} bytes written.`);
  console.log(`SHA-256: ${checksum}`);
  console.log(
    'Restore test (do this on a scratch database, never directly on a live target):\n' +
    `  pg_restore --list ${outFile} > /tmp/toc.txt   # inspect, exclude DEFAULT ACL entries owned by supabase_admin\n` +
    `  pg_restore --clean --if-exists --no-owner --exit-on-error --use-list=<edited toc> --dbname=<scratch> ${outFile}\n` +
    'Full context: docs/STAGING.md ("اختبار النسخ والاسترجاع").'
  );
}

main();
