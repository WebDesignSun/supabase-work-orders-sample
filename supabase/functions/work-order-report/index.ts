// POST /functions/v1/work-order-report
//
// Workload report of a business unit's technicians for a due-date range:
// assigned / open / overdue / done on time / done late per technician, as JSON
// or CSV. For office staff and admins of that unit.
//
// This file is the HTTP shell only: CORS, auth, validation, role check and the
// three database reads. The calculation lives in logic.ts.
//
// Every query runs with the caller's JWT, never the service role, so RLS
// applies to the report exactly as it does to the app.

import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import type { Database } from '../_shared/database.types.ts';
import {
  buildWorkloadReport,
  describeIssues,
  MAX_WORK_ORDERS,
  type MemberRole,
  REPORT_ROLES,
  type ReportRequest,
  reportRequestSchema,
  toCsv,
  type ValidationIssue,
  type WorkOrderInfo,
} from './logic.ts';

type Client = SupabaseClient<Database>;

const CORS_HEADERS: Record<string, string> = {
  // The function authenticates with a bearer token, not cookies, so a wildcard
  // is safe; set ALLOWED_ORIGIN to pin it to the app's origin.
  'Access-Control-Allow-Origin': Deno.env.get('ALLOWED_ORIGIN') ?? '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

/** An error whose message is safe to show to the caller. */
class HttpError extends Error {
  constructor(
    readonly status: number,
    message: string,
    readonly issues?: ValidationIssue[],
  ) {
    super(message);
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  try {
    return await handle(req);
  } catch (error) {
    if (error instanceof HttpError) {
      return json(error.status, { error: error.message, issues: error.issues });
    }
    // Details go to the function log only, never to the caller.
    console.error('work-order-report failed', error);
    return json(500, { error: 'Internal server error' });
  }
});

async function handle(req: Request): Promise<Response> {
  if (req.method !== 'POST') throw new HttpError(405, 'Method not allowed');

  const token = bearerToken(req);
  const supabase = createClient<Database>(env('SUPABASE_URL'), env('SUPABASE_ANON_KEY'), {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });

  const { data: auth, error: authError } = await supabase.auth.getUser(token);
  if (authError || !auth.user) throw new HttpError(401, 'Invalid or expired token');

  const request = await parseBody(req);

  const role = await callerRole(supabase, request.businessUnitId, auth.user.id);
  // Not a member: answer as if the unit did not exist, so ids cannot be probed.
  if (role === null) throw new HttpError(404, 'Business unit not found');
  if (!REPORT_ROLES.includes(role)) {
    throw new HttpError(403, 'Only office staff and admins can export this report');
  }

  const [unit, members, workOrders] = await Promise.all([
    loadUnit(supabase, request.businessUnitId),
    loadMembers(supabase, request.businessUnitId),
    loadWorkOrders(supabase, request),
  ]);

  const report = buildWorkloadReport({
    unit,
    from: request.from,
    to: request.to,
    now: new Date(),
    members,
    workOrders,
  });

  if (request.format === 'csv') {
    return new Response(toCsv(report), {
      status: 200,
      headers: {
        ...CORS_HEADERS,
        'Content-Type': 'text/csv; charset=utf-8',
        'Content-Disposition':
          `attachment; filename="work-orders_${request.from}_${request.to}.csv"`,
      },
    });
  }
  return json(200, report);
}

function bearerToken(req: Request): string {
  const header = req.headers.get('Authorization') ?? '';
  const match = /^Bearer (\S+)$/.exec(header);
  if (!match) throw new HttpError(401, 'Missing bearer token');
  return match[1];
}

async function parseBody(req: Request): Promise<ReportRequest> {
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    throw new HttpError(400, 'Request body must be valid JSON');
  }
  const parsed = reportRequestSchema.safeParse(body);
  if (!parsed.success) {
    throw new HttpError(400, 'Invalid request', describeIssues(parsed.error));
  }
  return parsed.data;
}

async function callerRole(
  supabase: Client,
  businessUnitId: string,
  userId: string,
): Promise<MemberRole | null> {
  const { data, error } = await supabase
    .from('memberships')
    .select('role')
    .eq('business_unit_id', businessUnitId)
    .eq('user_id', userId)
    .maybeSingle();
  if (error) throw error;
  return data?.role ?? null;
}

async function loadUnit(supabase: Client, businessUnitId: string) {
  const { data, error } = await supabase
    .from('business_units')
    .select('id, name, timezone')
    .eq('id', businessUnitId)
    .single();
  if (error) throw error;
  return data;
}

async function loadMembers(supabase: Client, businessUnitId: string) {
  const { data, error } = await supabase
    .from('memberships')
    .select('user_id, role, display_name')
    .eq('business_unit_id', businessUnitId);
  if (error) throw error;
  return data.map((m) => ({ userId: m.user_id, role: m.role, displayName: m.display_name }));
}

/** One query for the orders and their assignees (embedded), no per-order reads. */
async function loadWorkOrders(supabase: Client, request: ReportRequest): Promise<WorkOrderInfo[]> {
  const { data, count, error } = await supabase
    .from('work_orders')
    .select('id, status, due_on, completed_at, work_order_assignees(user_id)', { count: 'exact' })
    .eq('business_unit_id', request.businessUnitId)
    .gte('due_on', request.from)
    .lte('due_on', request.to)
    .order('due_on')
    .order('id')
    .limit(MAX_WORK_ORDERS);
  if (error) throw error;

  // Refuse rather than return a report silently cut at the row limit.
  if ((count ?? 0) > MAX_WORK_ORDERS) {
    throw new HttpError(
      422,
      `More than ${MAX_WORK_ORDERS} work orders are due in this range; choose a shorter range`,
    );
  }

  return data.flatMap((order) =>
    // The range filter already excludes orders without a due date.
    order.due_on === null ? [] : [{
      id: order.id,
      status: order.status,
      dueOn: order.due_on,
      completedAt: order.completed_at,
      assigneeIds: order.work_order_assignees.map((a) => a.user_id),
    }]
  );
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
}

function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing environment variable ${name}`);
  return value;
}
