# Reseller Financial Operations — Architecture Blueprint

Status: **architecture freeze proposal, not implemented.**
Repository state inspected: `main` @ `94b1873`.
Every claim below is tagged.

| Tag | Meaning |
|---|---|
| **FACT** | Read directly from this repository or the production database. |
| **INFERENCE** | Derived from evidence, but not stated anywhere explicitly. |
| **RECOMMENDATION** | Proposed target design. |
| **OPEN DECISION** | Business input required; not decidable from the code. |

---

## 1. The two domains

**FACT.** The application already contains two financial domains that share nothing but the
agent's name.

| | Agent Commissions | Installation Fees |
|---|---|---|
| Unit of money | activation event counts × tier rate | fixed instalment per subscriber stage |
| Tiers/stages | P35 / P45 / P65 → tier T1/T2/T3 | P1 / P2 / P3 / P4 / DONE |
| Period | `commission_months` (`YYYY-MM`) | historical snapshot + future cycles |
| Tables | `commission_months`, `commission_rows`, `commission_agents` | `installation_subscribers`, `installation_subscriber_state`, `installation_payment_history`, `installation_entitlements`, `installation_batches`, `installation_payments` |
| Code | `index.html` `calc()`, `calculateRawImport()` | `assets/js/installation-fees.js` |

**FACT.** P35/P45/P65 are *package names* that become commission quantity buckets
(`index.html` `normalizeRawProfile`, `calculateRawImport`). P1–P4 are *installation fee
stages* derived from `Remaining` (`assets/js/installation-fees.js` `STAGE_BY_REMAINING`).
The two never meet in code, and the installation module's header comment states this
explicitly. **This separation must survive the migration.**

---

## 2. Where the product is today

### 2.1 Agent Commissions — aggregate-only

**FACT.** The raw activation file is parsed **entirely in the browser**
(`calculateRawImport`, `index.html:688`). What reaches the database is an aggregate per
`(month, zone, name)`:

```
commission_rows(month_id, zone, name, p35, p45, p65, custom_tier,
                tier_mode, applied_tier, tier_basis_qty,
                tier_group_id, tier_group_name, source_account,
                source_breakdown jsonb, paid, payment_date)
```

**FACT.** No subscriber identity is stored for commissions anywhere. No raw SaaS event is
stored anywhere. `source_breakdown` (added by `20260815113000`) is the finest grain that
survives, and it holds `{parent, fdt, agentId, agentName, p35, p45, p65}` — counts, not
subscribers.

**INFERENCE.** Once the browser tab is closed, the activation file is the only record of
which subscriber produced which commission. The system cannot answer "was this subscriber
counted twice across two months" because it never knew the subscriber.

### 2.2 Installation Fees — two half-connected halves

**FACT.** The historical baseline exists and is correct in production:
5,693 subscribers · 17,117 payment events · as-of `2026-07-31` · 2,196 eligible ·
3,497 blocked · 19 unresolved.

**FACT.** The operational side (`installation_entitlements` → invoice audit → payment) is
deployed but holds **0 rows**. The dashboard now merges both for display
(`installationDashboardRows`, added `f31705b`/`94b1873`), but the merge is display-only —
there is no process that promotes a baseline subscriber into an operational entitlement.

**This is the central gap.** The historical state says "5,693 subscribers, 2,196 of them owe
a next instalment", and nothing converts that into payable work.

---

## 3. Target architecture in one picture

```
   SaaS export ──► raw_saas_activation_events   (immutable, append-only)
                            │
                            ▼
                   matching + classification         ◄── package master
                   (NEW / EXISTING / NEEDS_REVIEW)   ◄── agent aliases
                            │
                            ▼
   subscribers  ◄──── attribution / transfer history (event-sourced)
        │
        ├──► enrollment in an installation_fee_scheme_version  (immutable at enrolment)
        │            │
        │            ▼
        │    installation_entitlements ──► invoice link ──► payment batch ──► ledger
        │            (one per subscriber per stage)
        │
        └──► commission cycle: unique-active-user snapshot ──► tier snapshot ──► payout
```

**RECOMMENDATION.** Three sources of truth, never overlapping:

| Source | Owns | Mutability |
|---|---|---|
| SaaS | what happened operationally | immutable once imported |
| Babil | who it belongs to, what is owed, what is paid | controlled, audited |
| Odoo (future) | accounting invoice identity | external, referenced not copied |

---

## 4. The cutover

**FACT.** Approved baseline date is `2026-07-31`, stored on every one of the 5,693 state
rows (`installation_subscriber_state.as_of_date`).

**RECOMMENDATION.**

- `≤ 2026-07-31` — historical financial truth. Read-only. Never recomputed from SaaS.
- `≥ 2026-08-01` — operational system. Continues from the stored stage.

**The rule that must never break:** a subscriber whose history says P1 and P2 are paid
resumes at **P3**. The system must be structurally incapable of restarting them at P1.
Today that is guaranteed only by the `(subscriber, stage)` unique key on
`installation_payment_history` — which prevents a *duplicate* P1 but does not by itself
prevent a *new entitlement* being raised for P1. **See `financial-state-machine.md` §4.**

---

## 5. Non-negotiable invariants

**FACT — already enforced in the database:**

| Invariant | Enforced by |
|---|---|
| No duplicate stage payment | `installation_history_identity_key unique (subscriber_uuid, stage)` |
| One payment per entitlement | `installation_payments_entitlement_key unique (entitlement_id)` |
| Unresolved cannot be eligible | `installation_state_unresolved_is_never_eligible` |
| Mismatch cannot be resolved | `installation_state_mismatch_is_unresolved` |
| DONE cannot be paid | `installation_state_eligible_needs_pending_stage` + `installation_entitlements_done_is_unpayable` |
| Stage must match Remaining | `installation_state_stage_matches_remaining` (NULL-safe) |
| Payment idempotency | `request_id` checked against `audit_logs` in every financial RPC |
| Concurrency | `pg_advisory_xact_lock` + `select … for update` |
| Browser cannot write | `authenticated` holds `SELECT` only on all six installation tables |

**RECOMMENDATION.** These stay in SQL. They must never become configuration.

---

## 6. What must become configuration

**FACT — currently hardcoded:**

| Value | Location |
|---|---|
| P1/P2/P3/P4 amounts and Remaining thresholds | `assets/js/installation-fees.js` `STAGE_BY_REMAINING`, and again in SQL `installation_stage_for_remaining` / `installation_amount_for_stage` |
| Qualifying packages → quantity bucket | `index.html` `normalizeRawProfile` and `field = profile==='P-35000'?'p35':…` |
| Tier thresholds and rates | `index.html` `defaultTiers` (T1 ≤200, T2 201–400, T3 401+) |
| Role → capability matrix | `index.html` `ROLE_PERMISSIONS` **and** `profiles_role_check` in SQL |

**The stage table is defined twice** — once in JavaScript, once in SQL. They agree today.
Nothing enforces that they keep agreeing. See `risk-and-open-decisions.md` R-02.

**RECOMMENDATION.** Move to versioned master data with effective dates and a
Draft → Review → Published lifecycle. Published financial configuration is never edited;
change creates a new version. Existing enrolments keep
`scheme_version_id_at_enrollment`. See `configuration-engine-architecture.md`.

---

## 7. Migration principle

**RECOMMENDATION.** No big-bang rewrite. Agent Commissions keeps working untouched
throughout. Installation Fees gains capability in additive layers, each shippable and
reversible. See `migration-roadmap-vnext.md` for the ordered plan.

---

## Related documents

- `installation-fees-business-rules.md` — the rules, including Loan-3 and new/existing
- `financial-state-machine.md` — states, transitions, and what blocks payment
- `navigation-and-screen-map-vnext.md` — target information architecture
- `../engineering/financial-domain-model-vnext.md` — proposed tables
- `../engineering/configuration-engine-architecture.md` — versioned config
- `../engineering/permission-and-scope-model.md` — capabilities and scopes
- `../engineering/saas-import-matching-contract.md` — import and matching
- `../engineering/finance-payment-controls.md` — payment safety
- `../engineering/historical-migration-and-cutover.md` — baseline preservation
- `../engineering/migration-roadmap-vnext.md` — ordered migration
- `../engineering/risk-and-open-decisions.md` — risks and open questions
