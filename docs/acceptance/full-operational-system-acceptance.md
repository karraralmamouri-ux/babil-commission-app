# Definition of a Complete Operational System

The criteria BABIL FLOW must meet before it can be called a complete operational
system rather than a dashboard over a financial engine.

**Dashboard polish never satisfies this.** A beautiful home screen with no
subscriber case, no addressable route, and a queue capped at 300 of 22,727 fails
regardless of how it looks.

Every criterion is **testable**. "Feels complete" is not a criterion.

---

## 1. Routes and screens

- [ ] Every menu item resolves to a distinct screen. **Zero aliases** — no two
      labels share a destination.
- [ ] Every screen has a URL that survives refresh.
- [ ] Browser Back and Forward move between screens, never out of the app.
- [ ] Every record has an addressable URL: cycle, subscriber, agent, cabinet,
      batch, user, import.
- [ ] Filters live in the query string; a filtered queue is linkable.
- [ ] Every screen owns loading, empty, error, and no-permission states.
- [ ] Breadcrumbs reflect the route.

**Test:** for each of the 36 routes — deep link cold, refresh, Back, and load
without the capability. Automated.

## 2. Case management

- [ ] Any subscriber is findable by identity, name, agent, or cabinet.
- [ ] The case shows stage, eligibility, invoice, hold, amount due, and payment
      state on one screen.
- [ ] The case answers **why blocked** in words, without an export.
- [ ] The timeline is **derived** from events, ledger and audit — never stored.
- [ ] Agent, cabinet, cycle, batch and user each have an equivalent workspace.

**Test:** pick a real blocked subscriber; a reviewer with no system knowledge
states the reason from the screen alone.

## 3. Workflow continuity

- [ ] The installation lifecycle is visible as a sequence with a current
      position.
- [ ] Every blocked step names what blocks it and links to where it is resolved.
- [ ] Cycle finalization lists its blockers rather than only counting them.
- [ ] Exception → resolution → recalculation is completable without leaving the
      app or asking an engineer.

**Test:** classify a cabinet in a test cycle and follow the loop to a changed
figure, using only the interface.

## 4. Queues and drill-down

- [ ] Every list is server-paged with filters, sort, and a visible total.
- [ ] No list silently truncates. A cap, if any, is stated.
- [ ] Every KPI links to the filtered records behind it, or says why not.
- [ ] Blocked money is reachable in one click from home.

**Test:** reach exception 22,000 of 22,727 through the interface.

## 5. Payments

- [ ] Batch preparation, validation, posting and history each have a screen.
- [ ] Line-level state shows draft, validated, rejected with the server reason.
- [ ] Blocked and unfinalized records cannot be selected.
- [ ] No posting decision is computed client-side.
- [ ] Every posted entry links to its ledger row and audit record.

**Test:** attempt to include a blocked record; the server refuses and the screen
explains.

## 6. Master data and administration

- [ ] Agents, aliases, cabinets, packages and scheme versions each have a screen.
- [ ] Financially relevant configuration is versioned and published, never edited
      in a generic form.
- [ ] An admin can answer **"why can this user do this?"** on screen — role,
      explicit grant, explicit deny, scope, effective decision.
- [ ] Every master-data change is audited with before and after.

**Test:** grant, then deny, and read the explanation from the screen.

## 7. Audit and reports

- [ ] Audit is a first-class screen, filterable by date, actor, entity, action,
      and paged across full history.
- [ ] Audit rows drill to before, after, reason, request id, and ledger entry.
- [ ] All six reports filter, export, and link back to operational records.
- [ ] Report totals equal detail totals equal export totals.

**Test:** trace one financial change from report to audit to ledger without SQL.

## 8. Imports

- [ ] Import centre lists every batch with file, checksum, coverage, rows,
      accepted, duplicates, rejected, status, actor, timestamp.
- [ ] Every import is inspectable after the fact.
- [ ] Completeness is declared explicitly, never inferred.
- [ ] `ct_password` never appears in storage, log, export, or fixture.

## 9. Mobile and accessibility

- [ ] Every screen usable at 375 px; no horizontal page overflow.
- [ ] Wide tables become cards or scroll inside their own container.
- [ ] Keyboard reaches every action; focus is visible.
- [ ] Contrast meets AA on every real pair.
- [ ] Status is never conveyed by colour alone.
- [ ] Touch targets ≥ 44 px.

## 10. Performance

- [ ] Every list screen returns its first page in **under 1 s** on production
      volumes.
- [ ] No screen fetches a full table to display a page.
- [ ] Server-side filtering and paging on every list.
- [ ] The row-level-security evaluation fix is not regressed — the RLS predicate
      is evaluated once per query, never per row.

**Test:** measure the seven paths already benchmarked and compare.

## 11. Financial safety — unchanged from v1.0

- [ ] No financial value computed in the browser.
- [ ] Server enforces every capability; hidden UI is convenience only.
- [ ] Blocked money cannot enter a payment.
- [ ] Posted ledger entries remain immutable.
- [ ] Projected figures never render as final.
- [ ] Historical baseline intact: 5,693 · 17,117 · 54,828,000 IQD.
- [ ] Unknown cabinet never becomes OLD ZONE.
- [ ] Cycle windows remain Baghdad-based regardless of session timezone.

**Any regression here fails acceptance outright**, regardless of product
progress.

## 12. Legacy

- [ ] No application logic in `index.html`.
- [ ] Historical months still readable.
- [ ] Legacy write paths read-only or removed under their stated condition.

---

## Verdict rule

**Complete** requires every §1–§5 and §11 box, and no open P0.

§6–§10 gaps may be accepted as post-launch items **if and only if** they are
written down with an owner and do not touch financial safety.

An open box in §11 is never waivable.
