import { assertEquals, assertThrows } from '@std/assert';
import {
  buildWorkloadReport,
  csvCell,
  describeIssues,
  localDateIn,
  MAX_RANGE_DAYS,
  type MemberInfo,
  reportRequestSchema,
  toCsv,
  type WorkloadCounts,
  type WorkloadInput,
  type WorkloadRow,
  type WorkOrderInfo,
} from './logic.ts';

const UNIT_ID = 'a0000000-0000-4000-8000-000000000001';
const BEN = '10000000-0000-4000-8000-000000000003';
const CLARA = '10000000-0000-4000-8000-000000000004';
const OLIVIA = '10000000-0000-4000-8000-000000000002';

const MEMBERS: MemberInfo[] = [
  { userId: OLIVIA, displayName: 'Olivia Office', role: 'office' },
  { userId: CLARA, displayName: 'Clara Technician', role: 'technician' },
  { userId: BEN, displayName: 'Ben Technician', role: 'technician' },
];

let orderSeq = 0;
function order(overrides: Partial<WorkOrderInfo>): WorkOrderInfo {
  orderSeq += 1;
  return {
    id: `order-${orderSeq}`,
    status: 'not_started',
    dueOn: '2026-11-20',
    completedAt: null,
    assigneeIds: [],
    ...overrides,
  };
}

function input(workOrders: WorkOrderInfo[], overrides: Partial<WorkloadInput> = {}): WorkloadInput {
  return {
    unit: { id: UNIT_ID, name: 'Crew North', timezone: 'Europe/Berlin' },
    from: '2026-11-01',
    to: '2026-11-30',
    // 12 Nov 2026, 10:00 in Berlin.
    now: new Date('2026-11-12T09:00:00Z'),
    members: MEMBERS,
    workOrders,
    ...overrides,
  };
}

function countsOf(row: WorkloadRow): WorkloadCounts {
  const { userId: _userId, displayName: _displayName, role: _role, ...counts } = row;
  return counts;
}

// ---------------------------------------------------------------------------
// Request validation
// ---------------------------------------------------------------------------

Deno.test('request: a valid body is accepted and format defaults to json', () => {
  const parsed = reportRequestSchema.parse({
    businessUnitId: UNIT_ID,
    from: '2026-11-01',
    to: '2026-11-30',
  });
  assertEquals(parsed.format, 'json');
});

Deno.test('request: a range of exactly MAX_RANGE_DAYS is accepted, one more day is not', () => {
  const ok = reportRequestSchema.safeParse({
    businessUnitId: UNIT_ID,
    from: '2026-01-01',
    to: '2026-04-02', // 92 days inclusive
  });
  assertEquals(ok.success, true);
  assertEquals(MAX_RANGE_DAYS, 92);

  const tooLong = reportRequestSchema.safeParse({
    businessUnitId: UNIT_ID,
    from: '2026-01-01',
    to: '2026-04-03',
  });
  assertEquals(tooLong.success, false);
  if (!tooLong.success) {
    assertEquals(describeIssues(tooLong.error), [
      { path: 'to', message: 'The range may span at most 92 days' },
    ]);
  }
});

Deno.test('request: `to` before `from` is rejected', () => {
  const result = reportRequestSchema.safeParse({
    businessUnitId: UNIT_ID,
    from: '2026-11-10',
    to: '2026-11-09',
  });
  assertEquals(result.success, false);
  if (!result.success) {
    assertEquals(describeIssues(result.error)[0].path, 'to');
  }
});

Deno.test('request: invalid values are reported per field', () => {
  const result = reportRequestSchema.safeParse({
    businessUnitId: 'not-a-uuid',
    from: '2026-02-30', // not a calendar date
    to: '30.11.2026',
    format: 'xlsx',
  });
  assertEquals(result.success, false);
  if (!result.success) {
    const paths = describeIssues(result.error).map((i) => i.path).sort();
    assertEquals(paths, ['businessUnitId', 'format', 'from', 'to']);
  }
});

Deno.test('request: unknown keys and non-objects are rejected', () => {
  assertEquals(
    reportRequestSchema.safeParse({
      businessUnitId: UNIT_ID,
      from: '2026-11-01',
      to: '2026-11-30',
      technicianId: BEN,
    }).success,
    false,
  );
  assertEquals(reportRequestSchema.safeParse(null).success, false);
  assertEquals(reportRequestSchema.safeParse([]).success, false);
});

// ---------------------------------------------------------------------------
// Local dates
// ---------------------------------------------------------------------------

Deno.test('localDateIn: converts an instant to the calendar date of the zone', () => {
  const berlin = localDateIn('Europe/Berlin');
  // Winter time (UTC+1): 23:30 UTC is already the next day in Berlin.
  assertEquals(berlin(new Date('2026-11-05T23:30:00Z')), '2026-11-06');
  assertEquals(berlin(new Date('2026-11-05T22:59:59Z')), '2026-11-05');
  // Summer time (UTC+2): the day changes at 22:00 UTC.
  assertEquals(berlin(new Date('2026-07-01T22:00:00Z')), '2026-07-02');
  assertEquals(localDateIn('UTC')(new Date('2026-07-01T22:00:00Z')), '2026-07-01');
});

Deno.test('localDateIn: an unknown zone throws', () => {
  assertThrows(() => localDateIn('Europe/Atlantis'), RangeError);
});

// ---------------------------------------------------------------------------
// Workload report
// ---------------------------------------------------------------------------

Deno.test('report: counts open, overdue, on-time and late orders per technician', () => {
  const report = buildWorkloadReport(input([
    // Ben: done on the due date (on time), due 3 Nov.
    order({
      status: 'done',
      dueOn: '2026-11-03',
      completedAt: '2026-11-03T14:10:00Z',
      assigneeIds: [BEN],
    }),
    // Ben: finished 00:30 Berlin on 6 Nov, due 5 Nov -> late, although the
    // UTC instant is still 5 Nov.
    order({
      status: 'done',
      dueOn: '2026-11-05',
      completedAt: '2026-11-05T23:30:00Z',
      assigneeIds: [BEN],
    }),
    // Ben + Clara: still working, due 10 Nov -> overdue for both.
    order({ status: 'working', dueOn: '2026-11-10', assigneeIds: [BEN, CLARA] }),
    // Clara: due today -> open, not overdue.
    order({ status: 'stuck', dueOn: '2026-11-12', assigneeIds: [CLARA] }),
    // Nobody: overdue and unassigned.
    order({ status: 'not_started', dueOn: '2026-11-02' }),
  ]));

  assertEquals(report.today, '2026-11-12');
  assertEquals(report.rows.map((r) => r.displayName), ['Ben Technician', 'Clara Technician']);

  const [ben, clara] = report.rows;
  assertEquals(
    countsOf(ben),
    {
      assigned: 3,
      open: 1,
      overdue: 1,
      done: 2,
      doneOnTime: 1,
      doneLate: 1,
      onTimeRatePercent: 50,
    },
  );
  assertEquals([clara.assigned, clara.open, clara.overdue, clara.done], [2, 2, 1, 0]);
  assertEquals(clara.onTimeRatePercent, null);

  assertEquals(report.unassigned.assigned, 1);
  assertEquals(report.unassigned.overdue, 1);

  // Totals count orders, not assignments: the shared order counts once.
  assertEquals(report.totals.assigned, 5);
  assertEquals(report.totals.overdue, 2);
  assertEquals(report.totals.done, 2);
});

Deno.test('report: lists every technician, even without work, and members with assignments', () => {
  const report = buildWorkloadReport(input([
    order({ status: 'working', dueOn: '2026-11-20', assigneeIds: [OLIVIA] }),
  ]));
  assertEquals(
    report.rows.map((r) => [r.displayName, r.role, r.assigned]),
    [
      ['Ben Technician', 'technician', 0],
      ['Clara Technician', 'technician', 0],
      ['Olivia Office', 'office', 1],
    ],
  );
});

Deno.test('report: an empty range gives zero counts and null rates', () => {
  const report = buildWorkloadReport(input([]));
  assertEquals(report.totals, {
    assigned: 0,
    open: 0,
    overdue: 0,
    done: 0,
    doneOnTime: 0,
    doneLate: 0,
    onTimeRatePercent: null,
  });
  assertEquals(report.rows.length, 2);
});

Deno.test('report: the on-time rate is rounded to one decimal', () => {
  const done = (completedAt: string) =>
    order({ status: 'done', dueOn: '2026-11-05', completedAt, assigneeIds: [BEN] });
  const report = buildWorkloadReport(input([
    done('2026-11-04T10:00:00Z'),
    done('2026-11-05T10:00:00Z'),
    done('2026-11-07T10:00:00Z'),
  ]));
  assertEquals(report.rows[0].onTimeRatePercent, 66.7);
});

Deno.test('report: "today" and overdue follow the unit zone, not UTC', () => {
  // 23:30 UTC on 11 Nov is already 12 Nov in Berlin, still 11 Nov in UTC.
  const now = new Date('2026-11-11T23:30:00Z');
  const orders = [order({ status: 'working', dueOn: '2026-11-11', assigneeIds: [BEN] })];

  const berlin = buildWorkloadReport(input(orders, { now }));
  assertEquals([berlin.today, berlin.totals.overdue], ['2026-11-12', 1]);

  const utc = buildWorkloadReport(
    input(orders, { now, unit: { id: UNIT_ID, name: 'Crew North', timezone: 'UTC' } }),
  );
  assertEquals([utc.today, utc.totals.overdue], ['2026-11-11', 0]);
});

Deno.test('report: a duplicated assignee id is counted once', () => {
  const report = buildWorkloadReport(input([
    order({ status: 'working', assigneeIds: [BEN, BEN] }),
  ]));
  assertEquals(report.rows[0].assigned, 1);
});

Deno.test('report: inconsistent data is refused instead of miscounted', () => {
  assertThrows(
    () => buildWorkloadReport(input([order({ assigneeIds: ['stranger'] })])),
    Error,
    'is not a member',
  );
  assertThrows(
    () => buildWorkloadReport(input([order({ status: 'done', completedAt: null })])),
    Error,
    'has no completion time',
  );
});

// ---------------------------------------------------------------------------
// CSV
// ---------------------------------------------------------------------------

Deno.test('csv: header, one line per row, then unassigned and total', () => {
  const report = buildWorkloadReport(input([
    order({
      status: 'done',
      dueOn: '2026-11-03',
      completedAt: '2026-11-03T10:00:00Z',
      assigneeIds: [BEN],
    }),
  ]));
  assertEquals(
    toCsv(report),
    [
      'technician,role,assigned,open,overdue,done,done_on_time,done_late,on_time_rate_percent',
      'Ben Technician,technician,1,0,0,1,1,0,100',
      'Clara Technician,technician,0,0,0,0,0,0,',
      '(unassigned),,0,0,0,0,0,0,',
      '(total),,1,0,0,1,1,0,100',
      '',
    ].join('\r\n'),
  );
});

Deno.test('csv: quotes separators and neutralises spreadsheet formulas', () => {
  assertEquals(csvCell('Müller, Jörg'), '"Müller, Jörg"');
  assertEquals(csvCell('Say "hi"'), '"Say ""hi"""');
  assertEquals(csvCell('=HYPERLINK("http://x")'), `"'=HYPERLINK(""http://x"")"`);
  assertEquals(csvCell('@SUM(A1)'), "'@SUM(A1)");
  assertEquals(csvCell('-1+2'), "'-1+2");
  assertEquals(csvCell(-1), '-1'); // numbers are not text, nothing to neutralise
  assertEquals(csvCell(null), '');
});
