const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function createElement() {
  return {
    addEventListener() {},
    appendChild() {},
    classList: {
      add() {},
      remove() {},
      toggle() {},
    },
    dataset: {},
    disabled: false,
    innerHTML: '',
    querySelector() {
      return createElement();
    },
    style: {},
    textContent: '',
    value: '',
  };
}

function extractInlineApplicationScript(html) {
  const scripts = [...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/gi)]
    .map((match) => match[1])
    .filter((script) => script.trim());

  if (scripts.length !== 1) {
    throw new Error(`Expected one inline application script, found ${scripts.length}.`);
  }

  return scripts[0].replace(/\ninitAuth\(\);\s*$/, '\n');
}

function loadCurrentApp() {
  const htmlPath = path.join(__dirname, '..', 'index.html');
  const html = fs.readFileSync(htmlPath, 'utf8');
  const applicationScript = extractInlineApplicationScript(html);
  const storage = new Map();
  const document = {
    addEventListener() {},
    createElement,
    getElementById() {
      return createElement();
    },
    querySelectorAll() {
      return [];
    },
    visibilityState: 'visible',
  };

  const context = vm.createContext({
    Blob,
    Date,
    FileReader: function FileReader() {},
    Intl,
    JSON,
    Math,
    Number,
    Object,
    Set,
    String,
    URL: {
      createObjectURL() {
        return 'blob:test';
      },
      revokeObjectURL() {},
    },
    URLSearchParams,
    alert() {},
    confirm() {
      return true;
    },
    console,
    document,
    fetch: async () => {
      throw new Error('Network access is disabled in characterization tests.');
    },
    localStorage: {
      getItem(key) {
        return storage.has(key) ? storage.get(key) : null;
      },
      removeItem(key) {
        storage.delete(key);
      },
      setItem(key, value) {
        storage.set(key, String(value));
      },
    },
    prompt() {
      return null;
    },
    setInterval() {
      return 0;
    },
    setTimeout() {
      return 0;
    },
    window: {
      addEventListener() {},
    },
  });

  const exportsScript = `
    globalThis.__characterization = {
      calc,
      compareMonthKeys,
      defaultData,
      defaultTiers,
      getPreviousRow,
      monthKey,
      monthOrder,
      nextMonthKey,
      normalizeImport,
      parseCSV,
      state,
      status,
      tierFor
    };
  `;

  new vm.Script(applicationScript + exportsScript, {
    filename: 'index.inline.js',
  }).runInContext(context);

  return context.__characterization;
}

module.exports = { loadCurrentApp };
