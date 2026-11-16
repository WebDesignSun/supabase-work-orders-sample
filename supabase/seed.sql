-- Local demo data. Fictional units and people only; e-mail addresses use the
-- reserved example.com domain.
--
-- The users are created WITHOUT a password. To sign in locally, set one from
-- your .env (see README, "Run it"), so no credential lives in the repository.

-- ---------------------------------------------------------------------------
-- Users (auth schema)
-- ---------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change_token_new, email_change
)
select
  '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
  u.email, '', now(),
  '{"provider": "email", "providers": ["email"]}', '{}', now(), now(),
  '', '', '', ''
from (values
  ('10000000-0000-4000-8000-000000000001'::uuid, 'admin@example.com'),
  ('10000000-0000-4000-8000-000000000002'::uuid, 'office@example.com'),
  ('10000000-0000-4000-8000-000000000003'::uuid, 'ben.tech@example.com'),
  ('10000000-0000-4000-8000-000000000004'::uuid, 'clara.tech@example.com'),
  ('10000000-0000-4000-8000-000000000005'::uuid, 'south.admin@example.com')
) as u (id, email);

insert into auth.identities (
  id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at
)
select
  gen_random_uuid(), u.id, u.id::text, 'email',
  jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true),
  now(), now(), now()
from auth.users u
where u.email like '%@example.com';

-- ---------------------------------------------------------------------------
-- Business units and memberships
-- ---------------------------------------------------------------------------

insert into public.business_units (id, name, timezone) values
  ('a0000000-0000-4000-8000-000000000001', 'Crew North', 'Europe/Berlin'),
  ('a0000000-0000-4000-8000-000000000002', 'Crew South', 'Europe/Vienna');

insert into public.memberships (business_unit_id, user_id, role, display_name) values
  ('a0000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001', 'admin', 'Alex Admin'),
  ('a0000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000002', 'office', 'Olivia Office'),
  ('a0000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000003', 'technician', 'Ben Technician'),
  ('a0000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000004', 'technician', 'Clara Technician'),
  ('a0000000-0000-4000-8000-000000000002', '10000000-0000-4000-8000-000000000005', 'admin', 'Sven South');

-- ---------------------------------------------------------------------------
-- Work orders (Crew North, November 2026) and one in Crew South
-- ---------------------------------------------------------------------------

insert into public.work_orders (id, business_unit_id, title, status, priority, due_on, completed_at, created_by) values
  ('c0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001',
   'Replace broken ridge tiles', 'done', 'high', '2026-11-03', '2026-11-03 14:10:00+00', '10000000-0000-4000-8000-000000000002'),
  -- Finished at 00:30 local time on 6 Nov: late for a 5 Nov due date, although
  -- the UTC instant is still 5 Nov.
  ('c0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000001',
   'Clear gutters and downpipes', 'done', 'medium', '2026-11-05', '2026-11-05 23:30:00+00', '10000000-0000-4000-8000-000000000002'),
  ('c0000000-0000-4000-8000-000000000003', 'a0000000-0000-4000-8000-000000000001',
   'Inspect flat roof drainage', 'working', 'medium', '2026-11-10', null, '10000000-0000-4000-8000-000000000002'),
  ('c0000000-0000-4000-8000-000000000004', 'a0000000-0000-4000-8000-000000000001',
   'Seal skylight flashing', 'stuck', 'critical', '2026-11-20', null, '10000000-0000-4000-8000-000000000002'),
  ('c0000000-0000-4000-8000-000000000005', 'a0000000-0000-4000-8000-000000000001',
   'Quote: insulation of attic', 'not_started', 'low', '2026-11-27', null, '10000000-0000-4000-8000-000000000002'),
  ('c0000000-0000-4000-8000-000000000006', 'a0000000-0000-4000-8000-000000000002',
   'Snow guard installation', 'not_started', 'medium', '2026-11-15', null, '10000000-0000-4000-8000-000000000005');

insert into public.work_order_assignees (work_order_id, business_unit_id, user_id) values
  ('c0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000003'),
  ('c0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000003'),
  ('c0000000-0000-4000-8000-000000000003', 'a0000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000003'),
  ('c0000000-0000-4000-8000-000000000003', 'a0000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000004'),
  ('c0000000-0000-4000-8000-000000000004', 'a0000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000004');

insert into public.work_order_updates (work_order_id, business_unit_id, author_id, body) values
  ('c0000000-0000-4000-8000-000000000004', 'a0000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000004',
   'Waiting for replacement flashing kit from the supplier.');
