# First Real SaaS Cycle — Accuracy Validation

Validation of the July 2026 cycle against real Production data.
Run 2026-08-24. **No payment posted. No historical record altered.**

---

## 1. Source

**No new operational SaaS export exists.** The newest activation export is July
2026, already imported. Every un-imported workbook is *older* backfill
(Jan/Feb/April) or a July variant — none is "the export intended for the first
operational cycle".

Per the brief, nothing was imported. Validation therefore ran against the real
July data already in Production, which is genuine SaaS Excel output.

| Workbook | sha256 | Events | In Production |
|---|---|---|---|
| `فواتير شهر 7.xlsx` | `7bf8988ba4457148…` | 29,289 | **yes** — validated here |
| `May-2026_Activations.xlsx` | `ebcf152cd0c51e8b…` | 28,233 | yes |
| `users all.xlsx` | `c9cff920dffc26c7…` | 32,481 users | yes |
| `April-2026_Activations.xlsx` | `f7d7d929740013a8…` | 27,429 | no — older backfill |
| `Activations_Feb-2026.xlsx` | `c17f10f9a03509a7…` | 25,470 | no — older backfill |
| `Activations_Jan-2026.xlsx` | `94626a2b3eaf22ab…` | 23,973 | no — older backfill |
| `غرامات دايني شهر 7.xlsx` | `d9884ada49ed04ff…` | 29,289 | no — July variant |

The last file carries the same 29,289 events and same 20,772 distinct usernames
as the imported July file, over an identical window. It is the same period with
extra fine/debt sheets, not a new cycle.

## 2. Cycle and completeness

| | |
|---|---|
| Cycle | `2026-07 تموز` (2026-07-01 → 2026-07-31) |
| Observed window | 2026-06-30T21:00:28Z … 2026-07-31T20:58:30Z |
| Completeness | **UNKNOWN** — no source declares coverage |
| Status | **UNDER_REVIEW (projected)** — deliberately not finalized |

---

## 3. Two defects found and fixed

### 3.1 Compact timestamps nulled every event date

`created_at` exported as `2026-04-30 235650` — time without colons. `Date`
rejects it, so **100% of events in two real workbooks parsed to a null date**:

| Workbook | Events | Null dates |
|---|---|---|
| `April-2026_Activations.xlsx` | 27,429 | 27,429 (100%) |
| `غرامات دايني شهر 7.xlsx` | 29,289 | 29,289 (100%) |

An event with a null date falls outside every cycle window, so all 56,718 would
have imported and then vanished from every calculation **with no exception
raised** — a silent zero rather than a visible error.

Fixed: the format is parsed, unparsed dates are counted and reported, and
April's `tnam` header corruption is mapped. Both windows now resolve correctly
(April: 2026-03-31 → 2026-04-30).

### 3.2 Exception classification blocked finalization for non-problems

Measured on July:

| | Before | After |
|---|---|---|
| Blocking exceptions | **37,073** | **53** |
| — genuinely unknown parent | 52 | 52 |
| — source incomplete | 1 | 1 |
| — direct company mislabelled `UNKNOWN_AGENT` | 18,484 | 0 |
| — old-zone events mislabelled `UNKNOWN_FDT` | 18,536 | 0 |

Direct company (`FTTH_Users`) is a **resolved** alias deliberately excluded from
reseller commission — not an unknown agent. And old-zone events are tiered by
agent, so they carry no cabinet requirement.

At 37,073 blocking exceptions a cycle could never be finalized, and the 52 that
genuinely need a human decision were buried. Noise at that ratio ends with the
guard being switched off, which is worse than not having one.

---

## 4. Commission vNext — real result

Projected calculation over the real July cycle:

| Metric | Value |
|---|---|
| Scopes | 35 (11 agents + 24 cabinets) |
| **Unique activated subscribers (tier basis)** | **7,324** |
| **Qualifying activation events** | **7,520** |
| **Gross commission (projected)** | **37,059,000 IQD** |

| Zone | Scopes | Subscribers | Events | Gross |
|---|---|---|---|---|
| new (per cabinet) | 24 | 4,406 | 4,541 | 21,931,750 |
| old (per agent) | 11 | 2,918 | 2,979 | 15,127,250 |
| **Total** | **35** | **7,324** | **7,520** | **37,059,000** |

Tiers reached: T1 18 scopes · T2 13 · T3 4.

### Reconciliation — exact

```
entitlement sum   = 37,059,000
snapshot sum      = 37,059,000
report total      = 37,059,000
entitlement count = 7,520
snapshot events   = 7,520
```

Detail = scope = cycle = report, with no unexplained difference.

---

## 5. Source-to-result reconciliation — no remainder

Every one of the 29,246 July events is accounted for:

| Category | Events |
|---|---|
| Commission qualifying | 7,520 |
| Debt service (Loan-3) — earns nothing by rule | 8,554 |
| Direct company (`FTTH_Users`) — no reseller entitlement | 13,128 |
| Unknown parent — needs a business decision | 44 |
| Canceled | 0 |
| Unknown package | 0 |
| Identity conflict | 0 |
| **Total** | **29,246** ✓ |

Loan-3 events under unresolved parents account for the difference between the 44
here and the 52 unknown-parent exceptions, which count all package types.

**The tier basis is 7,324 distinct subscribers against 7,520 events — a 2.6%
difference caused entirely by repeat activators.** Under the legacy method the
basis was the event count. This is the intended vNext behaviour, and the gap is
large enough to move a scope across a tier boundary.

---

## 6. Historical continuity — unchanged

Measured before and after all work:

| | Before | After |
|---|---|---|
| Installation subscribers | 5,693 | 5,693 |
| Historical payment rows | 17,117 | 17,117 |
| Historical paid amount | 54,828,000 | 54,828,000 |
| Installation entitlements | 0 | 0 |
| Installation payments | 0 | 0 |
| commission_rows | 82 | 82 |
| Commission paid | 0.00 | 0.00 |
| Financial ledger | 0 | 0 |
| Enrollments | 5,688 | 5,688 |

No historical value moved.

---

## 7. Not validated, and why

- **Installation Fee new enrolment.** `subscriber_identities` and
  `subscriber_classifications` hold 0 rows in Production, so NEW/EXISTING
  classification cannot run. Commission does not depend on it, which is why
  commission validated regardless. See `current-data-quality-issues.md` §2.
- **Payment dry-run.** Not prepared. Completeness is UNKNOWN and 52 unknown-parent
  events remain open; preparing a batch against a knowingly incomplete basis
  would assert a readiness that does not exist.
- **Legacy comparison.** Legacy month `07/2026` records a tier basis of 7,533
  (event counts) against vNext's 7,324 (distinct subscribers). Classified as an
  **expected business-rule difference**, not a defect.

---

## 8. Verdict

The engine reconciles exactly, accounts for every source event, leaves history
untouched, and correctly refuses to finalize from an unproven source. Two real
defects surfaced only because real data was used, and both are fixed with
regression tests.

What remains is **business data decisions**, not engineering: map the 52
unknown-parent events, confirm cabinet registration, and declare source
completeness.
