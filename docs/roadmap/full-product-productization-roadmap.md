# BABIL FLOW — Productization Roadmap

**Baseline:** `v1.0.0` — frozen, deployable, recoverable.
**Rule for every phase:** the financial engine is consumed, never rebuilt. No
phase changes a commission rule, an installation rule, the ledger, permissions,
RLS, or timezone logic.

---

## Gap matrix

**P0** required for a complete operational system · **P1** required for strong
production usability · **P2** refinement.

| # | Capability | Today | Gap | Sev | Backend | Frontend | Work |
|---|---|---|---|---|---|---|---|
| 1 | Addressable screens | scroll anchors | no route, link, Back, or refresh | **P0** | n/a | ✗ | router + shell |
| 2 | Subscriber registry | none | 5,693 subscribers, no list | **P0** | needs RPC | ✗ | RPC + screen |
| 3 | Subscriber case | none | cannot open one subscriber | **P0** | needs RPC | ✗ | RPC + workspace |
| 4 | Exceptions queue | 300 of 22,727 | 98.7% unreachable | **P0** | needs RPC | partial | RPC + queue |
| 5 | Cycle workspace | tabs on a panel | no lifecycle, no blockers | **P0** | needs blockers RPC | partial | RPC + workspace |
| 6 | Five aliased labels | 1 shared panel | invoices/ready/holds/batches/cycle identical | **P0** | mostly ready | ✗ | 5 screens |
| 7 | Payment batch workspace | queue widget | no batch lifecycle screen | **P0** | ready | ✗ | 2 screens |
| 8 | Agent workspace | modal + tab | not addressable | **P1** | ready | partial | screen |
| 9 | Audit screen | modal, limit-only | not filterable or pageable | **P1** | needs RPC | ✗ | RPC + screen |
| 10 | Users & permissions | modal | no user detail or explainer | **P1** | ready | partial | 4 screens |
| 11 | Import centre | scattered buttons | no import history screen | **P1** | ready | partial | screen |
| 12 | Reports workspace | tab strip | no filters or drill-back | **P1** | ready | partial | screen |
| 13 | Persist classification | browser only | table empty in production | **P1** | missing workflow | n/a | RPC at import |
| 14 | KPI drill-down | terminal numbers | blocked money not clickable | **P1** | ready | ✗ | routing |
| 15 | Master data screens | 1 shared panel | agents/FDT share a panel | **P1** | ready | partial | 5 screens |
| 16 | Ledger screen | limit=50 | no paged ledger view | **P2** | needs RPC | ✗ | RPC + screen |
| 17 | Scheme version diff | none | cannot compare versions | **P2** | needs view | ✗ | view + screen |
| 18 | Archive browsing | modal | no historical navigation | **P2** | ready | ✗ | screens |

**P0: 7 · P1: 8 · P2: 3.**

---

## Phases

Each phase ends deployable, tested, and independently valuable.

### Phase A — Application foundation
**Goal:** the app becomes addressable. No screen changes behaviour.

Vite + TypeScript build; `legacy/app.js` extracted verbatim; History router with
guards and breadcrumbs; shell, session and cycle header ported; `domain/` typed
(money, zone, cycle stage, projected); Pages workflow with `404.html` fallback.

**Backend:** none.
**Risk:** *medium* — deploy mechanism changes. Mitigated by CI gating the build
and `v1.0.0` staying build-free and deployable.
**Tests:** router (deep link, Back, refresh, guard); `load-current-app.js`
re-pointed; 380 existing stay green.
**Accepts when:** every current destination has a URL that survives refresh and
Back; no behaviour changed.

### Phase B — Commission operations
**Goal:** the cycle becomes a workspace.

`/commissions`, `/commissions/cycles`, cycle workspace with overview, scopes,
paged events, exceptions, review, payout, audit. Agents list and `/agents/:id`.
FDT breakdown.

**Backend:** `commission_finalization_blockers`, `list_agents_financial`,
`list_commission_exceptions`.
**Risk:** *low* — reads only; payout reuses proven RPCs.
**Accepts when:** an operator can open July, see why finalization is blocked,
open a scope, page every event, and reach the resolving screen for any exception.

### Phase C — Installation case management
**Goal:** the largest gap closes.

`/installation/subscribers` with server paging and filters; the subscriber case
workspace with eight tabs; derived timeline; the installation cycle workspace.

**Backend:** `list_installation_subscribers`, `installation_subscriber_case`,
`subscriber_timeline`, `installation_cycle_state`.
**Risk:** *medium* — the largest new surface; timeline must be derived, never
stored.
**Accepts when:** any of 5,693 subscribers can be found, opened, and explained —
stage, eligibility, invoice, hold, amount, and why blocked — without an export.

### Phase D — Payments and exceptions
**Goal:** money movement gets a workspace; the queue becomes usable.

`/finance/payment-batches` and batch detail; `/exceptions` paged with filters and
owner routing; invoices, ready-for-payment and holds become three real screens.

**Backend:** `list_payment_batches`, `list_installation_invoices`.
**Risk:** *medium-high* — closest to money. No client-side posting logic; every
action is an existing RPC; server revalidation unchanged.
**Accepts when:** the five aliased labels are five screens; a batch shows draft,
validated and rejected lines with server reasons; blocked records cannot be
selected.

### Phase E — Master data and administration
**Goal:** administration leaves modals.

Agents, aliases, FDT, packages, scheme versions; users, user detail, roles,
overrides, effective-permission explainer.

**Backend:** none (`explain_permission` already suffices).
**Risk:** *low*.
**Accepts when:** an admin can answer "why can this user do this?" on screen,
showing role, grant, deny, scope, and decision.

### Phase F — Reports, imports, audit
**Goal:** the read surfaces become navigable.

Reports workspace with filters, preview, export and drill-back; import centre
with per-batch detail; audit screen with filters and paging; persist
classification at import.

**Backend:** `list_audit_events`, `list_import_batches`, classification RPC.
**Risk:** *low-medium* — the classification RPC moves existing tested rules
server-side; it must produce identical output, asserted against the current
browser implementation.
**Accepts when:** every report filters, exports and links back to records; audit
is filterable across the full history.

### Phase G — Legacy exit
**Goal:** `index.html` stops being an application.

Legacy month workflow wrapped read-only; archive and comparison replaced;
`legacy/app.js` emptied or reduced to the read-only path; text-coupled tests
re-pointed.

**Risk:** *low* if the removal conditions in the exit plan are respected;
*high* if legacy paths are deleted while still reachable.
**Accepts when:** no application logic remains in `index.html` and every
historical month is still readable.

### Phase H — Full operational acceptance
Against `docs/acceptance/full-operational-system-acceptance.md`, on production
data, at four widths, with a role-by-role permission pass and a performance
re-measure.

---

## Risk by phase

| Phase | Risk | Dominant hazard |
|---|---|---|
| A | medium | deploy mechanism change |
| B | low | read-mostly |
| C | medium | largest new surface |
| D | **medium-high** | adjacent to money movement |
| E | low | administration only |
| F | low-medium | classification must match exactly |
| G | low → high | only if removal conditions ignored |
| H | low | verification |

**Sequencing note.** D follows C deliberately: payment screens are worth
building only once a subscriber can be opened and explained, because a payment
decision that cannot be traced to a case is the failure mode this product exists
to prevent. If schedule pressure forces a reorder, move E earlier — never D.
