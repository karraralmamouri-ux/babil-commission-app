# Frontend Product Architecture — decision and target

**Status:** recommendation for approval. Not implemented.

---

## 1. Constraints, measured

| Fact | Value | Consequence |
|---|---|---|
| Runtime dependencies | **0** | nothing to keep current |
| Build step | **none** | Pages serves the repo as-is; a deploy cannot fail to build |
| `index.html` inline script | 223 KB · 306 functions · 36 globals | one namespace, no boundaries |
| Extracted modules | 82 KB, **0 DOM references**, CommonJS exports | already portable |
| Tests reading `index.html` as text | **13 files** | coupled to markup and script strings |
| Tests using the VM sandbox | **12 files** | survive a file move with a one-line harness change |
| Target screens | ~36, with record-level state | beyond comfortable hand-rolled DOM |
| Deploy | merge to `main` → Pages | build introduces a new failure mode |

---

## 2. Options

### A. Lightweight router over the existing vanilla code

Add a History router; keep rendering by hand; keep `index.html`.

**For:** no build step, no new failure mode, all 380 tests keep running
untouched, smallest possible step.
**Against:** 36 screens of manual `innerHTML` in a single global namespace. The
223 KB file keeps growing. No types on money. Every new screen raises the odds of
a name collision among 36 globals.

### B. Vite + TypeScript, no UI framework

Build to static output; TypeScript modules per screen; a small History router;
plain DOM rendering (template functions), no React/Vue.

**For:** real module boundaries; types on the values this project has repeatedly
got wrong — IQD integers, tier codes, zone enums, projected-vs-final; per-screen
code splitting; the 82 KB of DOM-free logic ports as-is.
**Against:** introduces a build step and a Pages workflow change; the 13
text-coupled tests need rework as code moves.

### C. Vite + React

**Against, decisively:** a component framework earns its weight through complex
client state. This app's state is server-authoritative — screens read reports and
call RPCs. React would add a dependency tree, a hydration model, and a rendering
abstraction to solve a problem the product does not have. Rejected on evidence,
not on taste.

---

## 3. Recommendation

> **Option B — Vite + TypeScript, no UI framework, migrated screen by screen
> behind a strangler.**

Three reasons, in order of weight:

**1. The risky part is already done.** The usual danger in this migration is
porting business logic. Here the domain logic is 82 KB of DOM-free, exported,
test-covered modules. They move by changing `module.exports` to `export`. What
remains in `index.html` is orchestration and DOM — the part being replaced
anyway.

**2. Types belong on this data.** The defects this project actually shipped were
type-shaped: a NULL scheme version silently becoming `0`; a naive timestamp read
in machine time; an inline style out-ranking a media query. A money type that
cannot be `null`, a `Zone = 'old' | 'new' | 'unresolved'`, and a
`Projected<Amount>` that will not render without its marker turn a class of
review-caught bug into a compile error.

**3. Thirty-six screens will not survive one namespace.** Thirty-six screens
sharing 36 globals and one 223 KB file is not a maintainable target, and the
audit shows the strain already: pagination helpers written and never wired,
because nothing made the connection obvious.

### What is explicitly rejected

- No React, Vue, Svelte, or component framework.
- No state library. Server is the state.
- No CSS framework — `babil-flow.css` is the design system and stays.
- No SSR. Static output only.

### Deploy risk and its mitigation

Today a bad commit still serves the previous file; with a build, a bad commit
could serve nothing. Mitigated by: CI builds on every PR and fails the merge;
Pages deploys from a built artifact only after CI passes; `v1.0.0` remains a
tagged, deployable, build-free fallback.

This is a real regression in one property — deploy simplicity — accepted in
exchange for maintainability across 36 screens. It should be stated plainly to
whoever approves this, not buried.

---

## 4. Target structure

```
src/
  main.ts                     entry: session, shell, router
  app/
    router.ts                 History router, guards, breadcrumbs
    shell.ts                  sidebar, header, cycle state
    session.ts                auth, refresh, logout
    capabilities.ts           my_capabilities cache; convenience only
  domain/                     ← the 5 modules, ported verbatim, typed
    money.ts                  IQD integer type + one formatter
    cycle.ts                  stages, projected/final
    commission.ts             ← commission-vnext.js
    installation.ts           ← installation-fees.js
    saas-import.ts            ← saas-import.js
    reporting.ts              ← reporting.js
    operations.ts             ← operations.js
  services/
    supabase.ts               single request path, retry, error mapping
    reports.ts                the six reports, typed
    rpc.ts                    typed RPC wrappers
  features/
    home/  commissions/  installation/  agents/  fdt/
    finance/  exceptions/  imports/  reports/  master/  system/
      <screen>/index.ts       route entry
      <screen>/view.ts        render
      <screen>/data.ts        fetch
  components/
    table/ filters/ states/ money/ chips/ drawer/ breadcrumbs/
  legacy/
    app.ts                    the current inline script, moved verbatim
```

`domain/` holds no DOM and no network. `services/` holds no DOM. `features/` may
use both. Enforced by a lint rule, not by intention.

---

## 5. Routing contract

- History API. No hash routing — the app already uses the hash for Supabase
  recovery tokens, and `detectRecoveryRedirect()` must keep working untouched.
- Pages needs a 404 fallback to `index.html` for deep links (Pages serves `404.html`;
  a copy of the shell there resolves it).
- Guards check capability before render and show the no-permission state instead
  of redirecting — a redirect hides the fact that the screen exists.
- Route params are the entity ids already used by the API (`cycleId`,
  `subscriberId`, `agentId`, `batchId`).
- Filters live in the query string so a filtered queue is linkable.
