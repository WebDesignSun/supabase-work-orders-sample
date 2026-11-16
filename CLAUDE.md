# CLAUDE.md

Rules for AI-assisted work in this repository. They are short on purpose:
each one exists because breaking it causes a real defect.

## Layout

- `supabase/migrations/` — one migration creates tables, a separate one holds
  RLS. An applied migration is immutable: change behaviour with a new file.
- `supabase/functions/<name>/index.ts` — HTTP shell only: CORS, auth,
  validation, role check, database reads/writes.
- `supabase/functions/<name>/logic.ts` — pure functions. No I/O, no
  `Deno.env`, no Supabase client. Everything here has a test in `logic_test.ts`.
- A new function's directory goes into `workspace` in the root `deno.json`;
  otherwise its import map is ignored by `deno test` / `deno check`.
- `supabase/tests/*.test.sql` — pgTAP. Self-contained fixtures inside the test
  transaction; never depend on `seed.sql`. Impersonate with
  `select set_config('request.jwt.claims', '{"sub":"<uuid>","role":"authenticated"}', true); set local role authenticated;`
  and `reset role` after. Raise `select plan(n)` with every test you add.
- `README.md` repeats the access table, test counts and pinned versions. A
  change to a policy, a test or a dependency updates it in the same PR.

## Database

- Every table has RLS enabled, with separate `select` / `insert` / `update` /
  `delete` policies `to authenticated`. A missing policy is a deliberate
  "deny" and gets a comment saying so.
- Every tenant table carries `business_unit_id not null`. Child tables point at
  their parent with a composite `(id, business_unit_id)` foreign key so a row
  can never reference another unit's parent. The parent declares
  `unique (id, business_unit_id)` as the FK target.
- Use `(select auth.uid())`, never bare `auth.uid()`, in policies and helpers.
- Role checks go through `private.*` helpers: `security definer`,
  `set search_path = ''`, fully qualified names, `execute` granted only to
  `authenticated`. Never put a security-definer function in `public`.
- Columns that must never change (ids, tenancy, authorship) are protected by
  column-level `grant update (...)`, not by convention. New table:
  `revoke all ... from anon`, `revoke update ... from authenticated`, then
  `grant update (<mutable columns>)`.
- A column limit that depends on the member role (a technician may change only
  `status`) needs a `before update` trigger in `private`; RLS filters rows,
  grants apply per database role.
- Index every foreign key and every column a policy filters on.
- Calendar dates (`due_on`) are `date` in the unit's IANA zone; instants are
  `timestamptz`. Compare them only after converting the instant to a local date.

## Edge Functions

- Strict TypeScript; no `any`, no `@ts-ignore`. Database types come from
  `supabase gen types` — regenerate after every migration, then format, or
  `deno fmt --check` fails:

  ```bash
  supabase gen types typescript --local --schema public \
    > supabase/functions/_shared/database.types.ts
  deno fmt supabase/functions/_shared/database.types.ts
  ```
- Validate the body with zod (`strictObject`); return field-level issues on 400.
- Authenticate with `supabase.auth.getUser(token)`; query with the caller's
  JWT so RLS applies. The service role needs a written justification in a
  comment next to it.
- Status codes: 400 invalid input, 401 no/invalid token, 403 wrong role,
  404 not found or not a member (do not reveal which), 405, 422 for a valid
  request we refuse to answer, 500 with a generic message. Internal details go
  to `console.error`, never into a response.
- No query inside a loop: embed relations or batch with `in`, then map in
  memory. Independent reads run in `Promise.all`.
- PostgREST silently truncates at `[api] max_rows` (`config.toml`). A function
  that needs every row selects with `count: 'exact'` and returns 422 past the
  limit; its limit constant (`MAX_WORK_ORDERS`) must equal `max_rows`.

## Before saying "done"

```bash
supabase start             # once; the commands below need the local stack
supabase db reset          # migrations + seed apply cleanly
supabase test db           # pgTAP
deno test                  # logic
deno lint && deno fmt --check && deno check supabase/functions/*/index.ts
```

All four must pass, and the output goes into the PR description.

## Tooling

- CI (`.github/workflows/ci.yml`) runs the same checks plus a drift check of
  `database.types.ts`. The AI review (`claude-review.yml`) checks every PR
  against this file; a `high` finding blocks the PR.
- Hooks in `.claude/settings.json` block edits to a committed migration and
  run `deno fmt` + `deno lint` after each `.ts` edit. Fix what they report;
  do not bypass them (no `sed -i` on a committed migration).
