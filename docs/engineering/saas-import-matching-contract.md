# SaaS Import and Matching Contract

---

## 1. How import works today

**FACT.** Two unrelated import paths exist.

### 1.1 Commission raw activation import

`index.html` `calculateRawImport(rows, config)` — runs **in the browser**.

```
xlsx → rows
  ├─ profile not in config.profiles            → ignoredProfiles++,   dropped
  ├─ id empty                                   → exception,           dropped
  ├─ id already seen in THIS file               → duplicateIds++,      dropped
  ├─ FDT in a cabinetRange                      → NEW ZONE bucket keyed by FDT
  └─ else parent matches an agent account       → OLD ZONE bucket keyed by account
        └─ parent starts with "r." but unknown  → exception
        └─ otherwise (e.g. FTTH_Users)          → ignoredAccounts++,   dropped
  → bucket.counts[p35|p45|p65]++ and recordBreakdown(...)
```

Only aggregates reach the database. **The raw file is never stored.**

### 1.2 Installation historical import

`assets/js/installation-fees.js` `buildHistoricalPreview` → RPC
`import_installation_history`. Preview in the browser, derivation on the server, idempotent
on `(subscriber_id)` and `(subscriber, stage)`.

**This second path is the better model** and should be the template for SaaS import: client
previews, server derives and decides.

---

## 2. Problems with the current contract

1. **Raw data is not retained.** Nothing can be re-derived, re-matched or audited after the
   fact. A matching-rule improvement cannot be applied to past months.
2. **Silent drops.** `ignoredProfiles`, `ignoredAccounts` and `duplicateIds` are counters on
   a transient object. A subscriber dropped because their parent was `FTTH_Users` leaves no
   trace anywhere.
3. **Within-file deduplication only.** `seenIds` resets per file. Cross-month identity does
   not exist.
4. **Repeat activations are discarded.** The second activation of the same `id` in a month is
   counted as a duplicate and dropped — it earns nothing. **Approved decision D-02 says this
   is wrong**: the event should be paid. Formally incompatible legacy behaviour (**R-05**).
5. **Client-side derivation.** Bucket assignment and tier basis are computed in the browser
   and posted. The server re-checks the tier *given* the basis but never recomputes the basis
   itself.

---

## 3. Target contract

```
upload → import_batch (draft)
       → raw rows stored verbatim, append-only
       → normalize        (aliases, package codes, FDT parsing)
       → classify         (NEW / EXISTING / NEEDS_REVIEW)
       → match            (subscriber registry)
       → preview          (counts, exceptions, deltas)
       → confirm          (server-side; derives everything again)
```

### 3.1 Import batch

```
import_batches
  id, domain, period, file_name, file_checksum, row_count,
  status ('draft'|'previewed'|'confirmed'|'rejected'),
  imported_by, imported_at
  unique (file_checksum, domain, period)
```

**`file_checksum` is what defends against "the same file uploaded under another filename"**
(`risk-and-open-decisions.md` S-17). Note the current installation import already accepts a
`p_file_checksum` parameter but the browser passes `null` — the hook exists and is unused.

### 3.2 Every row is accounted for

**RECOMMENDATION.** Replace silent counters with a disposition per raw row:

```
accepted · ignored_non_qualifying · ignored_direct_company ·
duplicate_in_file · duplicate_across_period · unknown_agent_alias ·
unmatched_subscriber · needs_review
```

The rule: **every raw row ends in exactly one disposition, and every disposition is
reviewable in the UI.** No row disappears into a counter.

### 3.2.1 Deduplication is event-level — APPROVED

**The single most important correction to the current import.**

| Deduplicate by | Purpose | Correct? |
|---|---|---|
| **activation identity** | the same event arriving twice through a re-import | **yes** |
| subscriber identity | the same subscriber activating twice | **no — this is real business** |

`activation_identity` comes from the SaaS activation id, or `transaction_id`, or the safest
composite the export supports (`saas_user_id + activated_at + profile_name`).

Consequences: subscriber A with events X and Y contributes **1** to tier population and
**2** commissionable activations. If X is imported twice, X counts once.

Today's `seenIds` does the opposite — it keys on the subscriber and silently drops Y.

### 3.3 Matching

Identity resolution, in order:

1. `saas_user_id` exact → matched
2. `username` exact (normalized) → matched
3. registry hit on either → **EXISTING** (decisive, per business rules §5)
4. no hit + qualifying activation + supporting signals → **NEW**
5. anything ambiguous → **NEEDS_REVIEW**

**NEEDS_REVIEW never produces an entitlement.**

### 3.4 Field contract

Preserve verbatim in `raw_saas_activation_events`:

`saas_user_id · username · subscriber_name · parent · fdt · fat · port ·
created_at · activated_at · profile_name · old_expiration · new_expiration ·
activations_count · price · total_price · transaction_id · card · card_owner ·
cancellation state`

plus the whole original row as `jsonb`.

**`transaction_id` is not an invoice.** It is a SaaS payment reference. Treating it as an
Odoo invoice id without explicit evidence is forbidden — see
`finance-payment-controls.md` §5.

### 3.5 User-state snapshots — **REQUIRED**

**The SaaS User Master must not be stored as a single mutable current row.** A user's
`enabled` flag and `expiration` change over time. If storage keeps only the latest value,
the state a financial calculation depended on is destroyed the next time the file is synced —
and a closed cycle can no longer be explained, let alone reproduced.

```
raw_saas_user_snapshots
  id, import_batch_id, snapshot_at, source_file_id,
  saas_user_id, username,
  enabled, expiration, parent_name, created_at_saas,
  raw jsonb
  unique (import_batch_id, saas_user_id)
```

**Rules.**

1. Append-only. A sync writes new snapshot rows; it never updates an old one.
2. Every row carries `snapshot_at` and the import/file identifier it came from, so any value
   can be traced to its source.
3. `raw jsonb` keeps every column the export carried, including fields not yet modelled.
4. "Current state" is a view — the latest snapshot per `saas_user_id` — never a stored row
   that gets overwritten.

**Why this is a requirement and not a preference.** Unique-active-user tier calculation
(**D-03**, Phase 8) needs to ask *"was this user active on the cycle's measurement date"*.
Only an as-of snapshot can answer that. A mutable current row answers a different and useless
question: *"is this user active today"*.

Naming is not prescribed. Any immutable snapshot or event model carrying the same fields
satisfies this. Choose the smallest design that fits the existing schema —
`raw_saas_user_snapshots` alongside `raw_saas_activation_events` is the obvious candidate
because both are already append-only and batch-scoped.

---

## 4. Idempotency

**FACT.** The pattern already exists and works: `request_id` is checked against `audit_logs`
before any write, and replaying returns the original result rather than importing twice
(`import_installation_history`, verified twice on production with zero effect).

**RECOMMENDATION.** Apply the same pattern to SaaS import, plus the checksum uniqueness
above, so a double upload is impossible on two independent grounds.

---

## 5. Backfill

**RECOMMENDATION.** Historical activation files can be loaded into
`raw_saas_activation_events` as `historical` batches without generating entitlements, giving
the matching engine prior history to work with. This is read-only enrichment: it must never
alter the frozen `2026-07-31` financial baseline.
