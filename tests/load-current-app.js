const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { webcrypto } = require('node:crypto');
const { TextEncoder } = require('node:util');
const XLSX = require(path.join(__dirname, '..', 'assets', 'vendor', 'xlsx.full.min.js'));
// index.html loads this as a separate <script src>; the sandbox needs it too.
const InstallationFees = require(path.join(__dirname, '..', 'assets', 'js', 'installation-fees.js'));

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

function loadCurrentApp(options = {}) {
  const htmlPath = path.join(__dirname, '..', 'index.html');
  const html = fs.readFileSync(htmlPath, 'utf8');
  const applicationScript = extractInlineApplicationScript(html);
  const storage = options.storage || new Map();
  // Stable per-id elements so render functions can be inspected after they run.
  const elements = options.elements || new Map();
  const document = {
    addEventListener() {},
    createElement,
    elements,
    getElementById(id) {
      if (!elements.has(id)) {
        elements.set(id, createElement());
      }
      return elements.get(id);
    },
    querySelectorAll() {
      return [];
    },
    visibilityState: 'visible',
  };

  const context = vm.createContext({
    Blob,
    crypto: webcrypto,
    Date,
    FileReader: function FileReader() {},
    Intl,
    JSON,
    Math,
    Number,
    Object,
    Set,
    String,
    TextEncoder,
    Uint8Array,
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
    fetch: options.fetch || (async () => {
      throw new Error('Network access is disabled in characterization tests.');
    }),
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
    XLSX,
    InstallationFees,
  });

  const exportsScript = `
    globalThis.__characterization = {
      calc,
      calculateRawImport,
      syncTierGroupBasis,
      applyRawImportResult,
      agentHierarchySummaries,
      backupStateSnapshot,
      buildExcelReportWorkbook,
      applyCentralPaymentResult,
      buildCentralAuditLogs,
      buildCentralPeriods,
      compareMonthKeys,
      createBackupDocument,
      createPeriodArchiveDocument,
      defaultData,
      defaultTiers,
      getSbSession,
      getPreviousRow,
      monthKey,
      monthOrder,
      renderAgentHierarchy,
      renderInstallation,
      showInstallationImportPreview,
      installationState,
      installationPaymentReview,
      installationExportRows,
      buildInstallationWorkbook,
      filteredInstallationRows,
      newZoneAgentTotals,
      newZoneFdtAgentExportRows,
      newZoneFdtBreakdown,
      newZoneOwnerSummaries,
      nextMonthKey,
      normalizeImport,
      parseCSV,
      preserveExistingCentralPayments,
      recordCentralPayment,
      rowsForCentralPublish,
      refreshSbSession,
      ROLE_PERMISSIONS,
      sessionExpiresSoon,
      setSbSession,
      state,
      status,
      tierFor,
      validatePeriodArchiveSnapshot,
      verifyBackupDocument,
      verifyPeriodArchiveDocument
    };
  `;

  new vm.Script(applicationScript + exportsScript, {
    filename: 'index.inline.js',
  }).runInContext(context);

  return Object.assign(context.__characterization, { __elements: elements });
}

module.exports = { loadCurrentApp };
