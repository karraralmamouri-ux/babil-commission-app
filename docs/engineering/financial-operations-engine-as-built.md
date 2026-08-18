# Financial Operations Engine — As Built

What was built and what is live in production. Every number here came from a run.

Starting SHA `b410140` → merged `d7d3996`.
Migrations `20260820090000` · `20260820120000` · `20260820150000` · `20260820180000`.

---

## 1. Dynamic permissions

Capabilities replace the six-verb frontend matrix (`edit/payment/rates/users/
delete/backup`). Roles become templates, so one capability can be granted to one
person without promoting them a whole role — previously promotion was easier than
adjustment, which pushes a financial system the wrong way.

- **35 capabilities**, **4 role templates**, **64 template grants** in production.
- `DENY` always beats `GRANT`, including a global DENY over a scoped GRANT.
- Scopes: `GLOBAL` / `AGENT` / `FDT` / `ZONE`. A non-global scope requires an id,
  so "unspecified agent" can never accidentally mean "all agents".
- `INHERIT` removes the override rather than storing a third effect.
- Every change goes through `set_user_permission`, which is idempotent by
  `request_id` and writes an audit row.
- `explain_permission` returns template / explicit grant / explicit deny / scopes
  / effective result, so the admin screen can say *why*.

### Behaviour parity

Templates were seeded to reproduce today's behaviour literally. Verified:

| Role | payment.execute | payment.correct | payment.reverse | installation.view |
|---|---|---|---|---|
| admin | ✓ | ✓ | ✓ | ✓ |
| accountant | ✓ | ✗ | ✗ | ✓ |
| monitor | ✗ | ✗ | ✗ | ✓ |
| viewer | ✗ | ✗ | ✗ | ✓ |

The accountant keeps payment and gains no correction or reversal. Recording a
payment is not authority to undo one.

### Lockout protection

A deferred constraint trigger refuses any transaction that would leave zero
active permission administrators. It is deferred on purpose — an intermediate
step may dip to zero, and what matters is the state at commit. Production
reports **1** administrator remaining.

---

## 2. Versioned schemes

`P1..P4` and their amounts left SQL and JS for configuration.

Production V1, published and immutable:

| Seq | Code | Amount | Expected remaining |
|---|---|---|---|
| 1 | P1 | 3,000 | 13,000 |
| 2 | P2 | 3,000 | 10,000 |
| 3 | P3 | 3,000 | 7,000 |
| 4 | P4 | 4,000 | 4,000 |
| 5 | DONE | 0 | 0 |

Total **13,000** — matching the accepted historical baseline exactly.

A trigger permits only one transition on a published version: retirement. Amount,
stage, and date edits are refused; change means a new version. Enrollments freeze
their `scheme_version_id`, so publishing V2 cannot rewrite V1 subscribers' money.
A test builds a three-stage V2 and confirms V1 is untouched.

**The V1 publish carries no actor.** Attributing a migration-seeded publish to
"the first user in the table" failed on an empty database and would have been a
lie in the audit trail. A system publish honestly records only its timestamp.

### Semantics are not eligibility

`packages.semantic_category` says what a package *is*. Whether it can satisfy a
stage is `installation_stage_definitions.qualifying_categories`. `Loan-3` is
`DEBT_SERVICE` and can never qualify; `Diamond` stays `UNKNOWN`; an unregistered
code is treated as unknown.

---

## 3. Historical continuity

`bootstrap_historical_enrollments()` attaches the baseline to V1 without
reconstructing a single riyal.

```
subscribers_total        5693
enrollments_created      5688
skipped_unknown_stage       5
enrollments_pre_existing    0     (0 on re-run — idempotent)
```

All **5,688** enrollments carry exactly the stage their historical state already
held. Distribution: DONE 3,492 · P1 774 · P4 690 · P3 385 · P2 347.

A subscriber who historically paid P1 and P2 continues at **P3**, never restarting
at P1 — asserted by test.

The **5 skipped** are precisely the `unresolved` rows with no computed stage.
They were already blocked from payment; guessing a stage would have invented a
financial position. They are reported, not resolved.

Unchanged through the whole operation: 5,693 subscribers · 17,117 payment rows ·
54,828,000 IQD historical sum · 0 entitlements · 0 payments.

---

## 4. Operations

- **Cycles** with a configurable lifecycle (DRAFT → … → CLOSED) and a snapshot.
- **Holds** with 10 seeded system reasons plus configurable manual reasons.
  Releasing requires a written reason. A hold blocks payment and erases nothing.
- **Invoices** with Odoo-ready fields (`odoo_model`, `odoo_record_id`) and no
  external calls. `external_invoice_id` is deliberately separate from the SaaS
  `transaction_id` — assuming they are the same would build a link on a guess.
- **Payment batches** with a partial unique index preventing one entitlement from
  sitting in two live batches.
- **Completeness declarations** requiring coverage bounds and written evidence.

### Eligibility

`installation_entitlement_eligibility(uuid)` is server-authoritative and returns
structured blockers. Conditions: enrollment valid and active, stage is genuinely
next, amount matches the scheme, identity resolved, not DIRECT_COMPANY, invoice
satisfied when the stage requires it, no active hold, not already paid, and no
unresolved historical state.

`revalidate_payment_batch` re-runs this at post time. A Ready computed a minute
ago is not permission to pay now — a test adds a hold after batch preparation and
confirms the item flips to BLOCKED.

The payment guard is installed as a **trigger** on `installation_entitlements`
rather than a second copy of the payment RPC. Duplicating that body would create
two financial texts that drift; a trigger catches every path including future
ones. Entitlements with no enrollment keep their previous behaviour, so existing
payments do not break because the enrollment layer arrived after them.

---

## 5. Raw SaaS ingestion

Three already-validated workbooks ingested as **operational history only**.
Checksums matched the measured evidence before any write.

| Source | Parsed | In production |
|---|---|---|
| `users all.xlsx` | 32,481 users, 1 secret column dropped | 32,481 snapshots |
| July | 29,289 events | — |
| May | 28,233 events (2 cross-sheet duplicates collapsed) | — |
| **Total events** | **57,522** | **57,522**, all ids distinct |

27,857 distinct usernames — reconciling exactly with local validation.

All three batches remain `completeness_status = UNKNOWN`. Consequently:
**0 NEW classifications, 0 entitlements, 0 payments.** Ingestion created no money,
which is the whole point of keeping completeness honest.

Idempotency was exercised by re-running the full ingestion against production: the
counts did not move (3 batches, 57,522 events, 32,481 snapshots, zero duplicates).

`ct_password` never reaches this path — the parser drops it at read time.

---

## 6. Client layer

Six panels: payment queues, import centre, schemes, master data, permissions,
corrections.

The page decides nothing financial. Eligibility comes from the RPC and is
rendered as-is; amounts are read from stage definitions. Tests assert that
neither the operations block in `index.html` nor `operations.js` contains a stage
amount or an eligibility decision, so that logic cannot drift into the browser.

Capability checks hide unusable panels. That is presentation, not enforcement —
the server checks every RPC regardless — and a capability the server did not
return is treated as **denied**, never assumed.

---

## 7. Remaining `app_settings` dependencies

`app_settings.raw_import` is still the authority for the **legacy commission raw
import path** (`calculateRawImport` in `index.html`): agent list, account aliases,
cabinet ranges, and profile mapping.

Master data now mirrors it — `bootstrap_master_data_from_settings()` seeds
`agents`, `agent_aliases`, `fdts` and `packages` from it — but the legacy import
still *reads* `app_settings`, not the master tables.

**Consequence:** aliases and agents must not be edited independently in both
places. Until the legacy raw import is migrated to read the master tables, treat
`app_settings.raw_import` as the editable authority for commission import and the
master tables as its derived mirror.

`app_settings` is not deleted, and should not be until that path moves.

---

## 8. Test coverage

| Suite | Count |
|---|---|
| JS | 234 (was 212) |
| Local database assertions | 256 (was 196) |

New database assertions cover: permission inheritance / grant / deny / scope
isolation / explainability / lockout / server-side RPC rejection; V1 shape,
published immutability, V2 with a different stage count, Loan-3 and Diamond;
historical continuity and idempotency; the full enrollment gate; eligibility,
holds, invoices, revalidation and the payment guard; completeness evidence; and
privilege invariants.

### A test defect worth recording

My suites set `request.jwt.claims`, but this harness's `auth.uid()` reads
`request.jwt.claim.sub` — so the sessions were **anonymous**. This meant the PII
test shipped in the previous phase was passing for the wrong reason: it asserted
a viewer sees zero rows while nobody was logged in. Both suites now carry a real
identity, and the restriction is genuinely proven.

---

## 9. Not implemented

Explicitly out of scope for this bundle and **not** built:

- Commission Engine vNext
- Unique Active Users tier calculation
- D-03 final Active User definition
- Live Odoo API integration (the invoice model is Odoo-ready; no calls are made)
- Full visual redesign

Also not built: a cycle close/reopen RPC (the table and its constraints exist,
the workflow that writes them does not), and attribution-transfer write paths.
