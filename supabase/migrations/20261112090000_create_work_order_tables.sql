-- Work orders: jobs a business unit's office creates and assigns to its
-- technicians, with a comment thread per job.
--
-- Tenancy: a business unit is the tenant. Every row carries business_unit_id,
-- and child tables reference their parent through a composite
-- (id, business_unit_id) foreign key, so a row can never point at a parent in
-- another unit. Access rules live in the next migration (RLS).
--
-- Dates: due_on is a calendar date in the unit's IANA time zone, not an
-- instant. completed_at is an instant (timestamptz). The two are only compared
-- after converting the instant to the unit's local date.

create schema if not exists private;
revoke all on schema private from public;

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

create type public.member_role as enum ('admin', 'office', 'technician');
create type public.work_order_status as enum ('not_started', 'working', 'stuck', 'done');
create type public.work_order_priority as enum ('critical', 'high', 'medium', 'low');

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.business_units (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 120),
  timezone text not null default 'Europe/Berlin'
    check (char_length(timezone) between 1 and 64),
  created_at timestamptz not null default now()
);

comment on column public.business_units.timezone is
  'IANA zone id (never a UTC offset). Due dates are local calendar dates in this zone.';

-- One row per (unit, user): membership and role in one place. A user may
-- belong to several units with a different role in each.
create table public.memberships (
  business_unit_id uuid not null references public.business_units (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  role public.member_role not null,
  display_name text not null check (char_length(display_name) between 1 and 120),
  created_at timestamptz not null default now(),
  primary key (business_unit_id, user_id)
);

create index memberships_user_id_idx on public.memberships (user_id);

create table public.work_orders (
  id uuid primary key default gen_random_uuid(),
  business_unit_id uuid not null references public.business_units (id) on delete cascade,
  title text not null check (char_length(title) between 1 and 300),
  notes text check (char_length(notes) <= 2000),
  status public.work_order_status not null default 'not_started',
  priority public.work_order_priority not null default 'medium',
  due_on date,
  completed_at timestamptz,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- Target of the composite foreign keys on the child tables.
  constraint work_orders_id_business_unit_id_key unique (id, business_unit_id),
  constraint work_orders_completed_at_matches_status
    check ((status = 'done') = (completed_at is not null))
);

-- Leading column covers the business_unit_id foreign key; due_on serves the
-- report's range filter.
create index work_orders_business_unit_id_due_on_idx
  on public.work_orders (business_unit_id, due_on);
create index work_orders_created_by_idx on public.work_orders (created_by);

create table public.work_order_assignees (
  work_order_id uuid not null,
  business_unit_id uuid not null,
  user_id uuid not null,
  assigned_at timestamptz not null default now(),
  primary key (work_order_id, user_id),
  constraint work_order_assignees_work_order_fkey
    foreign key (work_order_id, business_unit_id)
    references public.work_orders (id, business_unit_id) on delete cascade,
  -- Only a member of the same unit can be assigned. Removing the membership
  -- removes the assignment.
  constraint work_order_assignees_membership_fkey
    foreign key (business_unit_id, user_id)
    references public.memberships (business_unit_id, user_id) on delete cascade
);

create index work_order_assignees_business_unit_id_user_id_idx
  on public.work_order_assignees (business_unit_id, user_id);
create index work_order_assignees_user_id_idx on public.work_order_assignees (user_id);

create table public.work_order_updates (
  id uuid primary key default gen_random_uuid(),
  work_order_id uuid not null,
  business_unit_id uuid not null,
  author_id uuid not null references auth.users (id) on delete cascade,
  body text not null check (char_length(body) between 1 and 5000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint work_order_updates_work_order_fkey
    foreign key (work_order_id, business_unit_id)
    references public.work_orders (id, business_unit_id) on delete cascade
);

create index work_order_updates_work_order_id_created_at_idx
  on public.work_order_updates (work_order_id, created_at);
create index work_order_updates_author_id_idx on public.work_order_updates (author_id);

-- ---------------------------------------------------------------------------
-- Integrity triggers
-- ---------------------------------------------------------------------------

-- Keeps updated_at and completed_at consistent with status. completed_at is
-- stamped when an order becomes done and cleared when it is reopened; an
-- insert may carry a historical completed_at (back-filling finished work).
create function private.work_orders_maintain_timestamps()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.completed_at := case
      when new.status = 'done' then coalesce(new.completed_at, now())
    end;
    return new;
  end if;

  new.updated_at := now();
  new.completed_at := case
    when new.status <> 'done' then null
    when old.status = 'done' then old.completed_at
    else now()
  end;
  return new;
end;
$$;

create trigger work_orders_maintain_timestamps
  before insert or update on public.work_orders
  for each row execute function private.work_orders_maintain_timestamps();

create function private.work_order_updates_touch()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger work_order_updates_touch
  before update on public.work_order_updates
  for each row execute function private.work_order_updates_touch();

-- A unit must always keep at least one admin, otherwise nobody can manage its
-- memberships any more. The unit row is locked first so two concurrent
-- demotions cannot both see "another admin still exists".
create function private.memberships_keep_last_admin()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.role <> 'admin' or (tg_op = 'UPDATE' and new.role = 'admin') then
    return coalesce(new, old);
  end if;

  perform 1 from public.business_units where id = old.business_unit_id for update;

  -- The unit itself is being deleted (cascade): nothing to protect.
  if not found then
    return coalesce(new, old);
  end if;

  if not exists (
    select 1
    from public.memberships m
    where m.business_unit_id = old.business_unit_id
      and m.role = 'admin'
      and m.user_id <> old.user_id
  ) then
    raise exception 'A business unit must keep at least one admin'
      using errcode = 'check_violation';
  end if;

  return coalesce(new, old);
end;
$$;

create trigger memberships_keep_last_admin
  before update of role or delete on public.memberships
  for each row execute function private.memberships_keep_last_admin();
