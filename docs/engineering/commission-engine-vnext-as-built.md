# Commission Engine vNext — As Built

Written after deployment, from measured results.

Starting SHA `6d36cfb` → merged `aadb8ce`.
Migrations `20260821090000` · `20260821120000` · `20260821150000`.

---

## 1. D-03, resolved

The commission tier is chosen from **unique activated subscribers per commission
cycle**: each distinct subscriber counted **once** if they had at least one
qualifying activation in the cycle.

It is explicitly **not**:

- `enabled` + `expiration` (the old candidate definition)
- the total activation-event count (what `p35+p45+p65` actually measured)

Two metrics, kept apart everywhere:

```
tier basis            = count(distinct subscriber identity)
commissionable events = count(distinct activation event id)
```

A subscriber with three qualifying activations contributes **1** to the tier and
**3** to the commission. The basis itself is configuration
(`commission_scheme_versions.tier_basis`), so the rule is not re-buried in code.

Subscriber identity resolves in order: canonical `subscriber_identities.id` →
stable `saas_user_id` → `username_key`. Display names never participate.

---

## 2. V1 reconstructed from the live configuration

Not re-typed from a specification. Read out of production
(`commission_months.tiers`, identical in both existing months, and matching
`defaultTiers` in the page):

| Tier | Subscribers | P-35000 | P-45000 | P-65000 |
|---|---|---|---|---|
| T1 | 0–200 | 4,000 | 5,500 | 8,000 |
| T2 | 201–400 | 4,750 | 6,000 | 9,000 |
| T3 | 401+ | 6,000 | 8,000 | 11,500 |

**V1 has no `effective_from`.** These values are demonstrably in force today, but
when they started is unknown; inventing a date would have asserted authority
over months they may not have governed. An open lower bound states what is
actually known.

A published version is immutable — a trigger allows only retirement. Tier bands
must be contiguous; a gap is refused at publish because a gap means some
subscriber count has no tier, which is a silent financial hole.

---

## 3. Scope, verified not assumed

Checked against live data before building:

```
zone old : 34 rows, 17 with tier_group_id   → pooled by agent
zone new : 48 rows,  0 with tier_group_id   → per cabinet
```

So **old zone tiers at agent scope, new zone at FDT scope** — recorded as
configuration (`old_zone_scope` / `new_zone_scope`), and the zone itself is
derived from the FDT master rather than entered by hand.

---

## 4. Qualification

Package semantics say what a package *is*; the scheme says whether it earns.
`Loan-3` is guarded twice: it is `DEBT_SERVICE` so it never enters the billable
set, **and** a trigger refuses to let any scheme version mark a debt-service
package as qualifying. A misconfiguration cannot create money.

`Diamond` (`UNKNOWN`) does not qualify and raises a blocking exception rather
than being dropped.

---

## 5. Exceptions

Nothing is discarded silently. `UNKNOWN_AGENT`, `UNKNOWN_FDT`,
`UNKNOWN_PACKAGE`, `IDENTITY_CONFLICT`, `SOURCE_INCOMPLETE`, `EVENT_CONFLICT`,
`ATTRIBUTION_REVIEW`, `MISSING_PERIOD` are persisted and block finalization when
financially material.

**A defect found here:** recalculation deleted and recreated open exceptions, so
waiving one was pointless — it returned on the next run and blocked finalization
again. A reviewer's decision is not a calculation result; resolved and waived
exceptions are now never recreated for the same event and reason.

---

## 6. Projected vs final

An open cycle shows a projected calculation from whatever is imported. Producing
a **final** result requires every contributing source batch to be proven
`COMPLETE`, and all blocking exceptions resolved. Finalization writes immutable
per-scope snapshots carrying scheme version, both counts, tier, package
breakdown, gross, source batches, measurement window and timestamps.

Tested: an event inserted *after* finalization does not move the snapshot, and a
finalized cycle refuses recalculation.

---

## 7. Cycle close and reopen — both domains

Close produces a snapshot and records actor and reason. Reopen requires a
written reason and is refused when the cycle carries **posted money**; correction
and reversal remain the only path there, which is what Phase 0b built them for.

Installation close additionally refuses while pending payment items remain.
Posted amount is measured — installation from paid batch items, commission from
the ledger — not inferred from status.

---

## 8. Legacy compatibility — and a correction to the brief

The brief (§16) states the legacy client parser deduplicates at **subscriber**
level. **It does not.** `seenIds` keys on `rawField(row,'id')` — the activation
event id, measured earlier as 100% distinct in both activation workbooks. The
legacy dedup is already at the correct level; removing it would have discarded
nothing and broken historical reads.

The real legacy violation is §17: the legacy path picks the tier from
`p35+p45+p65`, an **event count**, where the approved rule counts distinct
subscribers. The in-code marker names that specifically, and a test pins the
dedup key so a later "fix" cannot move it to subscriber level and destroy real
events.

`tier_basis_qty` is retired for vNext: the server derives the basis from
persisted events and canonical identities, and
`commission_event_entitlements` has no column for a client-supplied basis.

Legacy `commission_rows` / `commission_months` are untouched and still readable.
Every cycle records `engine_version`, so legacy and vNext cannot mix inside one
finalized cycle.

**Cutover:** legacy months stay frozen; the first cycle created after this
deployment is vNext. No historical month was recalculated — production shows
0 commission cycles after deployment.

---

## 9. Non-posting reconciliation (July 2026)

Run as a pure read against production. **Nothing was written.**

| | |
|---|---|
| raw events in window | 29,246 |
| billable events | 7,520 |
| **distinct subscribers (vNext tier basis)** | **7,324** |
| events per subscriber | 1.03 |
| old-zone scopes / new-zone scopes | 11 / 24 |
| excluded debt-service events | 8,554 |
| events with unresolved scope | 18,536 |
| **legacy tier basis (`p35+p45+p65`)** | **7,533** |
| legacy rows | 41 |

Two things worth naming:

1. **The basis moves.** 7,324 against 7,533 — about **2.8% lower** under the
   resolved rule, because repeat activators now count once. This is the intended
   effect, and it is material enough that a tier sitting near a band edge could
   land differently.
2. **18,536 events have no reseller scope.** These are overwhelmingly the direct
   company accounts (`FTTH_Users` ≈ 18,513 in July). They correctly earn no
   reseller commission, and under vNext they surface as exceptions rather than
   vanishing.

This is a comparison only. Historical commission remains frozen.

---

## 10. Permissions

Eight capabilities added: `commission.view`, `manage_cycle`, `configure`,
`finalize`, `prepare_payment`, `execute_payment`, `reopen`, `review_exception`.

Role parity preserved. The accountant inherits payment preparation, execution
and exception review — and **not** finalize, configure or reopen: recording a
payment is not authority to decide what is owed. Admin can grant any single
capability to a specific user without promoting them, proven by test.

---

## 11. Client layer

Five panels: cycle, scopes, exceptions, configuration, agent financial profile.
The scope drill-down prints both metrics side by side so the difference is
visible rather than asserted.

The page computes nothing financial. Tests assert the commission block and
`commission-vnext.js` contain no tier bound and no rate, and that neither derives
the tier basis from the event count.

---

## 12. Tests

| Suite | Count |
|---|---|
| JS | 260 (was 234) |
| Local database assertions | 311 (was 256) |

Covering the §20 repeated-activation case, §21 Loan-3, §22 duplicate event, zone
scopes, configuration immutability and V2 without code change, source
completeness gating, snapshot immutability, close/reopen in both domains, and
permission separation.

---

## 13. Deployment notes

Two tooling defects surfaced and were fixed properly rather than bypassed:

- The targeted-apply guard blocked the migration because it matched
  `public.commission_` by prefix, which covers the *new* configuration tables.
  Protected tables are now named exactly, and the guard was re-proven to still
  block writes to `commission_rows`, `installation_payments` and
  `financial_ledger`.
- The same guard blocked `drop table if exists tmp_*` inside a function body.
  The allowlist now covers temp tables specifically; `drop table
  public.commission_rows` is still blocked.

The scheme migration is **not** safely re-runnable after its V1 publish — the
immutability trigger correctly rejects re-seeding published tiers. That is the
right behaviour for the trigger; it means the migration must be recorded once
and never replayed.

---

## 14. Remaining `app_settings` status

Unchanged from the previous phase and still accurate: the legacy commission raw
import reads `app_settings.raw_import` directly. Master data mirrors it but does
not replace it.

vNext does **not** read `app_settings` at all — it reads agents, aliases, FDTs,
packages and the commission scheme. So the dependency is now confined entirely
to the legacy path, and `app_settings` can be retired when that path is removed.
It is not deleted.

---

## 15. Not implemented

- Live Odoo API integration
- Full product-wide visual redesign
- Commission payment batches at vNext granularity (payments still run through
  the existing `record_commission_payment` on `commission_rows`; the vNext
  entitlement-to-payment bridge is not built)
- Executive overview consolidation and the six formal report exports
- `commission_cycles.legacy_month_id` exists but nothing populates it yet
