# Manual Exception Intake — إضافة مشترك استثنائي

**Status: DESIGN ONLY.** Written as part of the PR #89 D-12 first-operation fix
(2026-08-26), for a separate PR-B. No backend or UI code from this document has
been implemented in PR #89. Nothing here creates a capability, table, or route.

## Purpose

Some real subscribers cannot enter through the normal SaaS intake path at all —
never appeared in a SaaS export, missing from historical data, or known only
through an administrative exception. Today there is no way to register such a
subscriber without either (a) fabricating SaaS evidence that does not exist, or
(b) leaving them permanently invisible to every report in this system. This
feature is the single, audited front door for that situation — nothing else.

## Non-goals — read this before designing the schema or the UI

This is an **intake and review** feature, not a back door to eligibility. It
must be impossible, by construction, for a manually-entered record to reach
financial eligibility without a human deciding so explicitly, every time.

- MUST NOT automatically become `NEW`.
- MUST NOT automatically create an installation entitlement or payment.
- MUST NOT bypass `classify_newness()`, D-12, or any other approved rule.

## Safety model

- **Capability-restricted.** A new, dedicated capability (e.g.
  `installation.manual_exception_create`), not bundled into an existing broad
  role by default — this is a rare, sensitive action, not a routine one.
- **Mandatory exception type** (see below) — no free-form "other" without a
  reason.
- **Mandatory free-text reason**, non-empty, same convention as
  `grace_period_overrides.reason` / `override_grace_expired_review()`.
- **Actor / time / request_id audit** — every create, correction, and removal
  writes to `audit_logs` with `request_id` for replay-safety, matching the
  existing pattern in `override_grace_expired_review()`.
- **Explicit confirmation** — a distinct, deliberate UI step; not a side
  effect of any other form submission.
- **Lands as `MANUAL_EXCEPTION` / `NEEDS_REVIEW`**, never `NEW`. It enters the
  exact same `subscriber_classifications` review surface every other
  `NEEDS_REVIEW` row uses (`action_center()`'s `CLASSIFICATION_REVIEW` group),
  so it gets no special, less-scrutinized path to approval.
- **Reviewable/approvable separately** — promotion out of `NEEDS_REVIEW`
  still goes through the existing classification-review workflow; this
  feature only creates the row, it never classifies it `NEW` itself.
- **Later real-identity detection** — if a genuine SaaS identity later
  appears for the same person (matched by username/national_id/etc. through
  the existing `subscriber_identities` matching path), the manual record must
  be linkable/mergeable to it rather than left as a silent duplicate. Exact
  merge mechanics are for PR-B's own design pass; this document only requires
  that detection and linking be possible, not automatic promotion.
- **Duplicate-safe** — creating a second manual exception for a subscriber
  who already has one (matched by the same identifying fields) must be
  blocked or flagged at intake time, not discovered later as two competing
  financial rows.
- **Corrections preserve history** — any correction or removal is an
  append-only audit event (matching `audit_logs`'s existing old/new-value
  convention), never a hard delete of the original manual-entry record.

## Suggested exception types

A closed enum, not free text, so reporting can group by reason:

- `NOT_VISIBLE_IN_SAAS` — subscriber genuinely not present in any SaaS export.
- `MISSING_HISTORICAL_DATA` — known subscriber, historical registry data
  incomplete or never migrated.
- `IMPORT_SOURCE_ERROR` — a data quality/mapping failure in a prior import,
  confirmed by an operator.
- `APPROVED_ADMINISTRATIVE_EXCEPTION` — a specific, named administrative
  decision (the mandatory free-text reason should reference it).
- `OTHER` — requires the free-text reason to carry the actual justification;
  should be the least-used bucket, worth watching in reporting if it grows.

## Minimum backend contract (for PR-B)

- One new table, e.g. `manual_exception_intakes` (or extend
  `subscriber_identities`/`subscriber_classifications` with a provenance
  column — PR-B's call, not decided here), carrying: exception type, free-text
  reason, actor, timestamp, request_id, and whatever identifying fields let
  later duplicate/real-identity detection work (at minimum: username/name,
  optionally national_id, phone, or whatever the manual process already
  collects).
- One `security definer` RPC, e.g. `create_manual_exception_intake(...)`,
  following the existing convention: `require_capability(...)` gate,
  `request_id` replay-safety check against `audit_logs` (or a dedicated
  table, matching `override_grace_expired_review()`'s pattern), writes the
  row as `NEEDS_REVIEW`/`MANUAL_EXCEPTION`, writes the audit event, returns
  the created record.
- No changes to `classify_newness()`, `installation_grace_status()`, or any
  entitlement-creation path — a manual exception is purely a new row-creation
  entry point into the *existing* review surface.

## Suggested UI location (for PR-B)

A dedicated action from the Employees or Installation area (e.g.
`/installation/manual-exception/new`), not a field bolted onto the normal
SaaS-import flow — it must read as a deliberately separate, rarer path, not a
convenience shortcut next to the normal intake.

## Explicitly deferred

D-10 and D-11 are out of scope for both PR #89 and this design note.
