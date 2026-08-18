# Data Intelligence Foundation — As Built

What was actually built, measured against the three real workbooks. Every number
here came out of a run, not an estimate.

Migration: `20260819090000_add_data_intelligence_foundation.sql`
Parser: `assets/js/saas-import.js`
Tests: `tests/saas-import.test.js` (27), `tests/sql/data-intelligence.sql` (23)

This layer creates **no entitlement, no payment, and no commission**. It records
who exists, where they came from, and what the source actually said. The 5,693
historical subscribers and 17,117 payment rows are untouched and referenced, not
replaced.

---

## 1. Tables

| Table | Holds | Mutability |
|---|---|---|
| `agents` | the legal agent | editable master |
| `agent_aliases` | SaaS `parent` → agent, or an unresolved marker | editable master |
| `fdts` | cabinets, optionally owned | editable master |
| `packages` | package → semantic category | editable master |
| `saas_import_batches` | one row per imported file, with checksum | append |
| `saas_user_snapshots` | user state as of a moment | **append-only, trigger-enforced** |
| `saas_activation_events` | one row per activation event | **append-only, trigger-enforced** |
| `subscriber_identities` | the canonical subscriber | editable |
| `subscriber_attribution_history` | every attribution change | append |
| `subscriber_classifications` | New/Existing/Review with its evidence | append |

All ten are `select`-only for `authenticated`, RLS on, and carry **no
INSERT/UPDATE/DELETE/TRUNCATE** for any application role — verified by
`aclexplode()` in the SQL suite, not by reading the grant statements.

---

## 2. The four approved defaults, as implemented

### Multi-sheet import, event-level dedup

Every sheet satisfying the explicit column contract is imported; dedup keys on
the activation `id` across all sheets and files at once.

Running it on May settled the question the findings document had left open:

```
✓ "Sheet1"     rows=     1  imported=1  dupes=0
✓ "Sheet2"     rows=     1  imported=1  dupes=0
✗ "OLD ZONE"   rows=    29  REJECTED  CONTRACT_NOT_SATISFIED
✗ "NEW ZONE"   rows=    17  REJECTED  CONTRACT_NOT_SATISFIED
✓ "Worksheet"  rows= 28233  imported=28231  dupes=2
                            → 28,233 unique events
```

The two stray rows in `Sheet1`/`Sheet2` **are** duplicates of rows inside
`Worksheet` — the `dupes=2` on `Worksheet` is those same events arriving a
second time. Importing all three sheets and deduplicating by event yields
exactly 28,233 events: nothing lost, nothing counted twice. Both failure modes
the open question worried about are avoided by the same rule.

Subscriber-level dedup would have destroyed **8,517** July events and **8,065**
May events. The tests pin this directly.

### Diamond → `UNKNOWN`

Seeded as `semantic_category = 'UNKNOWN'`. `classifyNewness` only counts
`PAID_PACKAGE` events as qualifying, so Diamond can never produce `NEW`, and an
unregistered package code is treated the same way.

### `office.1` → unresolved

Stored as an alias row with `resolution = 'needs_review'` and `agent_id = null`.
A CHECK constraint makes the two states mutually exclusive: a confirmed mapping
must carry an agent, and a review marker must not. No agent is ever created from
a file.

### Completeness → `UNKNOWN`

`completeness_status` defaults to `'UNKNOWN'` and the parser never infers it from
observed data. Observed boundaries are recorded but explicitly do not imply
coverage:

| File | Observed window |
|---|---|
| July | 2026-06-30T21:00:28Z … 2026-07-31T20:58:30Z |
| May | 2026-04-30T21:03:38Z … 2026-05-31T20:57:40Z |

---

## 3. `ct_password`

Dropped at parse time. It is not in the schema, not in a view, not hashed, not
in metadata, and **not even named** in the import report — `mapHeaders` returns
a count, so the column name itself never travels into JSON. `password`,
`ctpassword` and `ct_pass` are refused the same way.

Two independent checks: a test asserts neither the value nor the string
`ct_password` appears anywhere in the serialized parse output, and a SQL check
greps `information_schema.columns` for any password-like column in the schema.

The real run reports `secret columns dropped: 1` for `users all.xlsx` and `0`
for both activation files.

---

## 4. Headers

An explicit alias map, no fuzzy matching. The corrupted May headers are all
present and confirmed by the real run:

```
irstname → firstname    lastnam → lastname
proile_name → profile_name    manager_irstname → manager_firstname
group → group_name      (May writes `group`, the users file `group_name`)
```

Fuzzy matching is deliberately refused: `proile_name` and `profile_name` differ
by one dropped letter, so a permissive matcher would bind the wrong column with
exactly the same confidence. An unrecognised header is ignored, never guessed.

Two separate contracts, because one would misjudge both files — the users
workbook has no `activations_count` and no `parent`:

- `ACTIVATION_EVENTS`: `id, username, created_at, activations_count, parent`
- `USERS_SNAPSHOT`: `id, username, profile_name, parent`

Both pivots in July and both zone pivots in May were rejected by contract, not
by sheet name.

---

## 5. Topology

Parsed from `lastname` plus any adjacent `__EMPTY*` spread columns. A part that
is absent stays null; text that does not match the shape stays raw and unparsed.

| File | Parsed |
|---|---|
| `users all.xlsx` | 29,490 with FDT; 29,288 with all three parts |
| July | 29,282 of 29,289 events |
| May | **0** |

May's zero is correct, not a parser gap: the file's `lastnam` column carries no
topology at all. Verified by scanning every column of the sheet for `FDT`/`FAT`/
`PORT` — the only hit was one coincidental `transaction_id`. Recorded here so the
gap is not later mistaken for a bug.

---

## 6. Matching

Deterministic only, in order: explicit link → SaaS user id → exact username →
manual review. Never fuzzy, and never by personal name — names repeat, and a
wrong link here assigns money to the wrong agent.

One username resolving to two subscribers returns `CONFLICT`, not a best guess.
`MATCHED` without a recorded method is refused by CHECK constraint.

---

## 7. New/Existing

`NEW` is a strong claim — it asserts a subscriber never existed, and money is
built on it. So it is gated: it requires `source_completeness = 'COMPLETE'`
**and** the reason code that means a complete lifetime history was observed. The
constraint enforces both in the database, so no code path can write a `NEW` the
rule would not allow.

Order of decision:

1. already in the registry → `EXISTING` (`REGISTRY_PREEXISTING`)
2. identity conflict → `NEEDS_REVIEW`
3. `activations_count` > observed events → `EXISTING`
   (`LIFETIME_COUNT_EXCEEDS_OBSERVED`) — valid even from an incomplete source,
   because the excess is positive evidence of history outside the file
4. no qualifying paid event → `NEEDS_REVIEW`
5. complete source and lifetime == observed → `NEW`
6. otherwise → `NEEDS_REVIEW`

Run against both real activation files merged (57,522 unique events, 27,857
distinct subscribers):

```
EXISTING      26,736   LIFETIME_COUNT_EXCEEDS_OBSERVED
NEEDS_REVIEW   1,121   UNKNOWN_SOURCE_COMPLETENESS 1,093
                       NO_QUALIFYING_PAID_EVENT       28
NEW                0
```

Zero `NEW` from sources whose completeness is unknown. That is the guard working
on real data, not a synthetic fixture.

---

## 8. Master bootstrap

`bootstrap_master_data_from_settings()` seeds from the existing `raw_import`
configuration — the reference the system already uses — so the master tables
agree with production behaviour rather than a re-typed list. It is idempotent;
the SQL suite asserts two consecutive runs return an identical result.

From the real configuration: **11 agents · 42 aliases · 24 FDTs · 5 packages**.
The 42 aliases are the 40 configured accounts plus both direct-company spellings
(`FTTH_Users` in July, `TTH_Users` in May), which resolve to `direct_company`
with no agent.

Execute is granted to no application role — it is a deployment operation.

---

## 9. Personal data

`phone` and `national_id` are stored on snapshots for authorized review but are
not exposed through `saas_user_current`, the view intended for broad reads.
`gps_lat`/`gps_lng`, `mac`, `address`, `street` and `email` are parsed by the
alias map but are **not** persisted by this migration — no demonstrated need
yet, and the cheapest data to protect is data not held.

---

## 10. Not built here

- No UI. The tables are readable; no screen consumes them yet.
- No production ingestion. Deployment installs structure and master data only.
- No attribution write path — `subscriber_attribution_history` exists and is
  constrained, but the RPC that writes it belongs with the screen that uses it.
- Completeness is never set to `COMPLETE` by any current code path. Until a
  source declares its coverage, `NEW` remains unreachable by design.
