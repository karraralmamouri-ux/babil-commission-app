# Financial State Machine

Tags: **FACT** / **INFERENCE** / **RECOMMENDATION** / **OPEN DECISION**.

---

## 1. Orthogonal dimensions, not one status

**FACT.** Today the installation domain already splits status across several columns rather
than overloading one: `stage`, `resolution`, `payment_eligible`, `invoice_status`,
`payment_status`. That instinct is correct and should be formalised.

**RECOMMENDATION.** Five independent dimensions. A subscriber holds one value from each.

| Dimension | Values | Owner |
|---|---|---|
| **Financial stage** | P1 · P2 · P3 · P4 · DONE | derived from Remaining + scheme version |
| **Operational** | Active · On Hold · Stopped · Unresolved | operations |
| **Matching** | Matched · Unmatched · Conflict | import/matching engine |
| **Invoice** | Missing · Found · Needs Review · Verified · Rejected | finance |
| **Payment** | Not Eligible · Eligible · Ready · Paid | derived + finance |

A readable state is the tuple: `P3 · Active · Verified · Ready`.

**FACT.** The existing `installation_entitlements` already carries `invoice_status`
(`pending / approved / missing / rejected`) and `payment_status`
(`awaiting_invoice / eligible / paid / not_eligible`) as separate columns, so the target is
an extension of what exists, not a replacement.

---

## 2. Stage progression

```
        ┌──────────────────── qualifying paid activation ────────────────────┐
        │                                                                    ▼
   (no entitlement) ──► P1 ──► P2 ──► P3 ──► P4 ──► DONE ──► (terminal)
                         ▲      ▲      ▲      ▲
                         └──────┴──────┴──────┴──── resume point after hold release
```

**Rules.**

- Progression is forward-only. There is no path back from DONE.
- Entry is at the stage the history dictates, **not** always P1. A migrated subscriber with
  P1 and P2 paid enters at P3.
- Loan-3 is not an entry trigger (`installation-fees-business-rules.md` §4).

---

## 3. Payment lifecycle for one stage

```
Not Eligible
   │  resolution = resolved  AND  stage ∈ {P1..P4}
   ▼
Eligible ──────────────► On Hold ──── release ────► Eligible
   │  invoice verified                                  │
   ▼                                                    │
Ready ◄─────────────────────────────────────────────────┘
   │  payment batch posted (server-side revalidation)
   ▼
Paid  ── correction ──►  Reversed / Adjusted   (never deleted)
```

**FACT.** `Paid` is already terminal-and-protected in the shipped schema: the trigger
`protect_settled_installation_entitlement` blocks mutation of a settled entitlement, and
`installation_payments_entitlement_key unique (entitlement_id)` makes a second payment
impossible.

---

## 4. What blocks payment

**FACT — enforced in the database today:**

| Blocker | Mechanism |
|---|---|
| `resolution = 'unresolved'` | `installation_state_unresolved_is_never_eligible` |
| financial mismatch | `installation_state_mismatch_is_unresolved` (forces unresolved) |
| stage = DONE or no stage | `installation_state_eligible_needs_pending_stage` |
| invoice not approved | `record_installation_payment` refuses unless `invoice_status = 'approved'` |
| already paid | `unique (entitlement_id)` on `installation_payments` |
| replayed request | `request_id` checked against `audit_logs` |
| concurrent double-spend | `pg_advisory_xact_lock` + `for update` |
| non-admin / non-payer | `current_app_role()` check inside every financial RPC |

**RECOMMENDATION — to be added:**

| Blocker | Why |
|---|---|
| active hold | holds are not modelled yet |
| matching = Unmatched or Conflict | matching engine does not exist yet |
| classification = NEEDS_REVIEW | must never auto-generate entitlement |
| cycle closed | closed periods must not accept new money |

---

## 5. The gap that matters most

**FACT.** There is today **no transition** from a baseline subscriber
(`installation_subscriber_state`, 5,693 rows) to an operational entitlement
(`installation_entitlements`, 0 rows). The dashboard merges them for display only.

**INFERENCE.** Until that transition exists, `payment_eligible = true` on 2,196 rows is a
statement of readiness, not a queue of payable work. Nothing can currently be paid.

**RECOMMENDATION.** Introduce one guarded transition — "raise entitlement for cycle" —
which for each eligible subscriber creates exactly one entitlement for its **current** stage,
carrying `agent_id_at_entitlement` and `scheme_version_id`. It must be idempotent per
`(subscriber, stage, cycle)` so that re-running a cycle cannot double-raise, and it must
refuse any subscriber that is unresolved, held, unmatched, or DONE.

**This single transition is what turns the historical baseline into an operating system,
and it is where a mistake would cost real money.** It should be the most heavily tested RPC
in the product.

---

## 6. Draft → Posted

**RECOMMENDATION.** Payment batches, financial corrections, configuration publishing and
cycle closing all share one lifecycle:

```
Draft ──► Reviewed ──► Posted ──► Paid
                          │
                          └──► Correction / Adjustment / Reversal
```

After `Posted`, nothing is edited in place. **FACT:** the commission month already has a
two-state version of this (`status ∈ {draft, approved}`, `20260809190000`), and
`update_commission_row` refuses to touch a month that is not `draft` — the pattern exists
and can be generalised.

---

## 7. Cycle lifecycle

**RECOMMENDATION.**

```
Draft → SaaS Imported → Matching → Under Review → Finance Review
      → Ready for Payment → Partially Paid → Paid → Closed
```

A closed cycle owns an immutable snapshot: imported data reference, matching decisions,
eligibility set, batches, exceptions, configuration versions used, tier snapshots.
Reopening is an audited event, never a silent state change.
