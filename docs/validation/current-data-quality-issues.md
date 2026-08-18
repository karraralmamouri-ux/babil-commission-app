# Current Data Quality Issues — Business Action Required

Unresolved issues found in real Production data during the first SaaS cycle
validation. Each needs a business decision; none is a code defect.

Measured 2026-08-24 against the July 2026 cycle (29,246 events).

---

## 1. Unknown parent accounts — 52 events

Three source `parent` values do not resolve to any agent or to the direct
company. Their events earn no commission and raise a blocking exception.

| Raw parent | Events | Question for the business |
|---|---|---|
| `hrins.office` | 47 | Is this an agent, an internal office, or direct company? |
| `office.1` | 4 | Same question — seen since the first empirical study. |
| `r.samer.mohammed` | 1 | The `r.` prefix suggests a reseller. Is this a new agent, or a typo of an existing one? |

**Action:** map each to an agent, or mark it direct-company/internal. Until then
these 52 events block cycle finalization — which is the correct behaviour.

**Do not** guess `r.samer.mohammed` into an existing agent by name similarity.

---

## 2. Canonical subscriber registry is empty — 0 rows

`subscriber_identities` and `subscriber_classifications` hold **0 rows** in
Production, although 57,522 raw events and 32,481 user snapshots are loaded.

Consequences today:

- Identity conflicts cannot be detected (the check has nothing to compare).
- `DIRECT_COMPANY` classification falls back to alias resolution. That works —
  18,484 July events are correctly excluded — but through a different route than
  the design intends.
- **NEW / EXISTING classification cannot run at all**, so no Installation Fee
  enrolment can be validated from SaaS data.

**Action:** decide whether to populate the registry from the loaded raw data.
This is the prerequisite for validating new Installation Fee enrolments; it is
not required for commission, which is why commission validated without it.

---

## 3. Source completeness is UNKNOWN for all batches

All three import batches remain `UNKNOWN`. This is honest — no source declares
its coverage — and it correctly blocks finalization.

**Action:** if July is known complete, declare it through
`declare_import_completeness` with coverage bounds and written evidence. Until
then the cycle stays PROJECTED, which is correct.

---

## 4. Only 24 cabinets are registered

`fdts` holds 24 cabinets from the legacy configuration, but July events carry
far more distinct FDT codes. Events whose cabinet is not registered fall to the
old zone and are tiered by agent.

**Action:** confirm whether the new-zone cabinet list is complete. If cabinets
are missing, some events are being tiered at agent scope when they should be
tiered per cabinet — which changes tier bands and therefore money.

**This is the highest-value open question in this document.**

---

## 5. Two export formats need watching

Discovered while validating, and now handled in the parser — recorded so the
pattern is recognised if it recurs:

- `created_at` exported as `2026-04-30 235650` (time without colons) in
  `April-2026_Activations.xlsx` and `غرامات دايني شهر 7.xlsx`.
- `lastname` truncated to `tnam` in `April-2026_Activations.xlsx`.

**Action:** none required — both are parsed. But if a future export produces a
non-zero `unparsedDates`, do not import it until the format is understood.

---

## 6. The two 18-8 workbooks are user snapshots, not activations — BLOCKING

`active 18-8.xlsx` and `all data 18-8.xlsx` were supplied as the current
activations source. Measured from content, neither is one.

| | `active 18-8.xlsx` | `all data 18-8.xlsx` |
|---|---|---|
| sha256 | `ba17d2925b887ac9…` | `80a2d6d133752ad0…` |
| Rows | 20,860 | 32,481 |
| `id` column | present, 20,860 distinct | **absent** |
| `activations_count` | absent | absent |
| event `parent` | absent (`parent_name` only) | absent |
| `enabled` | 1 × 20,860 (active subset) | 1 × 32,454 · 0 × 27 |
| `created_at` range | 2022-12-10 … **2026-08-05** | 2022-12-10 … **2026-08-15** |
| Parser verdict | USERS_SNAPSHOT | **REJECTED** — no `id` |

`created_at` here is the **user registration date**, not an activation timestamp.
Neither file contains a single 2026-08-16…18 activation event, so the expected
"cutoff around noon on 18/8" is not present in either.

`all data 18-8.xlsx` also cannot be imported even as a snapshot: without `id`
there is no stable identity anchor, and using `username` instead would breach the
approved identity rule and hide any id→username change.

**Action:** export the **activations** report for 2026-08-16 → 18 (the report
carrying `id`, `created_at`, `activations_count`, `parent`), and re-export
`all data` with the `id` column included.

## 7. Subscriber identity pipeline was never built — BLOCKING

Root cause established: `subscriber_identities` is referenced only by
migrations — the table, its constraints and readers. **No RPC inserts into it and
no client code writes it.** The pure matching function exists in
`assets/js/saas-import.js` but nothing calls it against Production and persists
the result. Production ingestion loaded only batches, events and snapshots.

So this is a **missing pipeline, not a defect and not a permissions problem**.
Nothing is broken; a step was never written.

**Action:** build the identity population path. `active 18-8.xlsx` is suitable
input — it carries 20,860 stable ids.
