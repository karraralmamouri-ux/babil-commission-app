# Migration Roadmap — vNext

**No implementation is authorised by this document.** Ordering proposal only.

Principle: **no big-bang rewrite.** Agent Commissions keeps working untouched throughout.
Each phase is additive, independently shippable, and revertible by not using the new path.

---

## Phase order and why

The order is driven by dependency, not by visibility. Phases 1–2 produce almost no visible
change but everything later depends on them.

### Phase 0 — Critical integrity and the correction foundation

**Revised at architecture review.** Phase 0 is no longer only small fixes: the
correction/reversal foundation was promoted here, because expanding payment workflows on a
system with no legal correction path is how a wrong payment becomes an out-of-audit database
edit.

**0a — integrity fixes** (independent, ship first)

1. **R-01** — recompute the commission tier basis server-side in `publish_commission_month`.
   The client-supplied basis stops being the financial source of truth.
2. **R-09** — send the real `file_checksum` from the browser; it is already accepted.
3. **R-10** — normalize `index.html` line endings once via `.gitattributes`.

**0b — correction and reversal foundation** (**R-03**, approved as critical)

4. Ledger transaction types (`HISTORICAL_PAYMENT` · `PAYMENT` · `ADJUSTMENT` · `CORRECTION` ·
   `REVERSAL`) with `reverses_ledger_id`, `reason` and `request_id`.
5. A reversal RPC: server-side, audited, idempotent, gated on `payment.reverse`.
6. Derived current state, so a reversal returns the subscriber to eligible automatically.

**Sequencing rule, approved:** correction/reversal architecture must not be deferred until
after large-scale payment expansion. Phase 6 must not begin without it.

*0a ships alone with no schema change beyond function bodies. 0b may use a compatibility
layer over the existing two payment tables rather than consolidating them —
see `financial-domain-model-vnext.md` §2.5.*

### Phase 1 — Master data

`agents`, `agent_aliases`, `fdts`, `packages`.

Seeded from `assets/data/raw-import-config.json` (11 agents, dozens of aliases, 3 cabinet
ranges) and from the three package codes. The import path keeps reading the JSON config until
Phase 3, so behaviour does not change.

*Gate:* aliases resolve to the same agents the JSON produces, for every alias.

### Phase 2 — Raw SaaS storage

`import_batches`, `raw_saas_users`, `raw_saas_activation_events`, append-only.

Import writes raw rows **in addition to** today's aggregate path. Nothing reads them yet.

*Gate:* one month imported both ways; aggregates derived from raw rows match the aggregates
the browser produced, exactly.

**This is the phase that makes everything else possible.** Until raw data exists, matching,
new/existing detection, and re-derivation are all impossible.

### Phase 3 — Subscriber registry and matching

`subscribers` (extending `installation_subscribers`), attribution and transfer history,
matching engine producing NEW / EXISTING / NEEDS_REVIEW.

*Gate:* the 5,693 historical subscribers all resolve to themselves; zero duplicates created.

### Phase 4 — Scheme versioning

`installation_fee_schemes`, `..._versions`, `..._stage_definitions`, enrolments.
SQL stage functions become lookups over the published version. **R-02 closed.**

*Gate:* every one of the 5,693 subscribers keeps its exact current stage and eligibility.
`5693 / 2196 / 3497 / 19` unchanged.

### Phase 5 — Ledger and holds

Historical rows presented as `HISTORICAL_PAYMENT` (physically in place or copied — see the
compatibility note in `financial-domain-model-vnext.md` §2.5), plus `holds`. **R-07 closed;
R-03 already closed in Phase 0b.**

*Gate:* state derived from the ledger reproduces the stored state exactly. This is the
reconciliation gate from `historical-migration-and-cutover.md` §4 step 6 — **do not proceed
past it on a mismatch.**

### Phase 6 — Cycles, entitlement raising, batches

`monthly_cycles`, the guarded "raise entitlement" transition, `payment_batches`,
`invoice_links` with its uniqueness constraint.

**This is where the 2,196 eligible subscribers become payable work** — the gap identified in
`financial-state-machine.md` §5.

*Gate:* a dry-run cycle on staging raises exactly 2,196 entitlements, at the correct stages,
and is idempotent on re-run.

### Phase 7 — Capabilities

`capabilities`, `role_templates`, `has_capability()` as a behaviour-preserving shim, then
per-user grants, then scopes (modelled, unenforced, then enforced). **R-06 closed.**

*Gate:* every existing user retains identical effective permissions on the day of the switch.

### Phase 8 — Commission Engine vNext

`commission_scheme_versions` (V1 = `activation_events`, recording today's truth honestly),
`commission_activation_facts`, `commission_cycle_snapshots`.

Three things happen here, all consequences of approved **D-02**:

1. Tier population becomes `COUNT(DISTINCT subscriber)` in scope.
2. Commissionable activations are counted **per event**, deduplicated on activation
   identity — so a subscriber's second qualifying activation is paid.
3. `seenIds` subscriber-level deduplication is removed as incompatible legacy behaviour
   (**R-05**).

V2 with `unique_active_users` waits on **D-03** only — the definition of "active".

*Gate:* closed months recompute to their stored tier, unchanged. Tier population and
commissionable activations reconcile independently against a known month.

### Phase 9 — Finance workspace and navigation

Queues, drill-downs, subscriber case view, agent financial profile. Presentation only, on top
of a model that already answers the questions.

### Phase 10 — Odoo integration

Invoice identity, verification source and record references, over a backend/Edge Function
channel with credentials server-side. Never browser-side. Waits on **D-10**.

---

## Sequencing constraints

```
Phase 0a ─────────────────────────► independent, ship first
Phase 0b ──────────────────────────────────────► REQUIRED BEFORE Phase 6
Phase 1  ──► Phase 3 ──► Phase 6
Phase 2  ──► Phase 3
Phase 4  ──► Phase 5 ──► Phase 6 ──► Phase 9
Phase 7  ─────────────────────────► independent after Phase 1
Phase 8  ─────────────────────────► needs D-03 for V2; D-02 already approved
Phase 10 ─────────────────────────► after Phase 6; needs D-10
```

**Two hard ordering rules:**

1. **Phase 0b before Phase 6.** No payment expansion without a legal correction path.
2. **Phase 5 before Phase 6.** Raising entitlements against a state never reconciled against
   a ledger is how double payments happen.

---

## Per-phase discipline

Every phase, without exception:

1. Local Postgres suite green (`npm run localdb:test`, currently 102 assertions).
2. Unit suite green (`npm test`, currently 162).
3. New behaviour has a test that **fails without the change** — verified, not assumed.
4. Migration safety scan clean; `revoke all` before any `grant`.
5. Staging: apply, exercise with real volume, verify ACLs behaviourally as viewer and
   accountant, then clean back to baseline.
6. Production: read-only readiness check, verified backup, apply, verify, deploy, smoke test.
7. Explicit approval before any production write.

**The counts `5693 / 17117 / 2196 / 3497 / 19` are the invariant.** They are checked before
and after every phase. Any phase that changes one of them without an explicit, approved
business reason has a bug.
