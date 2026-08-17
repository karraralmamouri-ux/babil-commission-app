# Configuration Engine Architecture

---

## 1. What is hardcoded today

**FACT.**

| Business value | Where | Duplicated? |
|---|---|---|
| Remaining → stage → amount | `assets/js/installation-fees.js` `STAGE_BY_REMAINING` | **yes** — also in SQL `installation_stage_for_remaining` and `installation_amount_for_stage` |
| Qualifying packages | `assets/data/raw-import-config.json` `profiles` | partly — the list is config, the bucket mapping is not |
| Package → commission bucket | `index.html:706` `profile==='P-35000'?'p35':…` | no, single point |
| Tier thresholds and rates | `index.html` `defaultTiers` (T1 0–200, T2 201–400, T3 401+) | snapshotted per month into `commission_months.tiers` |
| Role capabilities | `index.html` `ROLE_PERMISSIONS` | **yes** — also `profiles_role_check` in SQL |
| FDT → owner agent | `raw-import-config.json` `cabinetRanges` | no |
| Agent aliases | `raw-import-config.json` `agents[].accounts[]` | no |

**FACT — what already works well.** Commission tiers are *snapshotted*: `state.tiers` is
saved with each month and each archive entry, and `publish_commission_month` receives
`p_tiers` and validates the applied tier against it. Changing today's tiers therefore does
not retroactively change a closed month. **This is the pattern the rest of the system should
copy.**

**FACT — what is fragile.** The installation stage table is defined twice, in two languages.
They agree today. If someone edits one, the constraint
`installation_state_stage_matches_remaining` will start rejecting writes that the browser
considers valid — a confusing failure rather than a clean one.

---

## 2. Design

**RECOMMENDATION.** Three layers, in order of increasing ceremony.

| Layer | For | Change process |
|---|---|---|
| **Master data** | agents, aliases, FDTs, packages | edit with audit |
| **Versioned configuration** | fee schemes, tier schemes, active-user rule | new version, publish |
| **Hard invariants** | no double payment, DONE unpayable, idempotency | code + constraints, never configurable |

The third layer is the important one. **Financial safety must not be configurable.**
`risk-and-open-decisions.md` R-01 explains why.

---

## 3. Versioned configuration lifecycle

```
Draft ──► Review ──► Published ──► Superseded
  │                      │
  └── freely edited      └── never edited; a change creates the next version
```

```sql
-- shape shared by every versioned configuration
id, code, version, status, effective_from, effective_to,
created_by, reviewed_by, published_by, published_at
```

**Rules.**

1. A `published` row is immutable. Enforce with a trigger, not convention.
2. Effective ranges must not overlap for the same `code`.
3. Every financial record stores the `*_version_id` it was computed under.
4. Publishing is a capability (`scheme.publish`), separate from editing.

**Why version 3 matters.** Without it, "why was this subscriber paid 3000?" becomes
unanswerable after the next scheme change. With it, the answer is a join.

---

## 4. Installation fee schemes

Seed V1 from the current constants — mechanical, no business decision:

| stage | sequence | amount | expected_remaining |
|---|---|---|---|
| P1 | 1 | 3000 | 13000 |
| P2 | 2 | 3000 | 10000 |
| P3 | 3 | 3000 | 7000 |
| P4 | 4 | 4000 | 4000 |
| DONE | 5 | 0 | 0 |

**A V2 with three or five stages must not touch V1 subscribers.** That is guaranteed by
`subscriber_installation_enrollments.scheme_version_id`, fixed at enrolment.

**Migration note.** The SQL functions `installation_stage_for_remaining` and
`installation_amount_for_stage` stay as thin lookups over the published version, so the
existing CHECK constraints keep working unchanged. This removes the duplication without
touching the constraints that protect the money.

---

## 5. Package master

```
packages(code, name, classification, commission_bucket, effective_from, effective_to)
```

| code | classification | commission_bucket |
|---|---|---|
| P-35000 | qualifying_paid_activation | p35 |
| P-45000 | qualifying_paid_activation | p45 |
| P-65000 | qualifying_paid_activation | p65 |
| Loan-3 | **debt_service** | null |

This one table removes three hardcoded behaviours: the qualifying-package list, the
bucket ternary at `index.html:706`, and the future Loan-3 exclusion. A new package becomes a
row, not a release.

---

## 6. Commission scheme

```
commission_scheme_versions(version, tier_basis, tier_scope, effective_from, status)
commission_tier_definitions(scheme_version_id, tier_key, min_qty, max_qty,
                            rate_p35, rate_p45, rate_p65)
```

**FACT.** Current real behaviour, read from code:

- `tier_basis` = `p35 + p45 + p65` — **activation counts**, deduplicated by `id` within a
  single import file only.
- `tier_scope` = **agent** for OLD ZONE (`tierGroupId = agentId`, `groupTotals` pooled per
  agent) and **per-FDT** for NEW ZONE (each cabinet is its own row with no group).

Seeding V1 with `tier_basis = 'activation_events'` records today's truth honestly. Switching
to `unique_active_users` becomes V2 with its own `effective_from`, leaving closed months
untouched.

**APPROVED.** The intended tier basis is **unique active users**, and tier population is
`COUNT(DISTINCT subscriber)` while commissionable activations are counted per event
(**D-02**).

**OPEN — D-03.** The formal definition of *active* remains pending business confirmation.
The code establishes none — there is no `enabled`, `status` or `expiration` field anywhere in
the current import. Potential evidence once raw SaaS storage lands: `enabled`, `expiration` /
`new_expiration`, service or account state. **It must not be invented here.** V1 records
`activation_events` honestly; V2 waits.

---

## 7. Configuration audit

Every publish writes: actor, config type, code, previous version, new version, diff,
reason, timestamp. Published financial configuration is exactly the kind of change that is
invisible in a normal diff and enormous in effect.
