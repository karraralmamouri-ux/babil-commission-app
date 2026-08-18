# SaaS Source Workbooks — Empirical Findings

Measured directly from the three real workbooks on 2026-08-18, read-only. No file
was modified and none is committed. Every number below is counted from source,
not remembered or estimated.

This replaces assumption with evidence in `saas-import-matching-contract.md`.
Several questions that document had to leave open are now settled.

---

## 1. The three sources

| Workbook | Bytes | sha256 (16) | Sheets |
|---|---|---|---|
| `users all.xlsx` | 4,022,830 | `c9cff920dffc26c7…` | 1 |
| `فواتير شهر 7.xlsx` (July) | 8,349,988 | `7bf8988ba4457148…` | 2 |
| `May-2026_Activations.xlsx` | 7,080,352 | `ebcf152cd0c51e8b…` | 5 |

---

## 2. Users snapshot — `users all.xlsx`

One sheet, **32,481 rows**, 26 columns.

```
id | username | firstname | lastname | city | phone | balance | expiration | email
static_ip | enabled | notes | profile_name | mac | parent_name | ct_password
address | contract_id | created_at | national_id | last_online | group_name
company | gps_lat | gps_lng | street
```

- `id` — 32,481 present, **32,481 distinct**. A reliable stable identity.
- `username` — 32,481 present, **32,481 distinct**.
- `enabled` — **1 ×32,454 · 0 ×27**. The D-03 evidence exists and is nearly
  all-true; the activity test still must not be invented from it.
- `profile_name` — `P-35000` ×30,737 · `P-45000` ×1,467 · `P-65000` ×276 ·
  **`Diamond` ×1**. A fourth package exists in the wild.
- `lastname` carries topology for **29,490 of 32,481** rows, shaped
  `FDT:11 FAT:3 PORT:3`.
- `ct_password` is present in the source. **It must not be persisted** — see §7.

**This sheet has no `activations_count` and no `parent`**, so the raw-sheet
contract used for activation workbooks correctly does *not* match it. Users and
activations need separate contracts.

---

## 3. July activations — `فواتير شهر 7.xlsx`

Two sheets, and the contract separates them cleanly:

| Sheet | Rows | Contract `id,username,created_at,activations_count,parent` | Verdict |
|---|---|---|---|
| `Sheet1` | 43 | ✗ ✗ ✗ ✗ ✗ — headers `Row Labels \| Count of id` | **pivot, reject** |
| `Worksheet` | 29,289 | ✓ ✓ ✓ ✓ ✓ | **raw, import** |

From the raw sheet:

- **29,289 events · 29,289 distinct `id` · 20,772 distinct `username`.**
  8,517 events belong to a subscriber who already appears. **This is the
  empirical proof that deduplication must key on the event, never the
  subscriber** — collapsing by username would silently discard 29% of events.
- `transaction_id` — 29,289 present, **29,289 distinct**. Usable as a secondary
  reference; `id` remains primary.
- `canceled` — **`No` ×29,289**. No cancelled events in this period, so the
  cancellation path cannot be validated from July alone.
- `activations_count` — min **1**, max **80**.
- `profile_name` — `P-35000` ×19,634 · **`Loan-3` ×8,559** · `P-45000` ×906 ·
  `P-65000` ×190. Loan-3 is 29% of the month's events and must never be counted
  as a paid card activation.
- Topology in `lastname` for 27,384 of 29,289, shaped `FDT:97` — note this file
  often carries FDT only, where the users file carries all three parts.
- Columns `__EMPTY`, `__EMPTY_1` … `__EMPTY_4` appear between `lastname` and
  `manager_firstname` — the spread topology columns the contract warned about.

---

## 4. May activations — `May-2026_Activations.xlsx`

Five sheets:

| Sheet | Rows | Verdict |
|---|---|---|
| `Sheet1` | 1 | raw-shaped, 1 row |
| `Sheet2` | 1 | raw-shaped, 1 row |
| `OLD ZONE` | 29 | **pivot** — `Count of proile_name \| Column Labels \| __EMPTY…` |
| `NEW ZONE` | 17 | **pivot** — `Count of price \| Column Labels \| __EMPTY…` |
| `Worksheet` | 28,233 | **raw, import** |

- **28,233 events · 28,233 distinct `id` · 20,168 distinct `username`.** Same
  pattern as July.
- **The corrupted header variants are real and confirmed:**
  `irstname` · `lastnam` · `proile_name` · `manager_irstname`.
  The alias map must carry these explicitly. Broad fuzzy matching is not needed
  and must not be used — `proile_name` and `profile_name` differ by one dropped
  letter, and a permissive matcher could just as easily bind the wrong column.
- `parent` shows **`TTH_Users` ×18,829** where July shows **`FTTH_Users`
  ×18,513**. Both direct-company spellings are real, in different months, and
  both must normalize to `DIRECT_COMPANY`.
- `Sheet1` and `Sheet2` each hold a single raw-shaped row. They satisfy the
  column contract, so a contract-only rule would import them. Whether they are
  strays or meaningful is **unresolved** — see §8.

---

## 5. Agent aliases — measured, not assumed

Distinct `parent` values: **46** in the users file, **41** in July, **49** in May.

Confirmed alias families and their real sub-account ranges:

- `r.saeed.ammar` plus `.sub1` … `.sub23` — the full 23 confirmed present
- `r.ahmed.abdalabbas` plus `.sub1` … `.sub6`
- singletons: `r.ali.tareq` · `r.ammar.kamil` · `r.ammar.khalil` ·
  `r.bareq.laith` · `r.basim.mohammed.ibrahim` · `r.haider.talib` ·
  `r.karar.abbas` · `r.mustafa.dhiaa` · `r.ziyad.majid`
- direct company: `FTTH_Users` / `TTH_Users`
- at least one non-reseller value observed (`office.1` ×4) that belongs in
  **NEEDS_REVIEW**, not in a silently created agent

The alias set differs between months, which is exactly why aliases must be data
with an unmatched-review path rather than a fixed list.

---

## 6. What this settles

| Question | Evidence |
|---|---|
| Is `id` a stable event identity? | Yes — 100% present and distinct in both activation files |
| Can we dedup by subscriber? | **No** — 8,517 July and 8,065 May events would vanish |
| Are the corrupted headers real? | Yes — `irstname`, `lastnam`, `proile_name`, `manager_irstname` in May |
| Are both direct-company spellings real? | Yes — `FTTH_Users` in July, `TTH_Users` in May |
| Does Loan-3 appear at scale? | Yes — 8,559 events, 29% of July |
| Does the pivot/raw contract work? | Yes — it accepted 2 raw sheets and rejected 3 pivots across the two files |
| Is `enabled` available for D-03? | Present, 32,454 true / 27 false — **evidence only, rule still undecided** |

---

## 7. Security finding

`users all.xlsx` contains a **`ct_password`** column. It must not be written to
any persisted table, exposed through any view, or surfaced in the interface. The
importer should drop it at parse time rather than store-and-hide it — a secret
that is never persisted cannot leak from the database.

`national_id`, `phone`, `email`, `mac`, `gps_lat`/`gps_lng` and `address` are
also personal data and need a deliberate retention decision before ingestion.

---

## 8. Open before ingestion

1. ~~**May `Sheet1` / `Sheet2`**~~ — **resolved by measurement.** Both rows are
   duplicates of rows already inside `Worksheet`. Importing all three sheets and
   deduplicating on the event `id` yields exactly 28,233 unique events: the
   `Worksheet` pass reports `dupes=2`, which are those same two events arriving
   a second time. Nothing is lost and nothing is double-counted, so both feared
   outcomes are avoided by one rule. See
   `data-intelligence-foundation-as-built.md` §2.
2. **`Diamond` package** — one user in the snapshot. Semantic class unknown;
   defaults to `UNKNOWN`, never to a paid package.
3. **`office.1`** and other non-`r.` non-direct-company parents — review, never
   auto-created.
4. **Coverage boundaries** — neither activation file states its period
   explicitly; `created_at` ranges must be measured before a completeness flag
   can honestly be set, and the New/Existing rule depends on that flag.

Items 2–4 are settled by approved default rather than by evidence: `Diamond`
stays `UNKNOWN`, `office.1` goes to review, and completeness stays `UNKNOWN` so
`NEW` is unreachable until a source declares its coverage. Item 1 is settled by
measurement. Schema and ingestion are both unblocked; what remains blocked is
any rule that needs a *complete* source — by design.

One further gap was found while building and is recorded in
`data-intelligence-foundation-as-built.md` §5: **May carries no topology at
all.** Its `lastnam` column holds none, so the parser extracts 0 FDT codes from
28,233 events where July yields 29,282. Confirmed by scanning every column of
the sheet, so the zero is a property of the file, not a parser defect.
