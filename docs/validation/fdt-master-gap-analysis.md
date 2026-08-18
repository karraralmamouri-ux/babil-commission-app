# FDT Master Gap Analysis

Measured against real Production data on 2026-08-18.
**This gap changes money. It is the top blocker for cycle accuracy.**

---

## 1. The gap

| | |
|---|---|
| Cabinets registered in master | **24** |
| Distinct cabinet codes observed in raw events | **143** |
| **Unregistered** | **119** |
| Events on registered cabinets | 6,558 |
| **Events on unregistered cabinets** | **22,724** |
| Events with no cabinet at all | 28,240 |

The registered 24 are exactly `94 … 117` — the `cabinetRanges` from the legacy
`app_settings.raw_import` configuration. The master has never held anything else.

---

## 2. Why it changes money

Zone determines tier scope:

- **OLD ZONE** → tier from **unique subscribers per agent**
- **NEW ZONE** → tier from **unique subscribers per cabinet**

An agent pools thousands of subscribers; a cabinet holds tens or hundreds. The
same event therefore lands in a **different tier band**, at a different rate per
package, depending on which zone it is assigned.

The engine derives zone from the FDT master:

```
case when f.zone = 'new' then 'new' else 'old' end
```

An unregistered cabinet produces `f.zone = NULL`, which falls through to
**`'old'`** — silently. No exception is raised. Missing master data quietly
changes the tier basis.

---

## 3. Financial exposure — July 2026

Of 7,520 commissionable July events:

| | Events | Treatment |
|---|---|---|
| On registered cabinet | 4,541 | NEW ZONE — correct |
| **On unregistered cabinet** | **2,977** | **silently OLD ZONE** |
| No cabinet at all | 2 | OLD ZONE — legitimate |

**15,116,500 IQD of the 37,059,000 projected total — 40.8% — is attributed
through this silent fallback**, across **92 distinct unregistered cabinets**.

Note what this means for the earlier July report: the "old zone" line
(2,979 events / 15,127,250 IQD) is almost entirely the fallback, not genuine
old-zone business. Only 2 events are truly cabinet-less.

### Largest exposures

| Cabinet | Events | Subscribers | Commission | Distinct parents |
|---|---|---|---|---|
| 27 | 238 | 236 | 1,150,000 | 6 |
| 22 | 152 | 146 | 926,750 | 3 |
| 20 | 119 | 118 | 673,500 | 7 |
| 19 | 117 | 116 | 661,500 | 5 |
| 12 | 110 | 110 | 602,000 | 5 |
| 11 | 109 | 105 | 555,750 | 8 |
| 75 | 83 | 80 | 498,750 | 4 |
| 21 | 87 | 87 | 479,000 | 8 |
| 77 | 113 | 110 | 469,000 | 5 |
| 10 | 96 | 95 | 468,250 | 4 |
| 87 | 101 | 96 | 423,750 | 2 |
| 16 | 82 | 82 | 418,500 | 5 |

---

## 4. What the evidence does and does not prove

**Proven:** the master covers only 94–117, and 119 observed codes sit outside it.

**Inferred, not proven:** because the legacy configuration defined the new-zone
cabinet range as 94–117, codes outside it are *plausibly* old-zone cabinets — in
which case the current fallback happens to produce the right answer.

**That inference must not be acted on.** It rests on a legacy import
configuration, not on a cabinet registry. If even a handful of codes in the
10–27 or 75–87 range are new-zone cabinets added after that configuration was
written, their commission is being computed at agent scope and is wrong.

Codes 75, 77 and 87 sit between the low band and the registered band, which is
exactly where an inference from "the old range was 94–117" is least reliable.

---

## 5. Decision required

| Question | Status |
|---|---|
| Are codes outside 94–117 old-zone cabinets? | **BUSINESS_CONFIRMATION_REQUIRED** |
| Is the registered 94–117 range still current and complete? | **BUSINESS_CONFIRMATION_REQUIRED** |
| Are 75 / 77 / 87 old or new zone? | **BUSINESS_CONFIRMATION_REQUIRED** |

The cheapest resolution is a cabinet register from the network side: code → zone,
optionally code → owning agent. 119 codes need a zone.

Until then, **no commission cycle should be finalized**, because 40.8% of the
July projection depends on an unconfirmed zone assignment.

---

## 6. Engine hardening — required, not yet done

The engine must stop treating an unregistered cabinet as old zone. The correct
behaviour is a **blocking review exception** so that missing master data halts a
cycle instead of quietly re-pricing it.

This change was **not** made in this pass: applying it now would move 2,977 July
events into a blocked state and invalidate the 37,059,000 projection before the
zone question is answered. Fixing the engine and answering the business question
belong in the same change, so the corrected figure can be produced once rather
than twice.

**Status: BLOCKING — engine hardening plus cabinet register, together.**
