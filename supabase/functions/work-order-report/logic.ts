// Pure business logic of the work-order report: request validation, the
// per-technician workload calculation and CSV export. No I/O, no Deno APIs,
// no Supabase client: everything here is covered by logic_test.ts.

import { z } from 'zod';
import type { Database } from '../_shared/database.types.ts';

type Enums = Database['public']['Enums'];
export type MemberRole = Enums['member_role'];
export type WorkOrderStatus = Enums['work_order_status'];

/** Roles allowed to export the report. Technicians only see their own orders. */
export const REPORT_ROLES: readonly MemberRole[] = ['admin', 'office'];

/** Longest due-date range one report may cover, both ends inclusive. */
export const MAX_RANGE_DAYS = 92;

/** Must equal `[api] max_rows` in supabase/config.toml. */
export const MAX_WORK_ORDERS = 1000;

const DAY_MS = 86_400_000;

// ---------------------------------------------------------------------------
// Request
// ---------------------------------------------------------------------------

const isoDate = z.iso.date({ error: 'Expected a calendar date as YYYY-MM-DD' });

export const reportRequestSchema = z
  .strictObject({
    businessUnitId: z.uuid({ error: 'Expected a UUID' }),
    from: isoDate,
    to: isoDate,
    format: z.enum(['json', 'csv']).default('json'),
  })
  .superRefine((value, ctx) => {
    const span = daysBetween(value.from, value.to);
    if (span < 0) {
      ctx.addIssue({
        code: 'custom',
        path: ['to'],
        message: '`to` must not be before `from`',
      });
    } else if (span + 1 > MAX_RANGE_DAYS) {
      ctx.addIssue({
        code: 'custom',
        path: ['to'],
        message: `The range may span at most ${MAX_RANGE_DAYS} days`,
      });
    }
  });

export type ReportRequest = z.infer<typeof reportRequestSchema>;

export interface ValidationIssue {
  path: string;
  message: string;
}

/** Client-safe description of what is wrong with a request body. */
export function describeIssues(error: z.ZodError): ValidationIssue[] {
  return error.issues.map((issue) => ({
    path: issue.path.map(String).join('.'),
    message: issue.message,
  }));
}

function daysBetween(from: string, to: string): number {
  return (Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / DAY_MS;
}

// ---------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------

export interface UnitInfo {
  id: string;
  name: string;
  /** IANA zone id; due dates are calendar dates in this zone. */
  timezone: string;
}

export interface MemberInfo {
  userId: string;
  displayName: string;
  role: MemberRole;
}

export interface WorkOrderInfo {
  id: string;
  status: WorkOrderStatus;
  /** Local calendar date, YYYY-MM-DD. */
  dueOn: string;
  /** ISO instant, set exactly when status is 'done'. */
  completedAt: string | null;
  assigneeIds: readonly string[];
}

export interface WorkloadCounts {
  assigned: number;
  /** Not done yet, overdue ones included. */
  open: number;
  /** Not done and due before today (in the unit's zone). */
  overdue: number;
  done: number;
  /** Completed on or before the due date (in the unit's zone). */
  doneOnTime: number;
  doneLate: number;
  /** doneOnTime / done, one decimal; null when nothing is done. */
  onTimeRatePercent: number | null;
}

export interface WorkloadRow extends WorkloadCounts {
  userId: string;
  displayName: string;
  role: MemberRole;
}

export interface WorkloadReport {
  businessUnit: UnitInfo;
  from: string;
  to: string;
  /** "Today" in the unit's zone; the reference point for `overdue`. */
  today: string;
  generatedAt: string;
  /** Every technician, plus any other member with an assignment in range. */
  rows: WorkloadRow[];
  unassigned: WorkloadCounts;
  /** Per work order, so an order with two assignees is counted once. */
  totals: WorkloadCounts;
}

export interface WorkloadInput {
  unit: UnitInfo;
  from: string;
  to: string;
  now: Date;
  members: readonly MemberInfo[];
  workOrders: readonly WorkOrderInfo[];
}

type Outcome = 'open' | 'overdue' | 'onTime' | 'late';
type Tally = Omit<WorkloadCounts, 'onTimeRatePercent'>;

/**
 * Returns a formatter from an instant to its calendar date (YYYY-MM-DD) in
 * `timeZone`. Throws RangeError for an unknown zone.
 */
export function localDateIn(timeZone: string): (instant: Date) => string {
  const format = new Intl.DateTimeFormat('en-CA', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  });
  return (instant) => {
    const parts = format.formatToParts(instant);
    const part = (type: Intl.DateTimeFormatPartTypes): string =>
      parts.find((p) => p.type === type)?.value ?? '';
    return `${part('year')}-${part('month')}-${part('day')}`;
  };
}

export function buildWorkloadReport(input: WorkloadInput): WorkloadReport {
  const localDate = localDateIn(input.unit.timezone);
  const today = localDate(input.now);

  const membersById = new Map(input.members.map((m) => [m.userId, m]));
  const tallies = new Map<string, Tally>();
  for (const member of input.members) {
    if (member.role === 'technician') tallies.set(member.userId, emptyTally());
  }
  const unassigned = emptyTally();
  const totals = emptyTally();

  for (const order of input.workOrders) {
    const outcome = classify(order, today, localDate);
    record(totals, outcome);
    if (order.assigneeIds.length === 0) record(unassigned, outcome);

    for (const userId of new Set(order.assigneeIds)) {
      if (!membersById.has(userId)) {
        // The membership foreign key on work_order_assignees rules this out.
        throw new Error(`Assignee ${userId} of work order ${order.id} is not a member`);
      }
      let tally = tallies.get(userId);
      if (!tally) {
        tally = emptyTally();
        tallies.set(userId, tally);
      }
      record(tally, outcome);
    }
  }

  const rows = [...tallies.entries()]
    .map(([userId, tally]): WorkloadRow => {
      const member = membersById.get(userId);
      if (!member) throw new Error(`Unknown member ${userId}`);
      return {
        userId,
        displayName: member.displayName,
        role: member.role,
        ...withRate(tally),
      };
    })
    .sort(
      (a, b) =>
        a.displayName.localeCompare(b.displayName, 'de') || a.userId.localeCompare(b.userId),
    );

  return {
    businessUnit: input.unit,
    from: input.from,
    to: input.to,
    today,
    generatedAt: input.now.toISOString(),
    rows,
    unassigned: withRate(unassigned),
    totals: withRate(totals),
  };
}

function classify(
  order: WorkOrderInfo,
  today: string,
  localDate: (instant: Date) => string,
): Outcome {
  if (order.status !== 'done') {
    return order.dueOn < today ? 'overdue' : 'open';
  }
  if (order.completedAt === null) {
    // The work_orders_completed_at_matches_status check rules this out.
    throw new Error(`Work order ${order.id} is done but has no completion time`);
  }
  // ISO dates compare correctly as strings.
  return localDate(new Date(order.completedAt)) <= order.dueOn ? 'onTime' : 'late';
}

function emptyTally(): Tally {
  return { assigned: 0, open: 0, overdue: 0, done: 0, doneOnTime: 0, doneLate: 0 };
}

function record(tally: Tally, outcome: Outcome): void {
  tally.assigned += 1;
  switch (outcome) {
    case 'overdue':
      tally.overdue += 1;
      tally.open += 1;
      break;
    case 'open':
      tally.open += 1;
      break;
    case 'onTime':
      tally.done += 1;
      tally.doneOnTime += 1;
      break;
    case 'late':
      tally.done += 1;
      tally.doneLate += 1;
      break;
  }
}

function withRate(tally: Tally): WorkloadCounts {
  return {
    ...tally,
    onTimeRatePercent: tally.done === 0
      ? null
      : Math.round((tally.doneOnTime / tally.done) * 1000) / 10,
  };
}

// ---------------------------------------------------------------------------
// CSV export
// ---------------------------------------------------------------------------

const CSV_HEADER = [
  'technician',
  'role',
  'assigned',
  'open',
  'overdue',
  'done',
  'done_on_time',
  'done_late',
  'on_time_rate_percent',
] as const;

/** RFC 4180 CSV (comma, CRLF): one line per row, then unassigned and total. */
export function toCsv(report: WorkloadReport): string {
  const line = (name: string, role: string, c: WorkloadCounts): string =>
    [
      name,
      role,
      c.assigned,
      c.open,
      c.overdue,
      c.done,
      c.doneOnTime,
      c.doneLate,
      c.onTimeRatePercent,
    ]
      .map(csvCell)
      .join(',');

  return [
    CSV_HEADER.join(','),
    ...report.rows.map((row) => line(row.displayName, row.role, row)),
    line('(unassigned)', '', report.unassigned),
    line('(total)', '', report.totals),
  ]
    .map((l) => `${l}\r\n`)
    .join('');
}

/**
 * Quotes a cell when needed and neutralises spreadsheet formulas: a text cell
 * starting with = + - @ or a control character is prefixed with an apostrophe,
 * so a display name like "=HYPERLINK(...)" is shown, not executed.
 */
export function csvCell(value: string | number | null): string {
  if (value === null) return '';
  let text = String(value);
  if (typeof value === 'string' && /^[=+\-@\t\r]/.test(text)) text = `'${text}`;
  return /[",\r\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
}
