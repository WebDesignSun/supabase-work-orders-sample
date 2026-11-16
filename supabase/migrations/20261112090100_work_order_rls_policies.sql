-- Row level security for the work-order tables.
--
-- Roles are per business unit (public.memberships.role):
--   admin      everything in the unit, incl. memberships and deletes
--   office     sees every work order of the unit, creates, edits and assigns
--   technician sees and updates only the work orders assigned to them, and
--              may change nothing but their status
-- Nobody sees anything of a unit they are not a member of. anon has no access.
--
-- Policy expressions call the helpers below with (select auth.uid()) inside,
-- so auth.uid() is evaluated once per statement, not once per row.

-- ---------------------------------------------------------------------------
-- Role helpers
--
-- security definer: they read public.memberships / work_order_assignees, which
-- are themselves protected by RLS; calling them as the invoker from a policy
-- on those same tables would recurse. search_path = '' and fully qualified
-- names keep them safe from search_path hijacking. They live in the private
-- schema, which PostgREST does not expose, so they cannot be called over HTTP.
-- ---------------------------------------------------------------------------

create function private.has_role(
  p_business_unit_id uuid,
  p_roles public.member_role[]
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.memberships m
    where m.business_unit_id = p_business_unit_id
      and m.user_id = (select auth.uid())
      and m.role = any (p_roles)
  );
$$;

create function private.is_member(p_business_unit_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.memberships m
    where m.business_unit_id = p_business_unit_id
      and m.user_id = (select auth.uid())
  );
$$;

create function private.is_assigned(p_work_order_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.work_order_assignees a
    where a.work_order_id = p_work_order_id
      and a.user_id = (select auth.uid())
  );
$$;

revoke all on function private.has_role(uuid, public.member_role[]) from public;
revoke all on function private.is_member(uuid) from public;
revoke all on function private.is_assigned(uuid) from public;

grant usage on schema private to authenticated;
grant execute on function private.has_role(uuid, public.member_role[]) to authenticated;
grant execute on function private.is_member(uuid) to authenticated;
grant execute on function private.is_assigned(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Table privileges
--
-- anon gets nothing. authenticated may update only the columns that are meant
-- to change; identity and tenancy columns (id, business_unit_id, user_id,
-- author_id, created_*) are immutable. RLS then decides which rows.
-- ---------------------------------------------------------------------------

revoke all on public.business_units, public.memberships, public.work_orders,
  public.work_order_assignees, public.work_order_updates from anon;

revoke update on public.business_units, public.memberships, public.work_orders,
  public.work_order_assignees, public.work_order_updates from authenticated;

grant update (name, timezone) on public.business_units to authenticated;
grant update (role, display_name) on public.memberships to authenticated;
grant update (title, notes, status, priority, due_on) on public.work_orders to authenticated;
grant update (body) on public.work_order_updates to authenticated;

alter table public.business_units enable row level security;
alter table public.memberships enable row level security;
alter table public.work_orders enable row level security;
alter table public.work_order_assignees enable row level security;
alter table public.work_order_updates enable row level security;

-- ---------------------------------------------------------------------------
-- business_units
-- Units are provisioned by the platform (service role / seed), not over the
-- API: there is deliberately no INSERT or DELETE policy.
-- ---------------------------------------------------------------------------

create policy "Members can view their units"
  on public.business_units for select
  to authenticated
  using (private.is_member(id));

create policy "Admins can update their unit"
  on public.business_units for update
  to authenticated
  using (private.has_role(id, '{admin}'))
  with check (private.has_role(id, '{admin}'));

-- ---------------------------------------------------------------------------
-- memberships
-- Every member sees who else is in the unit (needed to show assignees).
-- ---------------------------------------------------------------------------

create policy "Members can view memberships of their units"
  on public.memberships for select
  to authenticated
  using (private.is_member(business_unit_id));

create policy "Admins can add members"
  on public.memberships for insert
  to authenticated
  with check (private.has_role(business_unit_id, '{admin}'));

create policy "Admins can change members"
  on public.memberships for update
  to authenticated
  using (private.has_role(business_unit_id, '{admin}'))
  with check (private.has_role(business_unit_id, '{admin}'));

create policy "Admins can remove members"
  on public.memberships for delete
  to authenticated
  using (private.has_role(business_unit_id, '{admin}'));

-- ---------------------------------------------------------------------------
-- work_orders
-- ---------------------------------------------------------------------------

create policy "Office sees all work orders, technicians their own"
  on public.work_orders for select
  to authenticated
  using (
    private.has_role(business_unit_id, '{admin,office}')
    or private.is_assigned(id)
  );

create policy "Office can create work orders"
  on public.work_orders for insert
  to authenticated
  with check (
    private.has_role(business_unit_id, '{admin,office}')
    and created_by = (select auth.uid())
  );

create policy "Office edits all work orders, technicians their own"
  on public.work_orders for update
  to authenticated
  using (
    private.has_role(business_unit_id, '{admin,office}')
    or private.is_assigned(id)
  )
  with check (
    private.has_role(business_unit_id, '{admin,office}')
    or private.is_assigned(id)
  );

create policy "Admins can delete work orders"
  on public.work_orders for delete
  to authenticated
  using (private.has_role(business_unit_id, '{admin}'));

-- RLS decides which rows a technician may update; it cannot restrict columns
-- per role. This trigger does: a technician may move the status of an order
-- assigned to them and nothing else. Requests without a user (service role,
-- migrations, seed) are trusted backend code and are not restricted here.
create function private.work_orders_restrict_technician_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (select auth.uid()) is null
     or private.has_role(old.business_unit_id, '{admin,office}') then
    return new;
  end if;

  if (to_jsonb(new) - '{status,updated_at,completed_at}'::text[])
     is distinct from (to_jsonb(old) - '{status,updated_at,completed_at}'::text[]) then
    raise exception 'Technicians may only change the status of a work order'
      using errcode = 'insufficient_privilege';
  end if;

  return new;
end;
$$;

create trigger work_orders_restrict_technician_update
  before update on public.work_orders
  for each row execute function private.work_orders_restrict_technician_update();

-- ---------------------------------------------------------------------------
-- work_order_assignees
-- No UPDATE policy: an assignment has nothing to edit; reassigning is
-- delete + insert. The composite foreign keys already guarantee that the
-- assignee is a member of the work order's unit.
-- ---------------------------------------------------------------------------

create policy "Office sees all assignments, technicians those on their orders"
  on public.work_order_assignees for select
  to authenticated
  using (
    private.has_role(business_unit_id, '{admin,office}')
    or private.is_assigned(work_order_id)
  );

create policy "Office can assign"
  on public.work_order_assignees for insert
  to authenticated
  with check (private.has_role(business_unit_id, '{admin,office}'));

create policy "Office can unassign"
  on public.work_order_assignees for delete
  to authenticated
  using (private.has_role(business_unit_id, '{admin,office}'));

-- ---------------------------------------------------------------------------
-- work_order_updates (comment thread)
-- Anyone who can see the work order can read and post; only the author edits
-- (while they can still see the order); the author or an admin deletes.
-- ---------------------------------------------------------------------------

create policy "Comments are visible with their work order"
  on public.work_order_updates for select
  to authenticated
  using (
    private.has_role(business_unit_id, '{admin,office}')
    or private.is_assigned(work_order_id)
  );

create policy "Members on the order can comment as themselves"
  on public.work_order_updates for insert
  to authenticated
  with check (
    author_id = (select auth.uid())
    and (
      private.has_role(business_unit_id, '{admin,office}')
      or private.is_assigned(work_order_id)
    )
  );

create policy "Authors can edit their comments"
  on public.work_order_updates for update
  to authenticated
  using (
    author_id = (select auth.uid())
    and (
      private.has_role(business_unit_id, '{admin,office}')
      or private.is_assigned(work_order_id)
    )
  )
  with check (author_id = (select auth.uid()));

create policy "Authors and admins can delete comments"
  on public.work_order_updates for delete
  to authenticated
  using (
    author_id = (select auth.uid())
    or private.has_role(business_unit_id, '{admin}')
  );
