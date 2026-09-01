const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

// Non-financial, repo-only guard: makes sure no requirement ID in the Master
// Requirements Register can silently fall out of the Master Requirements
// Audit's coverage table. Touches no Supabase project and no financial data.

const REGISTER_PATH = path.join(__dirname, '..', 'docs', 'MASTER_REQUIREMENTS_REGISTER.md');
const AUDIT_PATH = path.join(__dirname, '..', 'docs', 'MASTER_REQUIREMENTS_AUDIT.md');

const APPROVED_STATUSES = [
  'PASS',
  'PARTIAL',
  'MISSING',
  'VERIFY',
  'DECISION REQUIRED',
  'REPLACED',
  'CANCELLED BY AGREEMENT',
  'OUT OF SCOPE — OPERATIONS',
];

// The register's 18 requirement-ID namespaces. Deliberately excludes DEC-*
// ("Explicit business decisions still required") — those are pointers into
// the requirements below, not requirement IDs themselves.
const ID_PREFIX = '(?:CFG|USR|CLS|COM|ZON|INS|INV|HLD|PAY|CYC|OWN|IMP|FREE|HIST|ARC|SEC|UX|OPS)';

function readRegisterIds() {
  const text = fs.readFileSync(REGISTER_PATH, 'utf8');
  const ids = [];
  const re = new RegExp(`^- (${ID_PREFIX}-\\d{3}):`, 'gm');
  let m;
  while ((m = re.exec(text)) !== null) {
    ids.push(m[1]);
  }
  return ids;
}

// Table rows look like: | CFG-001 | requirement text | STATUS | code | db | ui | test | notes |
// The status is always the 3rd pipe-delimited cell. A row can also carry a
// single OPS-style 3-column table (ID | Requirement | Status).
// Only "## 2. Requirements Coverage" is parsed — later sections (§5, §7, ...)
// reference IDs in prose/tables for narrative purposes and are not the
// per-ID coverage matrix itself.
function coverageSectionText() {
  const text = fs.readFileSync(AUDIT_PATH, 'utf8');
  const start = text.indexOf('## 2. Requirements Coverage');
  const end = text.indexOf('\n## 3. ', start);
  assert.ok(start !== -1, '"## 2. Requirements Coverage" heading not found in audit report');
  assert.ok(end !== -1, '"## 3. " heading not found after the coverage section');
  return text.slice(start, end);
}

function readAuditRows() {
  const text = coverageSectionText();
  const rows = [];
  const re = new RegExp(`^\\|\\s*(${ID_PREFIX}-\\d{3})\\s*\\|(.*)\\|\\s*$`, 'gm');
  let m;
  while ((m = re.exec(text)) !== null) {
    const id = m[1];
    const rest = m[2];
    const cells = rest.split('|').map((c) => c.trim());
    // First remaining cell is the requirement text, second is the status.
    const status = cells[1];
    rows.push({ id, status, line: text.slice(0, m.index).split('\n').length });
  }
  return rows;
}

test('every requirement ID in the Master Register is unique', () => {
  const ids = readRegisterIds();
  assert.ok(ids.length > 0, 'expected to find requirement IDs in the register');
  const seen = new Set();
  const duplicates = [];
  for (const id of ids) {
    if (seen.has(id)) duplicates.push(id);
    seen.add(id);
  }
  assert.deepEqual(duplicates, [], `duplicate requirement IDs found: ${duplicates.join(', ')}`);
});

test('every Master Register requirement ID appears in the Master Requirements Audit coverage table', () => {
  const registerIds = new Set(readRegisterIds());
  const auditRows = readAuditRows();
  const auditIds = new Set(auditRows.map((r) => r.id));

  const missing = [...registerIds].filter((id) => !auditIds.has(id));
  assert.deepEqual(
    missing,
    [],
    `requirement IDs present in the register but missing from the audit report: ${missing.join(', ')}`
  );
});

test('no requirement ID in the audit report is missing from the register (no phantom IDs)', () => {
  const registerIds = new Set(readRegisterIds());
  const auditRows = readAuditRows();
  const phantom = [...new Set(auditRows.map((r) => r.id))].filter((id) => !registerIds.has(id));
  assert.deepEqual(
    phantom,
    [],
    `requirement IDs present in the audit report but not defined in the register: ${phantom.join(', ')}`
  );
});

test('the audit report uses only the approved status vocabulary', () => {
  const auditRows = readAuditRows();
  const invalid = auditRows.filter((r) => !APPROVED_STATUSES.includes(r.status));
  assert.deepEqual(
    invalid,
    [],
    `rows using a non-approved status: ${invalid
      .map((r) => `${r.id} (line ${r.line}): "${r.status}"`)
      .join('; ')}`
  );
});

test('the audit report status counts sum to the total number of register IDs', () => {
  const registerIds = readRegisterIds();
  const auditRows = readAuditRows();

  // Only count the first occurrence per ID (the coverage-table row), in case
  // an ID is also referenced elsewhere in prose (e.g. inside §3-§10 tables).
  const seen = new Map();
  for (const row of auditRows) {
    if (!seen.has(row.id)) seen.set(row.id, row.status);
  }

  assert.equal(
    seen.size,
    registerIds.length,
    `expected ${registerIds.length} classified IDs in the audit's coverage table, found ${seen.size}`
  );
});
