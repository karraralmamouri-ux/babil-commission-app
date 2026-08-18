/**
 * قواعد أودو النقيّة — بلا شبكة وبلا حالة.
 *
 * فُصلت عن العميل عمداً: هذه هي المواضع التي تُقرَّر فيها الأشياء (ما يُطابَق،
 * وما يُنقَّى، وكيف تُترجَم الحالة)، والقرار يجب أن يكون قابلاً للاختبار بلا
 * خادم ولا Deno. العميل يستوردها، والاختبارات تستوردها، فلا توجد نسخة ثانية
 * تتباعد عن الأولى.
 */

/** طرق القراءة المسموحة. لا طريقة كتابة واحدة، وهذه القائمة هي الحارس. */
const ODOO_READ_METHODS = ['search_read', 'search_count', 'fields_get', 'read'];

/**
 * يُخفي أي شيء يشبه سرّاً قبل تسجيله أو إعادته.
 * أودو يُرجع أحياناً الطلب كاملاً داخل رسالة الخطأ، وفيه كلمة المرور.
 */
function redact(value) {
  let text = typeof value === 'string' ? value : JSON.stringify(value ?? '');
  if (!text) return '';
  // المفاتيح المعروفة، بأي صيغة اقتباس.
  text = text.replace(
    /("?(?:password|api_key|apikey|token|secret|login)"?\s*[:=]\s*)("[^"]*"|'[^']*'|[^,\s}]+)/gi,
    '$1"[REDACTED]"',
  );
  // مصفوفة معاملات authenticate: [db, login, password, {}]
  text = text.replace(/(\[\s*"[^"]*"\s*,\s*"[^"]*"\s*,\s*)"[^"]*"/g, '$1"[REDACTED]"');
  return text.length > 1000 ? text.slice(0, 1000) + '…' : text;
}

/**
 * أولوية مطابقة حتمية.
 * لا مطابقة بالتاريخ أو المبلغ وحدهما: مبلغان متساويان في يوم واحد شائعان
 * جداً، وترجيح أحدهما تخمينٌ يُسند مالاً بلا دليل.
 */
function matchInvoice(invoices, criteria) {
  const list = invoices || [];
  const c = criteria || {};

  if (list.length === 0) {
    return { tier: 'REVIEW', invoice: null, candidates: 0, reason: 'NO_INVOICE_FOUND' };
  }

  if (c.explicitOdooInvoiceId) {
    const hit = list.filter((i) => Number(i.id) === Number(c.explicitOdooInvoiceId));
    if (hit.length === 1) {
      return { tier: 'EXPLICIT_ID', invoice: hit[0], candidates: 1, reason: 'EXPLICIT_ODOO_ID' };
    }
  }

  const ref = String(c.reference == null ? '' : c.reference).trim();
  if (ref) {
    const hit = list.filter((i) =>
      String(i.name || '').trim() === ref
      || String(i.ref || '').trim() === ref
      || String(i.payment_reference || '').trim() === ref);
    if (hit.length === 1) {
      return { tier: 'EXACT_REFERENCE', invoice: hit[0], candidates: 1, reason: 'EXACT_REFERENCE' };
    }
    if (hit.length > 1) {
      return { tier: 'REVIEW', invoice: null, candidates: hit.length, reason: 'AMBIGUOUS_REFERENCE' };
    }
  }

  const origin = String(c.origin == null ? '' : c.origin).trim();
  if (origin) {
    const hit = list.filter((i) => String(i.invoice_origin || '').trim() === origin);
    if (hit.length === 1) {
      return { tier: 'PARTNER_AND_ORIGIN', invoice: hit[0], candidates: 1, reason: 'EXACT_ORIGIN' };
    }
    if (hit.length > 1) {
      return { tier: 'REVIEW', invoice: null, candidates: hit.length, reason: 'AMBIGUOUS_ORIGIN' };
    }
  }

  return {
    tier: 'REVIEW',
    invoice: null,
    candidates: list.length,
    reason: list.length === 1 ? 'SINGLE_CANDIDATE_WITHOUT_REFERENCE' : 'MULTIPLE_CANDIDATES',
  };
}

/**
 * حالة أودو تُترجم إلى حالة بابل، وتُحفظ حقائق أودو كما هي إلى جانبها.
 *
 * لا يُختزل كل شيء إلى «مُعتمدة أو لا»: مسوّدة، وملغاة، ومُرحَّلة غير مدفوعة
 * أحوالٌ مختلفة، ودمجها يُخفي سبب المنع عن المستخدم.
 *
 * الاعتماد يبقى فعلاً بشرياً: أفضل ما تُنتجه هذه الدالة FOUND.
 */
function mapInvoiceState(invoice) {
  if (!invoice) {
    return { babilStatus: 'MISSING', reason: 'NO_INVOICE', odoo: null };
  }
  const state = String(invoice.state || '');
  const facts = {
    odoo_state: state,
    odoo_payment_state: String(invoice.payment_state || ''),
    amount_total: Number(invoice.amount_total || 0),
    amount_residual: Number(invoice.amount_residual || 0),
    move_type: String(invoice.move_type || ''),
  };

  // الملغاة والمسوّدة ليستا دليلاً محاسبياً: الأولى نُقضت والثانية لم تُرحَّل.
  if (state === 'cancel') {
    return { babilStatus: 'NEEDS_REVIEW', reason: 'ODOO_INVOICE_CANCELLED', odoo: facts };
  }
  if (state === 'draft') {
    return { babilStatus: 'NEEDS_REVIEW', reason: 'ODOO_INVOICE_DRAFT', odoo: facts };
  }
  if (state !== 'posted') {
    return {
      babilStatus: 'NEEDS_REVIEW',
      reason: 'ODOO_STATE_' + (state || 'UNKNOWN'),
      odoo: facts,
    };
  }
  return { babilStatus: 'FOUND', reason: 'ODOO_INVOICE_POSTED', odoo: facts };
}

// وحدة ESM خالصة (.mjs): يستوردها Deno مباشرةً وتستوردها الاختبارات
// بـimport() الديناميكي. خلط CommonJS وESM في ملف واحد يكسر أحد المستهلكَين.
export { ODOO_READ_METHODS, redact, matchInvoice, mapInvoiceState };
