# index.html exit plan

**Target:** remove application logic from `index.html` without a rewrite and
without a day where the app is not deployable.

**Today:** 265 KB · 3,133 lines · 223 KB inline script · 306 functions · 36
module-level globals.

---

## 1. The real constraint

Not the file size — the tests.

| Coupling | Files | Survives a code move? |
|---|---|---|
| VM sandbox via `loadCurrentApp()` | 12 | **Yes** — one line in `load-current-app.js` |
| Raw `readFileSync('index.html')` + regex | 13 | **No** — assertions name strings that will move |

`load-current-app.js` extracts `<script>` blocks from `index.html` and evals them
in a sandbox. Point it at the moved file and twelve files keep protecting the
legacy code throughout the migration. That is the safety net; it must be
preserved deliberately, not incidentally.

The thirteen text-coupled files are the actual work. Each names markup or script
strings that move. They are updated per phase, alongside the code they guard —
never in a batch, and never by weakening the assertion.

---

## 2. Code inventory

| Category | Approx. share | Destination | Timing |
|---|---|---|---|
| Auth and session | 8 % | `app/session.ts` | Phase A |
| Shell, nav, cycle header | 7 % | `app/shell.ts` | Phase A |
| Formatting, escaping, helpers | 4 % | `domain/`, `utils/` | Phase A |
| Commission vNext UI | 14 % | `features/commissions/` | Phase B |
| Reports UI | 11 % | `features/reports/` | Phase F |
| Operations panels | 13 % | `features/installation/`, `finance/` | C, D |
| Installation UI | 15 % | `features/installation/` | Phase C |
| Import UI | 6 % | `features/imports/` | Phase F |
| User administration | 6 % | `features/system/` | Phase E |
| Archive and comparison | 5 % | `features/*/archive` | Phase E |
| **Legacy month workflow** | 11 % | stays in `legacy/` | Phase G |

---

## 3. Migration order

### Step 0 — move, do not change

Cut the inline `<script>` verbatim into `legacy/app.js`; `index.html` loads it
with `<script src>`. Update `load-current-app.js` to read it.

Zero behaviour change. Diff is one deletion and one addition. This is the step
that makes every later step reviewable, because from here a diff shows logic
changes instead of a moved 223 KB blob.

### Step 1 — build without migrating

Introduce Vite. Entry mounts the shell and router; the legacy script loads
alongside as a side-effect import. Every route renders legacy behaviour.
Deployment changes; the application does not.

### Step 2..n — one screen at a time

For each screen: build it in `features/`, route to it, delete the legacy panel
and its handlers, update the tests that named them.

**Invariants:** the app deploys after every step; no step touches a financial
rule; no step deletes a legacy path still reachable from the menu; the 380 tests
stay green, changed only where the code they name has moved.

### Final step — empty the legacy file

When `legacy/app.js` holds only the legacy month workflow, either delete it or
keep it behind an explicit read-only route.

---

## 4. Legacy compatibility

Old months live in `commission_months` / `commission_rows` (2 and 82 rows). They
predate vNext and are read by the legacy month workflow.

| Feature | Disposition | Removable when |
|---|---|---|
| Legacy month read | **keep** | every historical month is represented as a vNext cycle |
| Legacy month edit / publish | **wrap read-only** | after the first vNext-only close |
| `publish_commission_month` RPC | **keep server-side** | as above; removal is a migration, not a cleanup |
| Central preview mode | **keep** | superseded by the cycle workspace |
| Archive modal | **replace** | `/commissions/archive` ships |
| Month comparison | **replace** | reports workspace ships |
| Excel export | **keep** | it is a business deliverable, not legacy |

Nothing here is deleted during early productization. The condition for removal is
stated per row so the decision is evidence-based later, not a judgement call
under time pressure.

---

## 5. What must not happen

- No big-bang rewrite.
- No step that leaves the app undeployable.
- No deletion of a legacy path while the menu still reaches it.
- No test weakened to make a migration step pass. If an assertion blocks a move,
  the assertion is re-pointed at the new location with its strength intact — the
  same rule already applied when the mobile-breakpoint assertion followed the CSS
  out of `index.html`.
