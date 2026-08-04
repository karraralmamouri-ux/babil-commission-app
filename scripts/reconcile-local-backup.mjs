import fs from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

import { inspectBackupDocument, summarizeSnapshot } from './inspect-local-backup.mjs';

const MONTH_KEY = /^(0[1-9]|1[0-2])\/\d{4}$/;
const ZONES = ['old', 'new'];

function stableJson(value) {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stableJson(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function normalizedTier(tier) {
  return {
    key: String(tier?.key ?? ''),
    label: String(tier?.label ?? ''),
    min: Number(tier?.min ?? 0),
    max: tier?.max == null ? null : Number(tier.max),
    p35: Number(tier?.p35 ?? 0),
    p45: Number(tier?.p45 ?? 0),
    p65: Number(tier?.p65 ?? 0),
  };
}

function normalizedRow(row, zone) {
  return {
    zone,
    name: String(row?.name ?? '').trim(),
    p35: Number(row?.p35 ?? 0),
    p45: Number(row?.p45 ?? 0),
    p65: Number(row?.p65 ?? 0),
    customTier: String(row?.customTier ?? row?.custom_tier ?? 'auto'),
    paid: Number(row?.paid ?? 0),
    paymentDate: row?.paymentDate ?? row?.payment_date ?? null,
  };
}

function normalizedPeriod(snapshot) {
  const rows = [];
  for (const zone of ZONES) {
    for (const row of snapshot?.data?.[zone] ?? []) rows.push(normalizedRow(row, zone));
  }
  rows.sort((left, right) => `${left.zone}\u0000${left.name}`.localeCompare(`${right.zone}\u0000${right.name}`));
  const tiers = (snapshot?.tiers ?? []).map(normalizedTier).sort((left, right) => left.key.localeCompare(right.key));
  return { rows, tiers };
}

function periodContent(snapshot) {
  return stableJson(normalizedPeriod(snapshot));
}

function publicSummary(snapshot, label) {
  const summary = summarizeSnapshot(snapshot, label);
  return {
    agents: summary.agents,
    quantity: summary.quantity,
    due: summary.due,
    paid: summary.paid,
    remaining: summary.remaining,
    zones: summary.zones,
    errors: summary.errors,
  };
}

function rowMap(snapshot, errors, label) {
  const map = new Map();
  for (const row of normalizedPeriod(snapshot).rows) {
    const key = `${row.zone}\u0000${row.name}`;
    if (map.has(key)) errors.push(`${label} contains a duplicate zone/name identity`);
    map.set(key, row);
  }
  return map;
}

function compareSameMonth(month, localSnapshot, centralSnapshot, errors) {
  const localRows = rowMap(localSnapshot, errors, `local:${month}`);
  const centralRows = rowMap(centralSnapshot, errors, `central:${month}`);
  let onlyLocal = 0;
  let onlyCentral = 0;
  let changed = 0;
  const fieldDifferences = {
    p35: { rows: 0, localMinusCentral: 0 },
    p45: { rows: 0, localMinusCentral: 0 },
    p65: { rows: 0, localMinusCentral: 0 },
    paid: { rows: 0, localMinusCentral: 0 },
    customTier: { rows: 0 },
    paymentDate: { rows: 0 },
  };

  for (const [key, localRow] of localRows) {
    const centralRow = centralRows.get(key);
    if (!centralRow) onlyLocal += 1;
    else if (stableJson(localRow) !== stableJson(centralRow)) {
      changed += 1;
      for (const field of ['p35', 'p45', 'p65', 'paid']) {
        if (localRow[field] !== centralRow[field]) {
          fieldDifferences[field].rows += 1;
          fieldDifferences[field].localMinusCentral += localRow[field] - centralRow[field];
        }
      }
      for (const field of ['customTier', 'paymentDate']) {
        if (localRow[field] !== centralRow[field]) fieldDifferences[field].rows += 1;
      }
    }
  }
  for (const key of centralRows.keys()) {
    if (!localRows.has(key)) onlyCentral += 1;
  }

  const localPeriod = normalizedPeriod(localSnapshot);
  const centralPeriod = normalizedPeriod(centralSnapshot);
  return {
    month,
    exactMatch: stableJson(localPeriod) === stableJson(centralPeriod),
    tiersMatch: stableJson(localPeriod.tiers) === stableJson(centralPeriod.tiers),
    rows: {
      local: localRows.size,
      central: centralRows.size,
      onlyLocal,
      onlyCentral,
      changed,
    },
    fieldDifferences,
    local: publicSummary(localSnapshot, `local:${month}`),
    central: publicSummary(centralSnapshot, `central:${month}`),
  };
}

function localPeriods(document) {
  const periods = new Map();
  periods.set(document.state.month, {
    data: document.state.data,
    tiers: document.state.tiers,
  });
  for (const [month, snapshot] of Object.entries(document.state.archive ?? {})) {
    periods.set(month, snapshot);
  }
  return periods;
}

function centralPeriods(months, rows, errors) {
  const periods = new Map();
  const monthIds = new Map();

  for (const month of months) {
    const key = String(month?.month_key ?? '');
    const id = String(month?.id ?? '');
    if (!MONTH_KEY.test(key)) errors.push('central export contains an invalid month key');
    if (!id) errors.push(`central:${key || 'unknown'} is missing an id`);
    if (periods.has(key)) errors.push(`central export contains duplicate month ${key}`);
    periods.set(key, { data: { old: [], new: [] }, tiers: month?.tiers ?? [] });
    monthIds.set(id, key);
  }

  for (const row of rows) {
    const month = monthIds.get(String(row?.month_id ?? ''));
    if (!month) {
      errors.push('central export contains a row with an unknown month id');
      continue;
    }
    const zone = String(row?.zone ?? '');
    if (!ZONES.includes(zone)) {
      errors.push(`central:${month} contains an invalid zone`);
      continue;
    }
    periods.get(month).data[zone].push(row);
  }

  return periods;
}

export function reconcileBackupWithCentralExport(document, months, rows) {
  const backup = inspectBackupDocument(document);
  const errors = [...backup.errors];
  if (!Array.isArray(months)) errors.push('commission_months export must be an array');
  if (!Array.isArray(rows)) errors.push('commission_rows export must be an array');

  if (!backup.valid || !Array.isArray(months) || !Array.isArray(rows)) {
    return { valid: false, readOnly: true, errors };
  }

  const local = localPeriods(document);
  const central = centralPeriods(months, rows, errors);
  const localMonths = [...local.keys()].sort();
  const centralMonths = [...central.keys()].sort();
  const sameMonthComparisons = localMonths
    .filter((month) => central.has(month))
    .map((month) => compareSameMonth(month, local.get(month), central.get(month), errors));
  const localOnlyMonths = localMonths.filter((month) => !central.has(month));
  const centralOnlyMonths = centralMonths.filter((month) => !local.has(month));
  const contentEquivalentAcrossMonths = [];

  for (const localMonth of localMonths) {
    const localContent = periodContent(local.get(localMonth));
    const centralMatches = centralMonths.filter(
      (centralMonth) => periodContent(central.get(centralMonth)) === localContent,
    );
    if (centralMatches.length > 0) {
      contentEquivalentAcrossMonths.push({ localMonth, centralMonths: centralMatches });
    }
  }

  const closestCentralComparisons = localOnlyMonths.flatMap((localMonth) =>
    centralMonths.map((centralMonth) => ({
      localMonth,
      centralMonth,
      ...compareSameMonth(
        `${localMonth}->${centralMonth}`,
        local.get(localMonth),
        central.get(centralMonth),
        errors,
      ),
    })));
  const centralContentGroups = new Map();
  for (const month of centralMonths) {
    const content = periodContent(central.get(month));
    centralContentGroups.set(content, [...(centralContentGroups.get(content) ?? []), month]);
  }
  const duplicateCentralContent = [...centralContentGroups.values()].filter((group) => group.length > 1);

  const sameMonthReconciled = localOnlyMonths.length === 0
    && sameMonthComparisons.every((comparison) => comparison.exactMatch);
  const everyLocalContentExistsCentrally = localMonths.every((localMonth) =>
    contentEquivalentAcrossMonths.some((match) => match.localMonth === localMonth));
  const localSummaries = localMonths.map((month) => ({
    month,
    ...publicSummary(local.get(month), `local:${month}`),
  }));
  const centralSummaries = centralMonths.map((month) => ({
    month,
    ...publicSummary(central.get(month), `central:${month}`),
  }));
  errors.push(...localSummaries.flatMap((summary) => summary.errors));
  errors.push(...centralSummaries.flatMap((summary) => summary.errors));

  return {
    valid: errors.length === 0,
    readOnly: true,
    backupChecksumMatches: backup.checksum.matches,
    localMonths,
    centralMonths,
    localOnlyMonths,
    centralOnlyMonths,
    sameMonthReconciled,
    everyLocalContentExistsCentrally,
    safeToAutoImport: false,
    localSummaries,
    centralSummaries,
    sameMonthComparisons,
    closestCentralComparisons,
    contentEquivalentAcrossMonths,
    duplicateCentralContent,
    errors,
  };
}

async function main() {
  const [backupFile, centralExportDirectory] = process.argv.slice(2);
  if (!backupFile || !centralExportDirectory) {
    throw new Error('Usage: node scripts/reconcile-local-backup.mjs <backup.json> <central-export-directory>');
  }

  const [document, months, rows] = await Promise.all([
    fs.readFile(backupFile, 'utf8').then(JSON.parse),
    fs.readFile(path.join(centralExportDirectory, 'commission_months.json'), 'utf8').then(JSON.parse),
    fs.readFile(path.join(centralExportDirectory, 'commission_rows.json'), 'utf8').then(JSON.parse),
  ]);
  const report = reconcileBackupWithCentralExport(document, months, rows);
  console.log(JSON.stringify(report, null, 2));
  if (!report.valid) process.exitCode = 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
