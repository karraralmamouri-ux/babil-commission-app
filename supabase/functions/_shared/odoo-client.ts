/**
 * عميل أودو — قراءة فقط.
 *
 * اكتُشف الخادم حيّاً قبل كتابة هذا الملف، بلا اعتماد وبلا أي كتابة:
 *   server_version  17.0+e-20250421   ⇒ أودو 17، نسخة Enterprise
 *   /json/2/...     404               ⇒ واجهة أودو 19 غير موجودة هنا
 *   /jsonrpc        تعمل              ⇒ المختار
 *   /xmlrpc/2/*     تعمل              ⇒ بديل، يحتاج تحليل XML
 *   قاعدة البيانات  odoo
 *
 * اختير /jsonrpc لأنه يعطي القدرة نفسها بـJSON خالص، فلا يحتاج محلّل XML في
 * بيئة Deno. وXML-RPC موثّق بديلاً لا أكثر.
 *
 * لا توجد هنا دالة كتابة واحدة. الطرق المسموحة محصورة في قائمة بيضاء
 * (search_read / fields_get / search_count / read)، وأي طلب بغيرها يُرفض
 * قبل أن يغادر العملية — فحتى خطأ برمجي لاحق لا يستطيع الكتابة في أودو.
 */

import {
  ODOO_READ_METHODS, redact, matchInvoice, mapInvoiceState,
} from './odoo-rules.mjs';

export { ODOO_READ_METHODS, redact, matchInvoice, mapInvoiceState };

export interface OdooConfig {
  baseUrl: string;
  database: string;
  login: string;
  apiKey: string;
  timeoutMs?: number;
}

export class OdooError extends Error {
  constructor(
    public readonly code:
      | 'ODOO_UNAVAILABLE'
      | 'ODOO_AUTH_FAILED'
      | 'ODOO_ACCESS_DENIED'
      | 'ODOO_NOT_CONFIGURED'
      | 'ODOO_WRITE_BLOCKED'
      | 'ODOO_BAD_RESPONSE',
    message: string,
  ) {
    super(message);
    this.name = 'OdooError';
  }
}

interface JsonRpcResponse {
  result?: unknown;
  error?: { message?: string; data?: { message?: string; name?: string } };
}

async function jsonRpc(
  config: OdooConfig,
  service: string,
  method: string,
  args: unknown[],
): Promise<unknown> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), config.timeoutMs ?? 15000);

  let response: Response;
  try {
    response = await fetch(`${config.baseUrl.replace(/\/+$/, '')}/jsonrpc`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        jsonrpc: '2.0',
        method: 'call',
        params: { service, method, args },
        id: Math.floor(Math.random() * 1e9),
      }),
      signal: controller.signal,
    });
  } catch (error) {
    // انقطاع الشبكة ومهلة الانتظار سواء: لا نعرف شيئاً، فلا ندّعي شيئاً.
    throw new OdooError(
      'ODOO_UNAVAILABLE',
      redact((error as Error)?.name === 'AbortError' ? 'request timed out' : String(error)),
    );
  } finally {
    clearTimeout(timeout);
  }

  if (!response.ok) {
    throw new OdooError('ODOO_UNAVAILABLE', `HTTP ${response.status}`);
  }

  let payload: JsonRpcResponse;
  try {
    payload = await response.json();
  } catch {
    throw new OdooError('ODOO_BAD_RESPONSE', 'response was not JSON');
  }

  if (payload.error) {
    const raw = payload.error.data?.message ?? payload.error.message ?? 'unknown error';
    const name = payload.error.data?.name ?? '';
    if (/AccessDenied|AccessError/i.test(name) || /access denied/i.test(raw)) {
      throw new OdooError('ODOO_ACCESS_DENIED', redact(raw));
    }
    throw new OdooError('ODOO_BAD_RESPONSE', redact(raw));
  }

  return payload.result;
}

/** معلومات الخادم — بلا اعتماد. تُستعمل لفحص الحياة والإصدار. */
export async function version(config: Pick<OdooConfig, 'baseUrl' | 'timeoutMs'>) {
  const result = await jsonRpc(
    { ...config, database: '', login: '', apiKey: '' } as OdooConfig,
    'common',
    'version',
    [],
  ) as Record<string, unknown>;
  return {
    serverVersion: String(result?.server_version ?? ''),
    serverSerie: String(result?.server_serie ?? ''),
    // اللاحقة e تعني Enterprise؛ وغيابها Community.
    edition: String(result?.server_version ?? '').includes('+e') ? 'enterprise' : 'community',
  };
}

/** يتحقق من الاعتماد ويعيد uid. مفتاح الـAPI يُستعمل بديلاً لكلمة المرور. */
export async function authenticate(config: OdooConfig): Promise<number> {
  if (!config.baseUrl || !config.database || !config.login || !config.apiKey) {
    throw new OdooError('ODOO_NOT_CONFIGURED', 'Odoo credentials are not configured');
  }
  const uid = await jsonRpc(config, 'common', 'authenticate', [
    config.database,
    config.login,
    config.apiKey,
    {},
  ]);
  if (typeof uid !== 'number' || uid <= 0) {
    // أودو يُرجع false لا خطأً عند فشل الاعتماد.
    throw new OdooError('ODOO_AUTH_FAILED', 'authentication returned no uid');
  }
  return uid;
}

/**
 * تنفيذ طريقة قراءة واحدة. القائمة البيضاء تُفحص هنا، فلا يمكن لأي مُستدعٍ
 * أن يمرّر create أو write أو unlink حتى بالخطأ.
 */
export async function executeRead(
  config: OdooConfig,
  uid: number,
  model: string,
  method: string,
  args: unknown[],
  kwargs: Record<string, unknown> = {},
): Promise<unknown> {
  if (!(ODOO_READ_METHODS as readonly string[]).includes(method)) {
    throw new OdooError('ODOO_WRITE_BLOCKED', `method ${method} is not a read method`);
  }
  return await jsonRpc(config, 'object', 'execute_kw', [
    config.database,
    uid,
    config.apiKey,
    model,
    method,
    args,
    kwargs,
  ]);
}

/** بيانات وصفية لحقول نموذج — أساس اكتشاف الحقول المخصّصة. */
export async function fieldsGet(config: OdooConfig, uid: number, model: string) {
  const fields = await executeRead(config, uid, model, 'fields_get', [], {
    attributes: ['string', 'type', 'required', 'readonly', 'relation', 'store'],
  }) as Record<string, Record<string, unknown>>;
  return Object.entries(fields ?? {}).map(([name, meta]) => ({
    name,
    label: String(meta?.string ?? ''),
    type: String(meta?.type ?? ''),
    relation: meta?.relation ? String(meta.relation) : null,
    stored: meta?.store !== false,
    // الحقول المخصّصة في أودو تبدأ بـx_ أو تأتي من Studio.
    custom: name.startsWith('x_') || name.startsWith('x_studio'),
  }));
}

/**
 * بحث حتمي عن شريك عبر حقول معرّف مستقرة.
 * لا مطابقة بالاسم: الأسماء تتكرر، وربطٌ خاطئ هنا يُسند فاتورة إلى شخص آخر.
 */
export async function findPartner(
  config: OdooConfig,
  uid: number,
  reference: string,
  candidateFields: string[],
  extraFields: string[] = [],
) {
  const clean = String(reference ?? '').trim();
  if (!clean) return [];

  const baseFields = ['id', 'name', 'display_name', 'ref', 'active', 'parent_id', 'company_id'];
  const fields = [...new Set([...baseFields, ...candidateFields, ...extraFields])];

  // OR على حقول المعرّفات فقط، ومطابقة تامة (=) لا ilike.
  const domain: unknown[] = [];
  for (let i = 0; i < candidateFields.length - 1; i += 1) domain.push('|');
  for (const field of candidateFields) domain.push([field, '=', clean]);

  return await executeRead(config, uid, 'res.partner', 'search_read', [domain], {
    fields,
    limit: 20,
    context: { active_test: false },
  }) as Record<string, unknown>[];
}

/** فواتير عميل لشريك بعينه. النوع مُقيَّد بفواتير البيع ومردوداتها. */
export async function findCustomerInvoices(
  config: OdooConfig,
  uid: number,
  partnerId: number,
  extraFields: string[] = [],
) {
  const fields = [...new Set([
    'id', 'name', 'ref', 'move_type', 'state', 'payment_state',
    'partner_id', 'commercial_partner_id', 'invoice_date', 'invoice_date_due',
    'amount_untaxed', 'amount_tax', 'amount_total', 'amount_residual',
    'payment_reference', 'invoice_origin', 'currency_id', 'create_date', 'write_date',
    ...extraFields,
  ])];

  return await executeRead(config, uid, 'account.move', 'search_read', [[
    ['partner_id', '=', partnerId],
    ['move_type', 'in', ['out_invoice', 'out_refund']],
  ]], {
    fields,
    limit: 100,
    order: 'invoice_date desc, id desc',
  }) as Record<string, unknown>[];
}

