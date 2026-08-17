# Migration Roadmap — vNext

**No implementation is authorised by this document.** Ordering proposal only.

Principle: **no big-bang rewrite.** Agent Commissions keeps working untouched throughout.
Each phase is additive, independently shippable, and revertible by not using the new path.

---

## Phase order and why

The order is driven by dependency, not by visibility. Phases 1–2 produce almost no visible
change but everything later depends on them.

### Phase 0 — Safety corrections (no new model)

Small, independent, and worth doing before anything is built on top.

1. **R-01** — recompute the commission tier basis server-side in `publish_commission_month`.
2. **R-09** — send the real `file_checksum` from the browser; it is already accepted.
3. **R-10** — normalize `index.html` line endings once via `.gitattributes`.

*Ships alone. No schema change beyond a function body. Highest value per unit of risk.*

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

`installation_payment_ledger` (absorbing the 17,117 historical rows as `kind='historical'`),
`holds`. **R-03 and R-07 closed.**

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

### Phase 8 — Commission unique-user tiers

`commission_scheme_versions` (V1 = `activation_events`, recording today's truth honestly),
`commission_cycle_snapshots`. V2 with `unique_active_users` only after **D-02** and **D-03**
are answered.

*Gate:* closed months recompute to their stored tier, unchanged.

### Phase 9 — Finance workspace and navigation

Queues, drill-downs, subscriber case view, agent financial profile. Presentation only, on top
of a model that already answers the questions.

---

## Sequencing constraints

```
Phase 0 ──────────────────────────► independent, ship first
Phase 1 ──► Phase 3 ──► Phase 6
Phase 2 ──► Phase 3
Phase 4 ──► Phase 5 ──► Phase 6 ──► Phase 9
Phase 7 ──────────────────────────► independent after Phase 1
Phase 8 ──────────────────────────► independent, needs D-02 and D-03
```

**Phase 5 must complete before Phase 6.** Raising entitlements against a state that has not
been reconciled against a ledger is how double payments happen.

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
