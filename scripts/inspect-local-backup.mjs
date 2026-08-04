import fs from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';

const MONTH_KEY = /^(0[1-9]|1[0-2])\/\d{4}$/;
const ZONES = ['old', 'new'];
const TIER_KEYS = new Set(['auto', 't1', 't2', 't3']);

function sha256(value) {
  return createHash('sha256').update(value, 'utf8').digest('hex');
}

function finiteNonnegative(value, label, errors) {
  const number = Number(value);
  if (!Number.isFinite(number) || number < 0) {
    errors.push(`${label} must be a non-negative number`);
    return 0;
  }
  return number;
}

function matchingTier(tiers, quantity, selectedKey, errors, context) {
  if (!TIER_KEYS.has(selectedKey)) {
    errors.push(`${context}.customTier is invalid`);
    return null;
  }

  const tier = selectedKey === 'auto'
    ? tiers
        .filter((item) => {
          const min = Number(item?.min ?? 0);
          const max = item?.max == null ? Number.POSITIVE_INFINITY : Number(item.max);
          return Number.isFinite(min) && quantity >= min && quantity <= max;
        })
        .sort((a, b) => Number(b?.min ?? 0) - Number(a?.min ?? 0))[0]
    : tiers.find((item) => item?.key === selectedKey);

  if (!tier) {
    errors.push(`${context} has no matching tier`);
    return null;
  }

  return tier;
}

export function summarizeSnapshot(snapshot, label = 'current') {
  const errors = [];
  const tiers = Array.isArray(snapshot?.tiers) ? snapshot.tiers : [];
  const data = snapshot?.data && typeof snapshot.data === 'object' ? snapshot.data : {};
  const result = {
    label,
    agents: 0,
    quantity: { p35: 0, p45: 0, p65: 0, total: 0 },
    due: 0,
    paid: 0,
    remaining: 0,
    zones: { old: 0, new: 0 },
    errors,
  };

  if (tiers.length === 0) {
    errors.push(`${label}.tiers must be a non-empty array`);
  }

  for (const zone of ZONES) {
    const rows = Array.isArray(data[zone]) ? data[zone] : [];
    if (!Array.isArray(data[zone])) {
      errors.push(`${label}.data.${zone} must be an array`);
    }

    const seenNames = new Set();
    for (let index = 0; index < rows.length; index += 1) {
      const row = rows[index] ?? {};
      const context = `${label}.data.${zone}[${index}]`;
      const name = String(row.name ?? '').trim();
      if (!name) errors.push(`${context}.name is required`);
      if (seenNames.has(name)) errors.push(`${context}.name is duplicated in the zone`);
      seenNames.add(name);

      const p35 = finiteNonnegative(row.p35, `${context}.p35`, errors);
      const p45 = finiteNonnegative(row.p45, `${context}.p45`, errors);
      const p65 = finiteNonnegative(row.p65, `${context}.p65`, errors);
      const paid = finiteNonnegative(row.paid, `${context}.paid`, errors);
      const quantity = p35 + p45 + p65;
      const tier = matchingTier(tiers, quantity, row.customTier ?? 'auto', errors, context);

      let due = 0;
      if (tier) {
        const rate35 = finiteNonnegative(tier.p35, `${context}.tier.p35`, errors);
        const rate45 = finiteNonnegative(tier.p45, `${context}.tier.p45`, errors);
        const rate65 = finiteNonnegative(tier.p65, `${context}.tier.p65`, errors);
        due = p35 * rate35 + p45 * rate45 + p65 * rate65;
      }

      if (paid > due) errors.push(`${context}.paid exceeds amount due`);

      result.agents += 1;
      result.zones[zone] += 1;
      result.quantity.p35 += p35;
      result.quantity.p45 += p45;
      result.quantity.p65 += p65;
      result.quantity.total += quantity;
      result.due += due;
      result.paid += paid;
      result.remaining += Math.max(0, due - paid);
    }
  }

  return result;
}

export function inspectBackupDocument(document) {
  const errors = [];

  if (!document || document.format !== 'babil-commission-backup') {
    errors.push('backup format is invalid');
  }
  if (document?.version !== 1) errors.push('backup version is not supported');
  if (document?.integrity?.algorithm !== 'SHA-256') {
    errors.push('backup integrity algorithm is invalid');
  }
  if (document?.integrity?.scope !== 'state') {
    errors.push('backup integrity scope is invalid');
  }
  if (!document?.state || typeof document.state !== 'object') {
    errors.push('backup state is missing');
  }

  const computedChecksum = document?.state
    ? sha256(JSON.stringify(document.state))
    : null;
  if (computedChecksum !== document?.integrity?.value) {
    errors.push('backup checksum does not match its state');
  }

  const currentMonth = document?.state?.month;
  if (!MONTH_KEY.test(String(currentMonth ?? ''))) {
    errors.push('current month key is invalid');
  }

  const current = summarizeSnapshot(document?.state, `current:${currentMonth ?? 'unknown'}`);
  const archive = document?.state?.archive && typeof document.state.archive === 'object'
    ? document.state.archive
    : {};
  const archived = [];

  for (const month of Object.keys(archive).sort()) {
    if (!MONTH_KEY.test(month)) errors.push(`archive month key is invalid: ${month}`);
    archived.push(summarizeSnapshot(archive[month], `archive:${month}`));
  }

  const snapshotErrors = [current, ...archived].flatMap((item) => item.errors);
  errors.push(...snapshotErrors);

  return {
    valid: errors.length === 0,
    format: document?.format ?? null,
    version: document?.version ?? null,
    exportedAt: document?.exportedAt ?? null,
    currentMonth: currentMonth ?? null,
    checksum: {
      expected: document?.integrity?.value ?? null,
      computed: computedChecksum,
      matches: computedChecksum === document?.integrity?.value,
    },
    auditEvents: Array.isArray(document?.state?.auditLog)
      ? document.state.auditLog.length
      : 0,
    current,
    archived,
    errors,
  };
}

async function main() {
  const file = process.argv[2];
  if (!file) {
    throw new Error('Usage: node scripts/inspect-local-backup.mjs <backup.json>');
  }

  const document = JSON.parse(await fs.readFile(file, 'utf8'));
  const report = inspectBackupDocument(document);
  console.log(JSON.stringify(report, null, 2));
  if (!report.valid) process.exitCode = 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
