const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');

function tsFiles(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    return entry.isDirectory() ? tsFiles(full) : entry.name.endsWith('.ts') ? [full] : [];
  });
}

test('لا يبقى fallback صامت يحوّل فشل قراءة تشغيلية إلى بيانات فارغة', () => {
  const offenders = [];
  for (const file of tsFiles(path.join(root, 'src'))) {
    const source = fs.readFileSync(file, 'utf8')
      .replace(/\/\*[\s\S]*?\*\//g, '')
      .replace(/\/\/.*$/gm, '');
    if (/\.catch\(\(\) => (?:null|\[\]|0)\)/.test(source)) {
      offenders.push(path.relative(root, file));
    }
  }
  assert.deepEqual(offenders, []);
});

test('هوية المتصفح تستخدم اسم BABIL FLOW وألوانه وأيقونته نفسها', () => {
  const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
  const mark = fs.readFileSync(path.join(root, 'assets', 'brand', 'babil-flow-mark.svg'), 'utf8');
  assert.match(html, /<title>BABIL FLOW — Reseller Financial Operations<\/title>/);
  assert.match(html, /name="theme-color" content="#0B1930"/);
  assert.match(html, /rel="icon"[^>]+babil-flow-mark\.svg/);
  assert.match(mark, /fill="#0B1930"/);
  assert.match(mark, /#E3B75A/);
  assert.match(mark, /#A87C1E/);
});
