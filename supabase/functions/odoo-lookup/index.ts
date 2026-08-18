/**
 * odoo-lookup — البوابة الوحيدة بين بابل وأودو.
 *
 * المتصفح لا يتصل بأودو إطلاقاً. مفتاح الـAPI يبقى سرّ الدالة الطرفية، ولا
 * يظهر في ردّ ولا سجلّ ولا رسالة خطأ.
 *
 * كل طلب يمرّ بثلاثة حواجز قبل أن يلمس أودو:
 *   1. مستخدم بابل مُعتمَد (تُتحقَّق هويته على الخادم لا من رأس مُرسَل).
 *   2. قدرة odoo.read فعّالة له.
 *   3. الفعل ضمن قائمة قراءة بيضاء.
 *
 * الأفعال: version | fields | find-partner | find-invoices | verify-invoice
 * ولا فعل كتابة واحد.
 */
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';
import {
  authenticate, executeRead, fieldsGet, findCustomerInvoices, findPartner,
  matchInvoice, mapInvoiceState, OdooError, redact, version,
  type OdooConfig,
} from '../_shared/odoo-client.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });

/** حقول الشريك المسموح إعادتها. الهوية الحسّاسة لا تُعاد بلا حاجة مُثبتة. */
const PARTNER_SAFE_FIELDS = [
  'id', 'name', 'display_name', 'ref', 'active', 'parent_id', 'company_id',
];

/** حقول الفاتورة التشغيلية. لا سطور ولا مرفقات ولا كائن كامل. */
const INVOICE_SAFE_FIELDS = [
  'id', 'name', 'ref', 'move_type', 'state', 'payment_state',
  'invoice_date', 'invoice_date_due', 'amount_total', 'amount_residual',
  'payment_reference', 'invoice_origin',
];

function pick(row: Record<string, unknown>, allowed: string[]) {
  const out: Record<string, unknown> = {};
  for (const key of allowed) if (key in row) out[key] = row[key];
  return out;
}

function odooConfig(): OdooConfig {
  return {
    baseUrl: Deno.env.get('ODOO_BASE_URL') ?? '',
    database: Deno.env.get('ODOO_DATABASE') ?? '',
    login: Deno.env.get('ODOO_LOGIN') ?? '',
    apiKey: Deno.env.get('ODOO_API_KEY') ?? '',
    timeoutMs: Number(Deno.env.get('ODOO_TIMEOUT_MS') ?? '15000'),
  };
}

/**
 * حقول المعرّف المرشَّحة للبحث عن شريك.
 * تُضبَط من الإعدادات بعد الاكتشاف المُعتمَد، ولا تُخمَّن هنا: أسماء الحقول
 * المخصّصة تختلف بين تركيب وآخر، وتخمينها يُنتج بحثاً يفشل صامتاً.
 */
function partnerKeyFields(): string[] {
  const configured = (Deno.env.get('ODOO_PARTNER_KEY_FIELDS') ?? '').trim();
  if (configured) return configured.split(',').map((s) => s.trim()).filter(Boolean);
  return ['ref'];
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'METHOD_NOT_ALLOWED' }, 405);

  // ---- 1. مستخدم بابل ----
  const authHeader = req.headers.get('Authorization') ?? '';
  const token = authHeader.replace(/^Bearer\s+/i, '').trim();
  if (!token) return json({ error: 'UNAUTHENTICATED' }, 401);

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    { auth: { persistSession: false } },
  );

  const { data: userData, error: userError } = await supabase.auth.getUser(token);
  if (userError || !userData?.user) return json({ error: 'UNAUTHENTICATED' }, 401);
  const userId = userData.user.id;

  // ---- 2. القدرة، محسوبة على الخادم ----
  const { data: allowed, error: capError } = await supabase.rpc('effective_permission', {
    p_user_id: userId,
    p_capability: 'odoo.read',
  });
  if (capError) return json({ error: 'PERMISSION_CHECK_FAILED' }, 500);
  if (allowed !== true) return json({ error: 'FORBIDDEN', capability: 'odoo.read' }, 403);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: 'BAD_REQUEST' }, 400);
  }

  const action = String(body.action ?? '');
  const config = odooConfig();

  try {
    // فحص الإصدار لا يحتاج اعتماداً، فيصلح فحصَ حياة قبل ضبط السرّ.
    if (action === 'version') {
      return json({ ok: true, ...(await version(config)) });
    }

    if (!config.login || !config.apiKey || !config.database || !config.baseUrl) {
      return json({ error: 'ODOO_NOT_CONFIGURED' }, 503);
    }

    const uid = await authenticate(config);

    if (action === 'fields') {
      const model = String(body.model ?? '');
      if (!['res.partner', 'account.move'].includes(model)) {
        return json({ error: 'MODEL_NOT_ALLOWED' }, 400);
      }
      const fields = await fieldsGet(config, uid, model);
      // البيانات الوصفية لا تحمل بيانات عملاء، فتُعاد كاملة لأجل الاكتشاف.
      return json({ ok: true, model, count: fields.length, fields });
    }

    if (action === 'find-partner') {
      const reference = String(body.reference ?? '');
      const rows = await findPartner(config, uid, reference, partnerKeyFields());
      return json({
        ok: true,
        reference,
        searched_fields: partnerKeyFields(),
        count: rows.length,
        // تعدد النتائج غموضٌ يُعلَن، ولا يُحسم بالاختيار الأول.
        ambiguous: rows.length > 1,
        partners: rows.map((r) => pick(r, PARTNER_SAFE_FIELDS)),
      });
    }

    if (action === 'find-invoices') {
      const partnerId = Number(body.partner_id ?? 0);
      if (!partnerId) return json({ error: 'PARTNER_ID_REQUIRED' }, 400);
      const rows = await findCustomerInvoices(config, uid, partnerId);
      return json({
        ok: true,
        partner_id: partnerId,
        count: rows.length,
        invoices: rows.map((r) => pick(r, INVOICE_SAFE_FIELDS)),
      });
    }

    if (action === 'verify-invoice') {
      const partnerId = Number(body.partner_id ?? 0);
      if (!partnerId) return json({ error: 'PARTNER_ID_REQUIRED' }, 400);

      const rows = await findCustomerInvoices(config, uid, partnerId);
      const match = matchInvoice(rows, {
        explicitOdooInvoiceId: body.odoo_invoice_id ? Number(body.odoo_invoice_id) : null,
        reference: body.reference ? String(body.reference) : null,
        origin: body.origin ? String(body.origin) : null,
      });
      const mapped = mapInvoiceState(match.invoice);

      return json({
        ok: true,
        match_tier: match.tier,
        match_reason: match.reason,
        candidates: match.candidates,
        babil_status: mapped.babilStatus,
        status_reason: mapped.reason,
        odoo: mapped.odoo,
        invoice: match.invoice ? pick(match.invoice, INVOICE_SAFE_FIELDS) : null,
        // القرار يبقى بشرياً: الدالة تعرض الحقائق ولا تعتمد شيئاً.
        note: 'facts only; verification remains an explicit human action',
      });
    }

    return json({ error: 'UNKNOWN_ACTION' }, 400);
  } catch (error) {
    if (error instanceof OdooError) {
      // الانقطاع لا يُنتج «مُعتمَدة» ولا «مفقودة»: يُعاد كما هو ليقرّر المستخدم.
      const status = error.code === 'ODOO_UNAVAILABLE' ? 503
        : error.code === 'ODOO_AUTH_FAILED' ? 502
        : error.code === 'ODOO_ACCESS_DENIED' ? 403
        : 500;
      console.error(`odoo-lookup ${error.code}: ${redact(error.message)}`);
      return json({ error: error.code, detail: redact(error.message) }, status);
    }
    console.error(`odoo-lookup unexpected: ${redact(String(error))}`);
    return json({ error: 'UNEXPECTED', detail: redact(String(error)) }, 500);
  }
});
