# BABIL FLOW v1.0.0 — Release Notes

**Reseller Financial Operations**

| | |
|---|---|
| Version | `v1.0.0` — see `git show v1.0.0` for the exact tagged commit |
| Audited commit | `e6a693335a8e87a16a7754f66586a19f3a3565d7` |
| Application code | identical between the audited commit and the tag; every commit in between is one of these release documents, verified by `git diff e6a6933 v1.0.0 -- . ':(exclude)docs'` returning empty |
| Released | 2026-08-19 |
| Production | `fbgffpxpskjzgheheikd` · `ACTIVE_HEALTHY` · Postgres 17.6.1.155 |
| Application | https://karraralmamouri-ux.github.io/babil-commission-app/ |
| Automated coverage | 380 JS · 465 DB assertions |

---

## Product

BABIL FLOW is the operational and financial system of record for reseller
commissions and installation fees. The server calculates; the browser displays.
No financial number is derived in the frontend.

## Commission vNext

Configuration-driven, event-based, server-authoritative.

- **Tier basis is unique activated subscribers per cycle**, not event count. A
  subscriber counts once toward the tier; each qualifying event may still earn.
- **OLD ZONE is scoped by agent; NEW ZONE by cabinet (FDT).** The mapping is
  exactly one-to-one and is asserted on every calculation.
- **Loan-3 earns nothing** and never contributes to a tier.
- An unregistered cabinet is `unresolved` — it never silently becomes OLD ZONE,
  and its money is blocked until a human classifies it.
- Cycle lifecycle: draft → review → approved → payable → closed, with reopen.

## Installation Fees

Versioned fee schemes, enrollment, cycles, holds, invoices and payment batches.
Historical subscribers keep their stage; nothing restarts at P1 and no historical
payment is ever reconstructed. `NEW` is only asserted from a source proven
complete — an unproven source yields `NEEDS_REVIEW`, never a guess.

## FDT onboarding

Cabinet classification is an admin task, not a developer task. Discovery lists
every unregistered cabinet with its event count, subscriber count, observed
parents and first/last seen. Registration is individual or bulk, requires
`fdt.manage`, demands the zone **explicitly**, is audited with before/after, and
is idempotent by request id. Bulk registration validates every row before writing
any, so a bad row rejects the batch instead of leaving a half-applied
configuration that money is then calculated against.

## Permissions

44 capabilities across four role templates — admin 44, accountant 20, monitor 8,
viewer 8 — plus per-user grants and denies.

**An explicit DENY overrides an explicit GRANT and overrides the role itself,
including admin.** Hidden buttons are a convenience; every financial RPC checks
the capability server-side.

## Financial ledger

Posted entries are immutable: amount and direction cannot change and rows cannot
be deleted. Benign annotation stays permitted. Payments, reversals and
corrections are atomic, idempotent by request id, and safe under concurrency —
concurrent attempts produce exactly one payment and exactly one reversal.

Authority is separated: recording a payment does not confer the power to correct
one.

## Reports

Six server-side reports — management summary, commission cycle detail, agent
financial statement, installation fees detail, exceptions/blocked, and
audit/corrections — plus exception financial impact. Summary, detail, snapshots
and event entitlements all agree; exports carry the same values.

## SaaS import

Excel remains the operational input. The parser handles standard timestamps,
compact forms (`2026-04-30 235650`), true Excel date cells, and observed header
corruptions (`irstname`, `lastnam`, `tnam`, `proile_name`).

**Timestamps are pinned to the source timezone**, so the same file imported from
two machines yields the same instant. Cycle boundaries are Baghdad-based
independently of the database session timezone: July is
`2026-06-30T21:00Z` inclusive to `2026-07-31T21:00Z` exclusive.

`ct_password` is dropped at parse. It is never stored, hashed, logged, exported,
or placed in a fixture.

## Security

- Row-level security on every application table; no table without it.
- Every `SECURITY DEFINER` function pins `search_path`.
- No privileges for anonymous roles; unauthenticated reads are refused.
- Raw SaaS history — phone, national id, card owner — is admin-only.
- The browser holds a publishable key only, gated entirely by RLS.
- No external font, CDN or third-party request on any page load.

## Performance

Measured on production volumes after the row-level-security evaluation fix:

| Path | Before | After |
|---|---|---|
| Open exceptions | 16,426 ms | **26.9 ms** |
| Exception financial impact | 7,923 ms | **291 ms** |
| Commission entitlements | 3,211 ms | **4.7 ms** |

Management summary 68 ms · cycle detail 11 ms · agent profile 9 ms ·
FDT candidates 38 ms.

## BABIL FLOW UI

Arabic RTL as the primary layout, not a mirrored Latin one. Navy sidebar, light
workspace, and a persistent header that always shows the cycle and its state.
Projected figures are visibly marked and never styled as final. Money uses one
format everywhere with tabular numerals. Every real colour pair meets AA.
Responsive to 375px with no horizontal overflow.

---

## Known operational exceptions at release

These are **data and process items, not defects**. The system blocks the affected
money and exposes the workflow to resolve each one.

| Item | Effect |
|---|---|
| 119 unclassified cabinets | 22,724 events blocked · 66,660,500 IQD indicative exposure |
| 2 unknown-parent events | 8,000 IQD blocked |
| July source completeness UNKNOWN | Finalization stays blocked until proven |
| **July cycle** | **UNDER_REVIEW — workflow accepted, financial finalization pending** |

July is deliberately not finalized. The calculation is correct and reconciled;
what remains is business classification.

## Deferred

**Odoo integration** is deferred by product decision and is not required for
v1.0. Preparation — the read-only connector, the integration contract and the
invoice fields — remains intact and unused. No key exists in the codebase and no
live call is made.

## Recovery position at release

The organization is on the Supabase **free plan**, where point-in-time recovery
is not available. The recovery point for v1.0 is a complete logical backup:
**50 tables, 184,322 rows, per-table SHA-256, migration state**, taken at
`2026-08-19T05:50:30Z` against release SHA `e6a6933`.

Enabling PITR requires a plan upgrade and is the first item in the post-launch
backlog.
