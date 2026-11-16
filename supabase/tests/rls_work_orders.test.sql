-- RLS for the work-order tables: each role sees and changes only what it is
-- allowed to, across two business units, and anon has no access at all.
--
-- Self-contained: creates its own users, units and orders inside the test
-- transaction (rolled back at the end), so it passes with or without seed.sql.
--
-- Fixture ids (unit A = "a…", unit B = "b…"):
--   unit A            aaaaaaaa-0000-4000-8000-000000000001
--   unit B            bbbbbbbb-0000-4000-8000-000000000001
--   A admin           aaaaaaaa-0000-4000-8000-0000000000a1
--   A office          aaaaaaaa-0000-4000-8000-0000000000a2
--   A technician 1    aaaaaaaa-0000-4000-8000-0000000000a3
--   A technician 2    aaaaaaaa-0000-4000-8000-0000000000a4
--   not yet a member  aaaaaaaa-0000-4000-8000-0000000000a5
--   B admin           bbbbbbbb-0000-4000-8000-0000000000b1
--   order 1 (A, tech 1)  aaaaaaaa-0000-4000-8000-0000000000c1
--   order 2 (A, tech 2)  aaaaaaaa-0000-4000-8000-0000000000c2
--   order 3 (B)          bbbbbbbb-0000-4000-8000-0000000000c3

begin;

create extension if not exists pgtap with schema extensions;

select plan(37);

-- ---------------------------------------------------------------------------
-- Fixtures (as the table owner, RLS does not apply)
-- ---------------------------------------------------------------------------

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-4000-8000-0000000000a1', 'a.admin@example.test'),
  ('aaaaaaaa-0000-4000-8000-0000000000a2', 'a.office@example.test'),
  ('aaaaaaaa-0000-4000-8000-0000000000a3', 'a.tech1@example.test'),
  ('aaaaaaaa-0000-4000-8000-0000000000a4', 'a.tech2@example.test'),
  ('aaaaaaaa-0000-4000-8000-0000000000a5', 'a.newcomer@example.test'),
  ('bbbbbbbb-0000-4000-8000-0000000000b1', 'b.admin@example.test');

insert into public.business_units (id, name) values
  ('aaaaaaaa-0000-4000-8000-000000000001', 'Unit A'),
  ('bbbbbbbb-0000-4000-8000-000000000001', 'Unit B');

insert into public.memberships (business_unit_id, user_id, role, display_name) values
  ('aaaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-0000000000a1', 'admin', 'A Admin'),
  ('aaaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-0000000000a2', 'office', 'A Office'),
  ('aaaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-0000000000a3', 'technician', 'A Tech 1'),
  ('aaaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-0000000000a4', 'technician', 'A Tech 2'),
  ('bbbbbbbb-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-0000000000b1', 'admin', 'B Admin');

insert into public.work_orders (id, business_unit_id, title, due_on) values
  ('aaaaaaaa-0000-4000-8000-0000000000c1', 'aaaaaaaa-0000-4000-8000-000000000001', 'Order 1', '2026-11-10'),
  ('aaaaaaaa-0000-4000-8000-0000000000c2', 'aaaaaaaa-0000-4000-8000-000000000001', 'Order 2', '2026-11-11'),
  ('bbbbbbbb-0000-4000-8000-0000000000c3', 'bbbbbbbb-0000-4000-8000-000000000001', 'Order 3', '2026-11-12');

insert into public.work_order_assignees (work_order_id, business_unit_id, user_id) values
  ('aaaaaaaa-0000-4000-8000-0000000000c1', 'aaaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-0000000000a3'),
  ('aaaaaaaa-0000-4000-8000-0000000000c2', 'aaaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-0000000000a4');

-- ---------------------------------------------------------------------------
-- Structure
-- ---------------------------------------------------------------------------

select is_empty(
  $$ select c.relname
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity $$,
  'RLS is enabled on every table in public'
);

select is(
  (select count(distinct cmd)::int from pg_policies
   where schemaname = 'public' and tablename = 'work_orders'),
  4,
  'work_orders has separate SELECT, INSERT, UPDATE and DELETE policies'
);

-- ---------------------------------------------------------------------------
-- anon: no access
-- ---------------------------------------------------------------------------

set local role anon;

select throws_ok(
  $$ select * from public.work_orders $$,
  '42501', null,
  'anon cannot read work orders'
);

select throws_ok(
  $$ insert into public.work_orders (business_unit_id, title)
     values ('aaaaaaaa-0000-4000-8000-000000000001', 'x') $$,
  '42501', null,
  'anon cannot create work orders'
);

reset role;

-- ---------------------------------------------------------------------------
-- technician 1 of unit A
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims',
  '{"sub": "aaaaaaaa-0000-4000-8000-0000000000a3", "role": "authenticated"}', true);
set local role authenticated;

select results_eq(
  $$ select id from public.work_orders $$,
  $$ values ('aaaaaaaa-0000-4000-8000-0000000000c1'::uuid) $$,
  'technician sees only the work orders assigned to them'
);

select is(
  (select count(*)::int from public.work_order_assignees),
  1,
  'technician sees only the assignments on their own orders'
);

select is(
  (select count(*)::int from public.memberships),
  4,
  'technician sees the members of their own unit only'
);

select lives_ok(
  $$ update public.work_orders set status = 'done'
     where id = 'aaaaaaaa-0000-4000-8000-0000000000c1' $$,
  'technician can change the status of their own order'
);

select isnt(
  (select completed_at from public.work_orders
   where id = 'aaaaaaaa-0000-4000-8000-0000000000c1'),
  null,
  'completing an order stamps completed_at'
);

select throws_ok(
  $$ update public.work_orders set title = 'Renamed'
     where id = 'aaaaaaaa-0000-4000-8000-0000000000c1' $$,
  '42501', 'Technicians may only change the status of a work order',
  'technician cannot change anything but the status'
);

select throws_ok(
  $$ update public.work_orders set business_unit_id = 'bbbbbbbb-0000-4000-8000-000000000001'
     where id = 'aaaaaaaa-0000-4000-8000-0000000000c1' $$,
  '42501', null,
  'nobody can move a work order to another unit (column not updatable)'
);

select is_empty(
  $$ update public.work_orders set status = 'done'
     where id = 'aaaaaaaa-0000-4000-8000-0000000000c2' returning id $$,
  'technician cannot update an order assigned to someone else'
);

select is_empty(
  $$ delete from public.work_orders
     where id = 'aaaaaaaa-0000-4000-8000-0000000000c1' returning id $$,
  'technician cannot delete work orders'
);

select throws_ok(
  $$ insert into public.work_orders (business_unit_id, title, created_by)
     values ('aaaaaaaa-0000-4000-8000-000000000001', 'x', 'aaaaaaaa-0000-4000-8000-0000000000a3') $$,
  '42501', null,
  'technician cannot create work orders'
);

select throws_ok(
  $$ insert into public.work_order_assignees (work_order_id, business_unit_id, user_id)
     values ('aaaaaaaa-0000-4000-8000-0000000000c2', 'aaaaaaaa-0000-4000-8000-000000000001',
             'aaaaaaaa-0000-4000-8000-0000000000a3') $$,
  '42501', null,
  'technician cannot assign themselves to an order'
);

select lives_ok(
  $$ insert into public.work_order_updates (work_order_id, business_unit_id, author_id, body)
     values ('aaaaaaaa-0000-4000-8000-0000000000c1', 'aaaaaaaa-0000-4000-8000-000000000001',
             'aaaaaaaa-0000-4000-8000-0000000000a3', 'Done, photos in the folder.') $$,
  'technician can comment on their own order'
);

select throws_ok(
  $$ insert into public.work_order_updates (work_order_id, business_unit_id, author_id, body)
     values ('aaaaaaaa-0000-4000-8000-0000000000c2', 'aaaaaaaa-0000-4000-8000-000000000001',
             'aaaaaaaa-0000-4000-8000-0000000000a3', 'x') $$,
  '42501', null,
  'technician cannot comment on someone else''s order'
);

select throws_ok(
  $$ insert into public.work_order_updates (work_order_id, business_unit_id, author_id, body)
     values ('aaaaaaaa-0000-4000-8000-0000000000c1', 'aaaaaaaa-0000-4000-8000-000000000001',
             'aaaaaaaa-0000-4000-8000-0000000000a2', 'x') $$,
  '42501', null,
  'technician cannot post a comment in someone else''s name'
);

-- ---------------------------------------------------------------------------
-- office of unit A
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims',
  '{"sub": "aaaaaaaa-0000-4000-8000-0000000000a2", "role": "authenticated"}', true);

select results_eq(
  $$ select id from public.work_orders order by id $$,
  $$ values ('aaaaaaaa-0000-4000-8000-0000000000c1'::uuid),
            ('aaaaaaaa-0000-4000-8000-0000000000c2'::uuid) $$,
  'office sees every order of its unit and none of another unit'
);

select lives_ok(
  $$ insert into public.work_orders (business_unit_id, title, created_by)
     values ('aaaaaaaa-0000-4000-8000-000000000001', 'New order',
             'aaaaaaaa-0000-4000-8000-0000000000a2') $$,
  'office can create a work order in its unit'
);

select throws_ok(
  $$ insert into public.work_orders (business_unit_id, title, created_by)
     values ('bbbbbbbb-0000-4000-8000-000000000001', 'x', 'aaaaaaaa-0000-4000-8000-0000000000a2') $$,
  '42501', null,
  'office cannot create a work order in another unit'
);

select lives_ok(
  $$ update public.work_orders set title = 'Order 2 (revised)', priority = 'high'
     where id = 'aaaaaaaa-0000-4000-8000-0000000000c2' $$,
  'office can edit any order of its unit'
);

select lives_ok(
  $$ insert into public.work_order_assignees (work_order_id, business_unit_id, user_id)
     values ('aaaaaaaa-0000-4000-8000-0000000000c1', 'aaaaaaaa-0000-4000-8000-000000000001',
             'aaaaaaaa-0000-4000-8000-0000000000a4') $$,
  'office can assign a technician of its unit'
);

select throws_ok(
  $$ insert into public.work_order_assignees (work_order_id, business_unit_id, user_id)
     values ('aaaaaaaa-0000-4000-8000-0000000000c1', 'aaaaaaaa-0000-4000-8000-000000000001',
             'bbbbbbbb-0000-4000-8000-0000000000b1') $$,
  '23503', null,
  'only members of the order''s unit can be assigned'
);

select is_empty(
  $$ delete from public.work_orders
     where id = 'aaaaaaaa-0000-4000-8000-0000000000c2' returning id $$,
  'office cannot delete work orders'
);

select throws_ok(
  $$ insert into public.memberships (business_unit_id, user_id, role, display_name)
     values ('aaaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-0000000000a5',
             'technician', 'Newcomer') $$,
  '42501', null,
  'office cannot add members'
);

select is_empty(
  $$ update public.business_units set name = 'Renamed'
     where id = 'aaaaaaaa-0000-4000-8000-000000000001' returning id $$,
  'office cannot change the unit'
);

-- ---------------------------------------------------------------------------
-- admin of unit A
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims',
  '{"sub": "aaaaaaaa-0000-4000-8000-0000000000a1", "role": "authenticated"}', true);

select isnt_empty(
  $$ delete from public.work_orders
     where id = 'aaaaaaaa-0000-4000-8000-0000000000c2' returning id $$,
  'admin can delete a work order of its unit'
);

select lives_ok(
  $$ insert into public.memberships (business_unit_id, user_id, role, display_name)
     values ('aaaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-0000000000a5',
             'technician', 'Newcomer') $$,
  'admin can add a member to its unit'
);

select throws_ok(
  $$ update public.memberships set role = 'office'
     where business_unit_id = 'aaaaaaaa-0000-4000-8000-000000000001'
       and user_id = 'aaaaaaaa-0000-4000-8000-0000000000a1' $$,
  '23514', 'A business unit must keep at least one admin',
  'the last admin of a unit cannot be demoted'
);

select is_empty(
  $$ select id from public.work_orders
     where business_unit_id = 'bbbbbbbb-0000-4000-8000-000000000001' $$,
  'admin sees nothing of another unit'
);

select is_empty(
  $$ delete from public.memberships
     where business_unit_id = 'bbbbbbbb-0000-4000-8000-000000000001' returning user_id $$,
  'admin cannot remove members of another unit'
);

select throws_ok(
  $$ insert into public.business_units (name) values ('Rogue unit') $$,
  '42501', null,
  'units cannot be created over the API'
);

-- ---------------------------------------------------------------------------
-- admin of unit B
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims',
  '{"sub": "bbbbbbbb-0000-4000-8000-0000000000b1", "role": "authenticated"}', true);

select results_eq(
  $$ select id from public.work_orders $$,
  $$ values ('bbbbbbbb-0000-4000-8000-0000000000c3'::uuid) $$,
  'admin of unit B sees only unit B'
);

select is(
  (select count(*)::int from public.work_order_updates),
  0,
  'comments of another unit are invisible'
);

-- ---------------------------------------------------------------------------
-- Cross-check as owner: what the technician could not touch is unchanged
-- ---------------------------------------------------------------------------

reset role;

select is(
  (select title from public.work_orders where id = 'aaaaaaaa-0000-4000-8000-0000000000c1'),
  'Order 1',
  'the rejected title change left order 1 as it was'
);

select throws_ok(
  $$ delete from auth.users where id = 'bbbbbbbb-0000-4000-8000-0000000000b1' $$,
  '23514', 'A business unit must keep at least one admin',
  'deleting the user account of a unit''s last admin is refused'
);

select * from finish();

rollback;
