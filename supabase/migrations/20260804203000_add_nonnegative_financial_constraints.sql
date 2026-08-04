-- Reject negative quantities and payments in both current commission models.

begin;

alter table public.commission_rows
  add constraint commission_rows_quantities_nonnegative
  check (p35 >= 0 and p45 >= 0 and p65 >= 0) not valid,
  add constraint commission_rows_paid_nonnegative
  check (paid >= 0) not valid;

alter table public.commission_agents
  add constraint commission_agents_quantities_nonnegative
  check (p35 >= 0 and p45 >= 0 and p65 >= 0) not valid,
  add constraint commission_agents_paid_nonnegative
  check (paid >= 0) not valid;

alter table public.commission_rows
  validate constraint commission_rows_quantities_nonnegative,
  validate constraint commission_rows_paid_nonnegative;

alter table public.commission_agents
  validate constraint commission_agents_quantities_nonnegative,
  validate constraint commission_agents_paid_nonnegative;

commit;
