# Odoo Integration Contract

**Status: connector ready and deployed · integration disabled by default ·
remaining live discovery DEFERRED by product decision.**

> **Deferred, not failed.** Live discovery of the field layout, the test
> subscriber and the invoice model is postponed to a later development axis. The
> reasons are product ones, not technical: the first go-live does not need Odoo,
> the priority is validating the SaaS Excel workflow and financial accuracy, and
> the current Odoo user may lack Accounting/Invoice read permissions — in which
> case discovering now would produce an incomplete picture that looks complete.
>
> Everything built for Odoo stays in place: connector, Edge Function (deployed
> and ACTIVE), secrets, schema, permissions, this contract, and the tests.
> Nothing was rolled back. The work resumes at §11 whenever it is wanted.

Every fact in §1–§3 was measured live against `https://znr.ejaferp.com` on
2026-08-23 using unauthenticated read-only endpoints. No credential was used, no
record was read, and nothing was written.

Sections marked **PENDING CREDENTIALS** are *not* filled in. They require
`ODOO_LOGIN` and `ODOO_API_KEY`, which do not exist in this environment. They are
left blank deliberately — a guessed field name is worse than an empty one,
because it produces a search that fails silently.

---

## 1. Server — verified live

| Fact | Value | How |
|---|---|---|
| `server_version` | `17.0+e-20250421` | `POST /web/webclient/version_info` |
| `server_serie` | `17.0` | same |
| Edition | **Enterprise** (`+e` suffix) | same |
| Build date | 2025-04-21 | from the version string |
| `protocol_version` | `1` | same |
| Database | **`odoo`** (single) | `POST /web/database/list` |

**This is Odoo 17, not 19.** The brief warned against assuming 19; the live
server settles it.

---

## 2. API style — verified live

| Interface | Path | Result |
|---|---|---|
| JSON-2 API | `/json/2/res.partner` | **HTTP 404 — does not exist** |
| JSON-RPC | `/jsonrpc` | **works**, returned version |
| XML-RPC | `/xmlrpc/2/common` | **works**, returned version |

The JSON-2 API is an Odoo 19 feature and is absent here, so the brief's first
preference is unavailable. **`/jsonrpc` is chosen**: identical capability to
XML-RPC but JSON in and out, so the Deno Edge Function needs no XML parser.

### Request shape

```
POST /jsonrpc
{"jsonrpc":"2.0","method":"call","id":<n>,
 "params":{"service":"<common|object>","method":"<...>","args":[...]}}
```

- `common.version` — no authentication (used as a liveness probe)
- `common.authenticate` → `[db, login, apiKey, {}]` → returns `uid` (integer) or
  `false`. **A failed login returns `false`, not an error** — the connector
  treats a non-positive uid as `ODOO_AUTH_FAILED`.
- `object.execute_kw` → `[db, uid, apiKey, model, method, args, kwargs]`

The API key is used **in place of the password**; Odoo has accepted this since
v14. It is never sent to the browser.

---

## 3. Authentication

| | |
|---|---|
| Style | API key as password, via `common.authenticate` |
| Database required | **Yes** — `odoo` |
| Login required | **Yes** |
| Where secrets live | Supabase Edge Function secrets **only** |

Required Edge Function secrets:

```
ODOO_BASE_URL   https://znr.ejaferp.com
ODOO_DATABASE   odoo
ODOO_LOGIN      <set at deploy time>
ODOO_API_KEY    <set at deploy time>
ODOO_TIMEOUT_MS 15000            (optional)
ODOO_PARTNER_KEY_FIELDS  <set after §5 discovery; defaults to "ref">
```

---

## 4. Models and fields — PENDING CREDENTIALS

`fields_get` requires an authenticated session. The `fields` action on the Edge
Function performs exactly this discovery and is restricted to `res.partner` and
`account.move`.

**To complete this section**, set the secrets and call:

```
POST /functions/v1/odoo-lookup   {"action":"fields","model":"res.partner"}
POST /functions/v1/odoo-lookup   {"action":"fields","model":"account.move"}
```

The response flags any field whose name starts with `x_` or `x_studio` as
`custom: true`, which is how the custom/Studio fields required by §6 will be
identified.

Standard fields the connector already requests are listed in
`supabase/functions/_shared/odoo-client.ts`.

---

## 5. Test subscriber `030270029` — PENDING CREDENTIALS

**Not resolved.** Searching `res.partner` requires authentication.

The discovery call, once secrets exist:

```
POST /functions/v1/odoo-lookup
{"action":"find-partner","reference":"030270029"}
```

The response returns `searched_fields`, the match `count`, an explicit
`ambiguous` flag when more than one partner matches, and the partner rows.

**Search behaviour is deterministic by construction:** exact `=` on identifier
fields only. There is no `ilike`, and no matching by name — a name collision here
would attach one customer's invoice to another. If several partners match, the
connector reports the ambiguity rather than picking one.

`ODOO_PARTNER_KEY_FIELDS` is a configurable list because custom field names
differ between installations. It defaults to `ref` alone; the correct list comes
out of §4.

---

## 6. Primary join key — PENDING CREDENTIALS

Cannot be chosen without seeing which field actually holds `030270029`.

The decision rule, to apply once §4 and §5 are run:

| Rank | Candidate | Accept when |
|---|---|---|
| 1 | dedicated custom subscriber/contract field (`x_*`) | present, unique, non-display |
| 2 | `ref` | populated consistently and unique |
| 3 | explicit contract id field | present and unique |
| — | **`vat` / national id** | only if legitimately required; it is identity data |
| ✗ | `name`, `display_name`, `phone`, `mobile`, `email` | **unsafe** — mutable, repeatable, not identifiers |

`res.partner.id` is the stable *internal* key once resolved, and is what gets
stored in `installation_invoices.odoo_partner_id`. It is not a lookup key,
because SaaS data does not carry it.

---

## 7. Invoice lookup

Customer invoices are constrained by move type — `account.move` also holds
journal entries, bills and refunds, and treating all of it as invoices would be
wrong:

```
[["partner_id","=",<id>],
 ["move_type","in",["out_invoice","out_refund"]]]
```

Whether this installation uses additional or custom move types is **PENDING
CREDENTIALS** (§10 of the brief).

### Matching priority — implemented and tested

| Tier | Basis | Result |
|---|---|---|
| 1 `EXPLICIT_ID` | stored `odoo_invoice_id` | match |
| 2 `EXACT_REFERENCE` | `name` / `ref` / `payment_reference` exact | match |
| 3 `PARTNER_AND_ORIGIN` | `invoice_origin` exact | match |
| 4 `REVIEW` | anything else | **no match; human decides** |

**Date and amount alone never match.** Two invoices of the same amount on the
same day are ordinary, and choosing between them is a guess that assigns money
without evidence. A single candidate with no reference is also `REVIEW` — one
option is not proof.

Ambiguity at any tier returns `REVIEW` with a candidate count, never a pick.

**The SaaS `transaction_id` is not assumed to be the Odoo invoice number.**
Nothing in the code equates them.

---

## 8. Status mapping — implemented

Odoo facts are stored **beside** the Babil state, never collapsed into a boolean.

| `account.move.state` | Babil status | Reason code |
|---|---|---|
| `posted` | `FOUND` | `ODOO_INVOICE_POSTED` |
| `draft` | `NEEDS_REVIEW` | `ODOO_INVOICE_DRAFT` |
| `cancel` | `NEEDS_REVIEW` | `ODOO_INVOICE_CANCELLED` |
| anything else | `NEEDS_REVIEW` | `ODOO_STATE_<value>` |
| no invoice | `MISSING` | `NO_INVOICE` |

**The mapper's best output is `FOUND`, never `VERIFIED`.** Verification stays an
explicit human act through `verify_installation_invoice`. A test asserts the
mapper cannot produce `VERIFIED`.

Preserved separately: `odoo_state`, `odoo_payment_state`, `amount_total`,
`amount_residual`, `move_type`.

### Payment state

**Raw values are stored as received, not translated.** Odoo 17's
`payment_state` set is not hardcoded from another version, because doing so
silently mislabels anything unexpected. A test round-trips
`not_paid`, `in_payment`, `paid`, `partial`, `reversed`, `blocked` and
`invoicing_legacy` and asserts each survives unchanged.

Confirming which values this installation actually emits is **PENDING
CREDENTIALS**.

---

## 9. Security model

```
Browser  →  Supabase Edge Function  →  Odoo
            (holds the secret)
```

The browser never contacts Odoo and never receives the key.

Every request passes three gates before Odoo is touched, in this order:

1. Babil user authenticated — verified server-side via `auth.getUser`, not from
   a client-supplied header.
2. `odoo.read` capability effective for that user, computed by
   `effective_permission`.
3. Action within the read-only allow-list.

**No write path exists.** `ODOO_READ_METHODS` is `search_read`, `search_count`,
`fields_get`, `read`. `executeRead` rejects anything else with
`ODOO_WRITE_BLOCKED` before the request leaves the process, so even a future
coding mistake cannot write to Odoo. Tests assert the client mentions no write
method and the function exposes only five read actions.

Returned fields are allow-listed. Partner responses exclude `vat`, `phone`,
`mobile` and `email`; invoice responses carry operational fields only, never
lines or attachments.

Secrets cannot reach the database: `integration_settings` has a trigger that
rejects any config key resembling a credential, and `record_odoo_invoice_check`
rejects a snapshot containing one. Both are tested.

Errors are redacted before logging or returning. Odoo sometimes echoes the whole
request — including the password — inside an error, and the `authenticate`
argument array is redacted positionally for exactly that case.

### Permissions

| Capability | admin | accountant | monitor | viewer |
|---|---|---|---|---|
| `odoo.read` | ✓ | ✓ | ✗ | ✗ |
| `invoice.verify` | ✓ | ✓ | ✗ | ✗ |

`odoo.read` is separate from `invoice.verify` on purpose: someone may need to
read Odoo for diagnosis without approving invoices, and invoices can be approved
manually with no Odoo at all.

---

## 10. Errors, timeouts, outage

| Code | HTTP | Meaning |
|---|---|---|
| `ODOO_NOT_CONFIGURED` | 503 | secrets absent — not an outage |
| `ODOO_UNAVAILABLE` | 503 | network failure or timeout |
| `ODOO_AUTH_FAILED` | 502 | credentials rejected |
| `ODOO_ACCESS_DENIED` | 403 | user lacks Odoo model access |
| `ODOO_WRITE_BLOCKED` | 500 | a write was attempted — a bug, not a state |
| `ODOO_BAD_RESPONSE` | 500 | malformed reply |

Requests abort after `ODOO_TIMEOUT_MS` (default 15s), so a hung Odoo cannot hang
Babil.

**An outage never produces a verified invoice.** There is no code path from
`ODOO_UNAVAILABLE` to any success state, and a test asserts it. The manual
review path continues to work with Odoo entirely off — also tested.

SaaS ingestion has no dependency on Odoo whatsoever.

---

## 11. Rollout

| Setting | Value now |
|---|---|
| `integration_settings.odoo.enabled` | **false** |
| `mode` | `MANUAL` |
| Production secrets | **not set** |

`odoo_verification_mode()` returns `OFF` whenever `enabled` is false, regardless
of stored mode — so the flag alone disables everything.

Modes: `OFF` · `MANUAL` · `OPTIONAL_LIVE_CHECK` · `REQUIRED`.
`odoo_verification_required()` is true only for `REQUIRED`, which is an explicit
operational decision, never a side effect of deployment.

### Steps to activate

1. Set the Edge Function secrets.
2. Run `{"action":"version"}` — needs no credentials, confirms reachability.
3. Run `{"action":"fields","model":"res.partner"}` → complete §4.
4. Run `{"action":"find-partner","reference":"030270029"}` → complete §5 and §6.
5. Set `ODOO_PARTNER_KEY_FIELDS` from the result.
6. Run `{"action":"find-invoices","partner_id":<id>}` → complete §7 and §8.
7. Only then set `enabled = true`, keeping `mode = MANUAL`.

---

## 12. Deferred — open questions for the next axis

These are **deferred**, not blocked and not failed. The secrets are configured in
the remote Edge Function runtime and the function is deployed; what remains is a
product decision about when to spend the time.

- Which `res.partner` field holds `030270029`, and whether it is unique.
- Whether custom/Studio fields exist on `res.partner` or `account.move`.
- Which `move_type` and `payment_state` values this installation actually uses.
- Whether the API user has read access to `account.move` at all.
- Whether a stable SaaS↔Odoo key exists, or whether operational data will need a
  reconciliation pass first.

**The fourth question is the reason the others wait.** If the configured Odoo
user lacks Accounting read rights, a discovery run would return a partial field
list and an empty invoice set — which reads exactly like "this installation has
no custom fields and no invoices for that subscriber." Answering that permission
question first is cheaper than acting on a confident-looking wrong answer.

Resuming needs no new build: run the six calls in §11 with any authenticated
Babil user holding `odoo.read`.

### State at deferral

| | |
|---|---|
| `odoo-lookup` Edge Function | deployed, ACTIVE, v1 |
| Unauthenticated call | correctly rejected — `401 UNAUTHENTICATED` |
| Odoo writes performed | **none** |
| `integration_settings.odoo.enabled` | `false` |
| `odoo_verification_mode()` | `OFF` |
| `odoo_verification_required()` | `false` |
| Operational source | **SaaS Excel, unchanged** |

---

## 13. Scope confirmation

**SaaS Excel remains the operational source** for users, activations,
new/existing evidence and commission events. Odoo is used only for partner and
invoice verification, and only when explicitly enabled. Nothing in this phase
changes the import centre or makes Odoo required for any workflow.
