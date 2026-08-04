const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const vendorPath = path.join(__dirname, '..', 'assets', 'vendor', 'xlsx.full.min.js');

test('HTML loads the vendored SheetJS file from an existing path', () => {
  const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');

  assert.match(html, /<script src="\.\/assets\/vendor\/xlsx\.full\.min\.js"><\/script>/);
  assert.doesNotMatch(html, /index_files\/xlsx\.full\.min\.js\.download/);
  assert.equal(fs.existsSync(vendorPath), true);
});

test('vendored SheetJS file matches the reviewed upstream artifact', () => {
  const digest = crypto.createHash('sha256').update(fs.readFileSync(vendorPath)).digest('hex');

  assert.equal(digest, 'cc015130aa8521e7f088f88898eba949ccdcbfb38df0bd129b44b7273c3a6f41');
});

test('vendored SheetJS version can round-trip an XLSX workbook', () => {
  const XLSX = require(vendorPath);
  const expected = [
    { Name: 'Agent One', Zone: 'OLD', P35: 12 },
    { Name: 'FDT-200', Zone: 'NEW', P35: 25 },
  ];
  const workbook = XLSX.utils.book_new();
  const worksheet = XLSX.utils.json_to_sheet(expected);

  assert.equal(XLSX.version, '0.20.3');
  XLSX.utils.book_append_sheet(workbook, worksheet, 'Commissions');

  const bytes = XLSX.write(workbook, { bookType: 'xlsx', type: 'buffer' });
  const parsed = XLSX.read(bytes, { type: 'buffer' });
  const rows = XLSX.utils.sheet_to_json(parsed.Sheets.Commissions, { defval: '' });

  assert.deepEqual(rows, expected);
});
