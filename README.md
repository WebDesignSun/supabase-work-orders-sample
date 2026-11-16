# Work orders — Supabase code sample

One complete feature on Supabase: a business unit's office creates **work
orders**, assigns them to **technicians**, and exports a **workload report**
(open / overdue / done on time / done late per technician) for a due-date
range, as JSON or CSV.

| Part | File |
| --- | --- |
| Migration: tables | `supabase/migrations/20261112090000_create_work_order_tables.sql` |
| Migration: RLS | `supabase/migrations/20261112090100_work_order_rls_policies.sql` |
| Edge Function | `supabase/functions/work-order-report/` (`index.ts`, `logic.ts`) |
| Tests: RLS (pgTAP) | `supabase/tests/rls_work_orders.test.sql` — 37 tests |
| Tests: logic (Deno) | `supabase/functions/work-order-report/logic_test.ts` — 16 tests |

## Where this sample comes from

**We wrote this sample to show how we build on Supabase.** It is not code from a client
project.

It ports one feature from our own product, a multi-tenant SaaS booking
platform (NestJS, Prisma, PostgreSQL) that runs in production. In that product,
each business unit has task boards: tasks with owners, a status, a priority, a
due date and a comment thread, with access limited to the unit. Here the same
design runs on Supabase, with Postgres RLS where the product uses an
application-level tenant scope.

These patterns come straight from that codebase:

- **The business unit is the tenant.** Every row carries `business_unit_id`, and
  no query can reach another unit's data.
- **Role presets per membership.** `admin` / `office` / `technician` here
  correspond to our `ADMIN` / `MANAGER` / `STAFF`.
- **Only members of the unit can be assigned.** In the product this is checked in
  code. Here a composite foreign key enforces it.
- **The last admin of a unit cannot be removed or demoted.** This also blocks
  deleting the user account of a unit's last admin: hand the admin role to
  another member first.
- **Calendar dates and instants are different things.** A due date is a calendar
  date in the unit's IANA time zone, and a completion time is an instant. They
  are compared only after the instant is converted to the unit's local date.
- **Thin HTTP layer, pure logic, no N+1.** One query loads the orders together
  with their assignees, and independent reads run in parallel.

## Authors

- [WebDesignSun](https://webdesignsun.com)

## Data model

```mermaid
erDiagram
  business_units ||--o{ memberships : "has members"
  business_units ||--o{ work_orders : owns
  work_orders ||--o{ work_order_assignees : "assigned to"
  memberships ||--o{ work_order_assignees : "(business_unit_id, user_id)"
  work_orders ||--o{ work_order_updates : "comment thread"
  auth_users ||--o{ memberships : "user"

  business_units {
    uuid id PK
    text name
    text timezone "IANA zone"
  }
  memberships {
    uuid business_unit_id PK, FK
    uuid user_id PK, FK
    member_role role
    text display_name
  }
  work_orders {
    uuid id PK
    uuid business_unit_id FK
    text title
    work_order_status status
    work_order_priority priority
    date due_on
    timestamptz completed_at
    uuid created_by FK
  }
  work_order_assignees {
    uuid work_order_id PK, FK
    uuid user_id PK, FK
    uuid business_unit_id FK
  }
  work_order_updates {
    uuid id PK
    uuid work_order_id FK
    uuid business_unit_id FK
    uuid author_id FK
    text body
  }
```

| Table | Purpose | Key constraints |
| --- | --- | --- |
| `business_units` | The tenant. `timezone` is the IANA zone of its due dates. | `name` 1–120 chars |
| `memberships` | Who belongs to a unit and with which role (`member_role`). | PK `(business_unit_id, user_id)`; last-admin trigger |
| `work_orders` | The job: title, notes, status, priority, `due_on`. | `unique (id, business_unit_id)`; `CHECK (status = 'done') = (completed_at IS NOT NULL)` |
| `work_order_assignees` | Who works on an order (one or more members). | composite FK to the order and to `memberships`, so the assignee must belong to the order's unit |
| `work_order_updates` | Comment thread per order. | composite FK to the order; `body` 1–5000 chars |

Every foreign key has an index, and so does every column a policy filters on.
A trigger stamps `completed_at` when an order becomes `done` and clears it when
the order is reopened.

## Access model

RLS is enabled on all five tables. Each operation has its own policy
`to authenticated`. `anon` has no table privileges at all. Role checks go
through `private.has_role()` / `is_member()` / `is_assigned()`. These are
`security definer` functions with `search_path = ''`, they live in a schema
PostgREST does not expose, and only `authenticated` may execute them. Policies
use `(select auth.uid())`.

| Table | Operation | admin | office | technician |
| --- | --- | --- | --- | --- |
| `business_units` | SELECT | own units | own units | own units |
| | UPDATE (`name`, `timezone`) | ✅ | — | — |
| | INSERT / DELETE | — (platform only) | — | — |
| `memberships` | SELECT | own units | own units | own units |
| | INSERT / UPDATE / DELETE | ✅ (not the last admin) | — | — |
| `work_orders` | SELECT | all in unit | all in unit | assigned to them |
| | INSERT | ✅ | ✅ | — |
| | UPDATE | ✅ | ✅ | assigned to them, **`status` only** |
| | DELETE | ✅ | — | — |
| `work_order_assignees` | SELECT | all in unit | all in unit | on their orders |
| | INSERT / DELETE | ✅ | ✅ | — |
| `work_order_updates` | SELECT | all in unit | all in unit | on their orders |
| | INSERT (as themselves) | ✅ | ✅ | on their orders |
| | UPDATE (`body`) | own comments | own comments | own comments |
| | DELETE | any in unit | own | own |

RLS cannot restrict columns per role. Two other mechanisms cover that:

- **Column-level grants.** No role can change `id`, `business_unit_id`,
  `user_id`, `author_id` or `created_*`.
- **A trigger for technicians.** A technician who updates an order may change
  only its `status`.

## Edge Function `work-order-report`

`POST /functions/v1/work-order-report` returns the workload report of one unit
for a due-date range. Only `office` and `admin` members of that unit can call
it.

What it does, in order:

1. Answers the `OPTIONS` preflight (CORS).
2. Rejects any method other than `POST`.
3. Reads the bearer token and resolves the user with `supabase.auth.getUser()`.
4. Validates the body with zod.
5. Looks up the caller's role in the unit.
6. Loads the unit, its members and the orders with their assignees. These are
   three reads in parallel, each made with the caller's JWT, so RLS applies.
   The service role is never used.
7. Builds the report in `logic.ts`.

**Request**

```json
{
  "businessUnitId": "a0000000-0000-4000-8000-000000000001",
  "from": "2026-11-01",
  "to": "2026-11-30",
  "format": "json"
}
```

- `from` and `to` are inclusive calendar dates. The range can be at most 92 days.
- `format` is `json` (default) or `csv`.
- Unknown keys are rejected.

**Response 200** (seed data, generated on 12 Nov 2026)

```json
{
  "businessUnit": { "id": "a0000000-0000-4000-8000-000000000001", "name": "Crew North", "timezone": "Europe/Berlin" },
  "from": "2026-11-01",
  "to": "2026-11-30",
  "today": "2026-11-12",
  "generatedAt": "2026-11-12T10:59:50.674Z",
  "rows": [
    { "userId": "10000000-0000-4000-8000-000000000003", "displayName": "Ben Technician", "role": "technician",
      "assigned": 3, "open": 1, "overdue": 1, "done": 2, "doneOnTime": 1, "doneLate": 1, "onTimeRatePercent": 50 },
    { "userId": "10000000-0000-4000-8000-000000000004", "displayName": "Clara Technician", "role": "technician",
      "assigned": 2, "open": 2, "overdue": 1, "done": 0, "doneOnTime": 0, "doneLate": 0, "onTimeRatePercent": null }
  ],
  "unassigned": { "assigned": 1, "open": 1, "overdue": 0, "done": 0, "doneOnTime": 0, "doneLate": 0, "onTimeRatePercent": null },
  "totals": { "assigned": 5, "open": 3, "overdue": 1, "done": 2, "doneOnTime": 1, "doneLate": 1, "onTimeRatePercent": 50 }
}
```

How to read the numbers:

- **On time vs. late.** Ben's order due 5 Nov was finished at 23:30 UTC, which
  is 00:30 on 6 Nov in Berlin, so it counts as **late**.
- **Totals count orders, not assignments.** An order with two assignees counts
  once in `totals`.

With `"format": "csv"` the function returns `text/csv` as a download:

```csv
technician,role,assigned,open,overdue,done,done_on_time,done_late,on_time_rate_percent
Ben Technician,technician,3,1,1,2,1,1,50
Clara Technician,technician,2,2,1,0,0,0,
(unassigned),,1,1,0,0,0,0,
(total),,5,3,1,2,1,1,50
```

Cells are quoted per RFC 4180. A text cell that starts with `= + - @` gets an
apostrophe prefix, so a spreadsheet does not run it as a formula.

**Errors** — the body is always `{ "error": "<message>" }`. Internal details go
to the function log only.

| Status | When |
| --- | --- |
| 400 | Body is not JSON, or fails validation. The response adds `issues: [{ path, message }]`. |
| 401 | No bearer token, or the token is invalid or expired. |
| 403 | The caller is a technician of the unit. |
| 404 | The unit does not exist **or** the caller is not a member. The two cases are not distinguished, so unit ids cannot be probed. |
| 405 | Any method other than `POST` or `OPTIONS`. |
| 422 | More than 1000 orders fall in the range. The function refuses rather than returning a report cut at the API row limit. |
| 500 | Anything unexpected. The response says only `Internal server error`. |

## Tests

**pgTAP** — `supabase/tests/rls_work_orders.test.sql`, 37 tests. The file
creates its own fixtures (two units, six users) inside the test transaction, so
it does not depend on `seed.sql`. It covers:

- **Structure:** RLS is on for every table in `public`, and `work_orders` has a
  separate policy for each of the four operations.
- **anon:** cannot read or write anything.
- **technician:** sees only the orders assigned to them, their assignments and
  their own unit's members. Can change the status of their own order, and
  `completed_at` gets stamped. Cannot:
  - change any other column, or move an order to another unit;
  - touch a colleague's order;
  - delete orders, create orders or assign themselves;
  - comment on a colleague's order or in someone else's name.
- **office:** sees all of its unit and nothing of the other unit. Can create,
  edit and assign within its unit. Cannot:
  - create an order in another unit;
  - assign a member of another unit (the foreign key rejects it);
  - delete orders, add members or change the unit.
- **admin:** can delete orders and add members. Cannot demote the last admin,
  and sees and removes nothing of another unit.
- **Last admin:** deleting the user account of a unit's last admin is refused.
- **Cross-unit:** the other unit's admin sees only its own orders and none of
  unit A's comments.

As a mutation check, we opened the `work_orders` SELECT policy to everyone and
dropped the technician trigger. Six tests failed.

**Deno** — `logic_test.ts`, 16 tests:

- **Request validation:** defaults; the 92-day boundary (inclusive) and one day
  past it; `to` before `from`; field-level errors for a bad UUID, an impossible
  date (`2026-02-30`), the wrong date format and an unknown `format`; unknown
  keys; `null` and array bodies.
- **Time zones:** conversion of an instant to a local date in winter and summer
  time; an unknown zone throws.
- **Report:** open / overdue / on-time / late per technician; the
  23:30 UTC = next day in Berlin case; "today" and overdue follow the unit's
  zone, not UTC; technicians with no work still get a row; non-technicians with
  assignments get one too; empty ranges give null rates; on-time rate rounding;
  a duplicate assignee is counted once; inconsistent data throws instead of
  being miscounted.
- **CSV:** exact output, quoting, formula neutralising.

## Run it

Prerequisites: Docker, [Supabase CLI](https://supabase.com/docs/guides/cli) ≥ 3.0,
[Deno](https://deno.com) ≥ 2.

```bash
cp .env.example .env            # then pick your own DEMO_PASSWORD
supabase start                  # starts Postgres, Auth, REST and the Edge Runtime; applies both migrations and seed.sql
supabase test db                # pgTAP: 37 tests
deno test                       # Deno: 16 tests
deno lint && deno fmt --check   # static checks
```

To call the function, first give the seeded users a local password. The seed
creates them without one, so no credential is stored in the repository. Then
sign in and call the function:

```bash
set -a; source .env; set +a
docker exec -i supabase_db_supabase-work-orders-sample psql -U postgres -v pw="$DEMO_PASSWORD" <<'SQL'
update auth.users set encrypted_password = extensions.crypt(:'pw', extensions.gen_salt('bf'))
where email like '%@example.com';
SQL

eval "$(supabase status -o env | grep -E '^(API_URL|ANON_KEY)=')"
token() {
  curl -s "$API_URL/auth/v1/token?grant_type=password" \
    -H "apikey: $ANON_KEY" -H 'Content-Type: application/json' \
    -d "{\"email\":\"$1\",\"password\":\"$DEMO_PASSWORD\"}" \
  | deno eval 'console.log((await new Response(Deno.stdin.readable).json()).access_token)'
}

curl -s "$API_URL/functions/v1/work-order-report" \
  -H "Authorization: Bearer $(token office@example.com)" \
  -H 'Content-Type: application/json' \
  -d '{"businessUnitId":"a0000000-0000-4000-8000-000000000001","from":"2026-11-01","to":"2026-11-30","format":"csv"}'
```

The seeded users are:

| Email | Unit | Role | Report result |
| --- | --- | --- | --- |
| `admin@example.com` | Crew North | admin | 200 |
| `office@example.com` | Crew North | office | 200 |
| `ben.tech@example.com` | Crew North | technician | 403 |
| `clara.tech@example.com` | Crew North | technician | 403 |
| `south.admin@example.com` | Crew South | admin | 404 for Crew North |

### Test run (clean `supabase db reset`, 16 Nov 2026; local paths removed)

```text
$ supabase test db
Target: local stack (127.0.0.1:54322)
supabase/tests/rls_work_orders.test.sql .. ok
All tests successful.
Files=1, Tests=37,  0 wallclock secs ( 0.01 usr  0.00 sys +  0.01 cusr  0.00 csys =  0.02 CPU)
Result: PASS

$ deno test
running 16 tests from ./supabase/functions/work-order-report/logic_test.ts
request: a valid body is accepted and format defaults to json ... ok
request: a range of exactly MAX_RANGE_DAYS is accepted, one more day is not ... ok
request: `to` before `from` is rejected ... ok
request: invalid values are reported per field ... ok
request: unknown keys and non-objects are rejected ... ok
localDateIn: converts an instant to the calendar date of the zone ... ok
localDateIn: an unknown zone throws ... ok
report: counts open, overdue, on-time and late orders per technician ... ok
report: lists every technician, even without work, and members with assignments ... ok
report: an empty range gives zero counts and null rates ... ok
report: the on-time rate is rounded to one decimal ... ok
report: "today" and overdue follow the unit zone, not UTC ... ok
report: a duplicated assignee id is counted once ... ok
report: inconsistent data is refused instead of miscounted ... ok
csv: header, one line per row, then unassigned and total ... ok
csv: quotes separators and neutralises spreadsheet formulas ... ok
ok | 16 passed | 0 failed
```

We also called the function by hand. Each case returned the documented status:

- 200 for office, as JSON and as CSV
- 403 for a technician
- 404 for an admin of the other unit
- 400 for an invalid body and for broken JSON
- 401 with no token
- 405 for `GET`
- 204 with CORS headers for `OPTIONS`

### Hosted Supabase run (12 Nov 2026)

We also deployed the sample to a fresh hosted Supabase project (Postgres 17,
EU region), created only for this check. The commands were:

```bash
supabase link --project-ref <ref>
supabase db push --remote --include-seed
supabase functions deploy work-order-report
supabase test db --remote
supabase db advisors --remote
```

Results:

- **pgTAP:** 36/36 tests passed against the hosted database (12 Nov 2026,
  before the last-admin deletion test was added).
- **Advisors:** no findings for the schema (RLS, `security definer`
  functions, `search_path`, foreign-key indexes). The only warning was the
  project-level Auth setting "Leaked password protection", which is not part
  of the code.
- **Edge Function:** called as each role, it returned the same statuses as
  locally: 200 JSON and CSV for office, 403 for a technician, 404 for the
  other unit's admin, 400 for an invalid body, 401 without a token, and 204
  for `OPTIONS`.
- **RLS over the REST API:**
  - a technician sees only their 3 orders, and office sees all 5 of its unit;
  - `anon` gets `permission denied`;
  - a technician renaming their own order gets 403 from the trigger;
  - the `private` helper functions are not reachable as RPCs.

## Stack and versions

| | Version |
| --- | --- |
| Supabase CLI | 3.0.0 |
| PostgreSQL | 17.11 (`supabase/postgres:17.11.0.011`) |
| Edge Runtime | v1.77.9 (Deno 2) |
| Deno (tests) | 2.9.8 |
| `@supabase/supabase-js` | 2.118.0 |
| `zod` | 4.6.7 |
| `@std/assert` | 1.0.14 |
| pgTAP runner | `supabase/pg_prove:3.36` |

## How we work with Claude Code

`CLAUDE.md` in this repository is the rule file we would start from on your
project. On a real project we would merge it into your existing `CLAUDE.md`
and data-model notes, not replace them. The workflow:

1. **Plan before code.** For anything beyond a one-file fix, Claude first reads
   the relevant rules and schema and proposes the tables, policies and
   function contract. A developer approves that before any code is written.
2. **Tests define done.** The pgTAP cases for a policy are written along with
   the policy. Every rule in the access table above has at least one test that
   proves the allowed case and one that proves the denied case. A test only
   counts once we have seen it fail. The mutation check above is how we prove
   that.
3. **Verify, don't trust.** No change is reported as done until
   `supabase db reset`, `supabase test db`, `deno test`, `deno lint` and
   `deno fmt --check` have passed. Their output goes into the PR.
4. **Human review on every PR.** A second developer reviews every AI-assisted
   PR against `CLAUDE.md`, with extra attention to RLS, `security definer`
   functions and anything that touches money or personal data.
5. **Small PRs.** One migration or one function change per PR, so each review
   stays readable.

## CI and AI workflow

**CI** — `.github/workflows/ci.yml`, on every pull request and on push to
`main`. A red run means the task is not finished. Two jobs run in parallel:

- **Deno:** `deno lint`, `deno fmt --check`, `deno check` of every function,
  `deno test`.
- **Database:** `supabase start` (Postgres, Auth and postgres-meta only),
  `supabase db reset`, `supabase test db`, and a drift check: types generated
  from the migrated schema must equal the committed
  `supabase/functions/_shared/database.types.ts`.

Versions are pinned: Supabase CLI 3.0.0, Deno 2.9.8, actions by release tag.

**AI review** — `.github/workflows/claude-review.yml` runs
[`anthropics/claude-code-action`](https://github.com/anthropics/claude-code-action)
on every pull request. Claude reviews the diff against `CLAUDE.md` and posts
each finding as an inline comment marked `high`, `medium` or `low`, plus one
summary comment. A `high` finding fails the job, so the PR is blocked until it
is fixed. The job needs the repository secret `CLAUDE_CODE_OAUTH_TOKEN` (from
`claude setup-token`; it runs on the team's Claude subscription). A human
review is still required.

**Claude Code project config** — committed, so every developer's Claude
session follows the same rules:

- `.claude/settings.json` hooks:
  - before an edit, `guard-applied-migration.sh` blocks changes to a
    migration that is already committed (`CLAUDE.md`: an applied migration is
    immutable) and tells Claude to add a new one;
  - after an edit, `after-edit.sh` runs `deno fmt` and `deno lint` on a
    changed `.ts` file and sends lint errors back to Claude. After a change to
    a migration or a pgTAP test it reminds Claude to run `supabase test db`,
    regenerate the types and update the README counts.
- `.claude/settings.json` permissions: the check commands run without a
  prompt; `supabase db push`, `functions deploy`, `secrets` and `link` are
  denied, and so is reading `.env`.
- `.mcp.json`: the Supabase MCP server in read-only mode
  (`read_only=true`), scoped to one project. Set `SUPABASE_PROJECT_REF`; login
  is OAuth, so no token is stored in the repository.

The hooks need `jq` and `deno` on the developer's machine.

## Notes and limits

- **Business units have no INSERT or DELETE policy on purpose.** They are
  provisioned by the platform (the service role, or the seed locally), not by
  tenant users.
- **Orders without a `due_on` are not in the report.** The report is by due
  date.
- **The 1000-row limit equals `max_rows` in `config.toml`.** For larger units
  the next step would be paging or a SQL aggregate function. We kept the
  calculation in TypeScript so it stays readable and unit-testable.
- **The demo setup step needs Docker.** It uses `docker exec` because the
  Supabase CLI does not ship a `psql` client. A local `psql` against
  `postgresql://postgres:postgres@127.0.0.1:54322/postgres` works the same way.
