# Permission and Scope Model

---

## 1. Current state

**FACT.** Authorization is a hardcoded 4×6 matrix, defined **twice**:

```js
// index.html:403
const ROLE_PERMISSIONS={
 admin:      {edit:true,  payment:true,  rates:true,  users:true,  delete:true,  backup:true},
 accountant: {edit:false, payment:true,  rates:false, users:false, delete:false, backup:false},
 monitor:    {edit:false, payment:false, rates:false, users:false, delete:false, backup:false},
 viewer:     {edit:false, payment:false, rates:false, users:false, delete:false, backup:false}
};
```

```sql
-- 20260804170000_reconstructed_baseline.sql:27
constraint profiles_role_check check (role = any (array['admin','accountant','monitor','viewer']))
```

**FACT.** Server-side enforcement exists and is real: every financial RPC calls
`current_app_role()` and refuses a non-admin — verified on production, where a non-admin
attempting `import_installation_history` was rejected. RLS policies additionally gate table
reads, and `authenticated` holds `SELECT` only on the six installation tables.

**FACT.** The UI gate `roleAllows()` is presentation only; it is not the security boundary.
That is the correct arrangement and must be preserved.

### Limitations

1. **Adding a capability requires a code deployment** — the matrix is a JS literal.
2. **Adding a role requires a migration** — the CHECK constraint enumerates four values.
3. **No per-user override.** An accountant who should exceptionally be allowed to correct
   agent attribution cannot be granted it; the only path is promotion to admin, which grants
   everything including user management.
4. **Capabilities are too coarse.** `payment` covers both invoice audit and disbursement.
   `edit` covers commission rows and installation import alike.
5. **No scoping.** Every permitted user sees every agent, FDT and zone.
6. **Permission changes are barely audited.** Role changes go through the atomic RPC, but
   there is no capability-level audit because there are no capabilities.

---

## 2. Target model

**RECOMMENDATION.** Roles become *templates*; authorization is decided by capabilities.

```
effective_capabilities(user) =
      capabilities of the user's role template
    + explicit user grants
    − explicit user revocations
```

An explicit revocation beats a template grant, so a capability can be withdrawn from one
person without inventing a new role.

### 2.1 Capability catalogue

Named per domain, verb last:

```
subscriber.view            subscriber.edit           subscriber.transfer
subscriber.correct_agent   subscriber.change_fdt

installation.view          installation.import       installation.hold
installation.release_hold  installation.raise_entitlement

invoice.view               invoice.verify            invoice.approve       invoice.reject

payment.prepare            payment.execute           payment.reverse

commission.view            commission.edit           commission.publish

cycle.close                cycle.reopen

agent.manage               package.manage            scheme.publish

report.export              audit.view

user.manage                permission.manage
```

**Deliberate separations:** `invoice.approve` ≠ `payment.execute` (the person who verifies
an invoice should not necessarily release the money); `payment.execute` ≠ `payment.reverse`;
`user.manage` ≠ `permission.manage`.

### 2.2 Role templates

| Template | Shape |
|---|---|
| Administrator | everything |
| Finance | invoice.*, payment.*, installation.view, commission.view, report.export |
| Operations | subscriber.*, installation.* except raise_entitlement, report.export |
| Auditor | *.view, audit.view, report.export |
| Management | *.view, report.export, audit.view |
| Read Only | *.view |

Migration of existing users: `admin → Administrator`, `accountant → Finance`,
`monitor → Management`, `viewer → Read Only`. Behaviour is preserved on day one.

### 2.3 Scopes

**RECOMMENDATION.** Model the table now; enforce incrementally.

```
permission_scopes(user_id, scope_type ∈ {all, agent, fdt, zone}, scope_id)
```

Absence of any row means `all` — so existing users are unaffected until a scope is
deliberately added. The important thing is that the *model* allows scoping later; retrofitting
scope into a boolean matrix is what becomes impossible.

### 2.4 Enforcement

**RECOMMENDATION.** One SQL function, used everywhere:

```sql
public.has_capability(p_capability text, p_scope_type text default null, p_scope_id uuid default null)
  returns boolean
  language sql stable security definer set search_path = ''
```

Every financial RPC replaces its `current_app_role() <> 'admin'` check with
`has_capability('payment.execute')`. RLS policies call the same function. The browser calls
a read-only `my_capabilities()` purely to decide which buttons to draw.

**The UI must never be the enforcement point.** That principle already holds today and must
survive the change.

---

## 2.5 Explainability — **APPROVED REQUIREMENT**

An effective permission must always be able to say **why** it is what it is. "Denied" with no
reason is an administration and audit failure: nobody can tell whether it was intended.

Every capability resolves to a verdict **and its source**:

| Capability | Effective | Source |
|---|---|---|
| `payment.execute` | Granted | Finance role template |
| `subscriber.correct_agent` | Granted | Explicit user grant — *"cycle cover, approved 2026-08-16"* |
| `payment.reverse` | Denied | Explicit user denial — overrides the Finance template |
| `cycle.close` | Denied | Not in any template, no grant |

Resolution order, and the answer records which rule won:

```
1. explicit user denial     → Denied  (wins over everything)
2. explicit user grant      → Granted
3. role template            → Granted
4. otherwise                → Denied ("not granted")
```

**RECOMMENDATION.** A function `explain_capability(user_id, capability)` returning
`{effective, source, source_id, reason, granted_by, granted_at}`, surfaced on the user
administration screen next to every capability. The same function answers the auditor's
question — "who could have done this on that date" — without reconstructing it by hand.

Scopes are explained the same way: a capability may be *granted but scoped*, and the screen
must say so rather than showing a bare "Granted" that silently applies to two agents.

---

## 3. Permission audit

**RECOMMENDATION.** Every grant or revocation writes an audit row: actor, target user,
capability, before, after, scope, reason, timestamp.

**Safety rule.** The system must refuse to remove the last `permission.manage` holder — a
constraint or trigger, not a UI check, or the product can be locked out of its own
administration.

---

## 4. Migration order

1. Create `capabilities`, `role_templates`, `role_template_caps` and seed them.
2. Add `has_capability()`; implement it as a shim over the current four roles so behaviour
   is identical.
3. Switch RPCs and RLS to `has_capability()` one at a time, each with a test.
4. Add `user_permission_grants` and let overrides take effect.
5. Add `permission_scopes`, unenforced.
6. Enforce scope in reads, then in writes.

Steps 1–3 are behaviour-preserving refactors and can ship before any product decision about
who should hold what.
