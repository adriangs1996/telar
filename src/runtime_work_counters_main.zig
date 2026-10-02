//! Exact runtime work counts over an idle runtime with known clients and
//! panes. The counters compile only into a root that opts into profile
//! counts and a Zig test runner never does, so this program is that root:
//! `zig build test-runtime-work-counters`. A mismatch prints every differing
//! metric and exits nonzero.
const backend = @import("telar-backend");
const core = @import("telar-core");
const std = @import("std");

// These names are the root-level opt-in contracts read by core through @hasDecl.
pub const telar_profile_counts = true;
pub var profile_store: core.ProfileStore = .{};

const IdleDelivery = backend.IdleDelivery;
const Runtime = backend.Runtime;
const RuntimeModel = @FieldType(Runtime, "model");
const Metric = core.profiling.Metric;
const Counters = core.ProfileCounters;

/// Two clients attach the same three panes, so a count per client differs
/// from a count per pane or per attachment.
const clients = 2;
const panes = 3;
const idle_flushes = 8;
const pane_size: core.TerminalSize = .{
    .cols = 80,
    .rows = 24,
};

const event_metric_prefix = "runtime_event_";

/// The lanes a title change passes through, in delivery order, when no
/// other lane publishes for its attachment.
const TitleLane = enum { cells, cwd, foreground, title };

/// A pending cell snapshot publishes in the first lane.
const SnapshotLane = enum { cells };

/// The work one fixture expects, named as its metric. A null count is not
/// checked.
const ExpectedWork = struct {
    runtime_flush: ?u64 = null,
    runtime_flush_passes: ?u64 = null,
    runtime_pane_slots: ?u64 = null,
    runtime_live_panes: ?u64 = null,
    runtime_prepare: ?u64 = null,
    runtime_pending_scans: ?u64 = null,
    runtime_attachment_slots: ?u64 = null,
    runtime_eligibility_checks: ?u64 = null,
    runtime_eligible_attachments: ?u64 = null,
    runtime_lane_offers: ?u64 = null,
    runtime_foreground_slots: ?u64 = null,
    runtime_commits: ?u64 = null,
    runtime_attachment_commits: ?u64 = null,
    runtime_cell_commits: ?u64 = null,
};

/// Runs every fixture against one runtime, in order; each starts from the
/// state the previous one left. Example: `runtime-work-counters`.
pub fn main(init: std.process.Init) !void {
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = try std.fmt.bufPrint(&directory_buffer, "/tmp/telar-work-counters-{d}", .{std.c.getpid()});
    try std.Io.Dir.cwd().createDirPath(init.io, directory);
    defer std.Io.Dir.cwd().deleteTree(init.io, directory) catch {};

    var idle: IdleDelivery = undefined;
    try idle.init(
        .{
            .io = init.io,
            .allocator = init.gpa,
        },
        .{
            .clients = clients,
            .panes = panes,
            .directory = directory,
            .environment = init.minimal.environ,
            .size = pane_size,
        },
    );
    defer idle.deinit();

    if (idle.runtime.model.panes.count != panes) {
        return error.UnexpectedPaneCount;
    }

    try countIdleFlushes(&idle);
    try countProductiveFlush(&idle);
    try countFlushWhileSending(&idle);
    try countRuntimeEvents(&idle);

    std.debug.print("runtime work counters: 4 fixtures matched\n", .{});
}

/// Idle flushes ask every attachment and offer no lane: the scans alone.
fn countIdleFlushes(idle: *IdleDelivery) !void {
    const model = &idle.runtime.model;
    const pane_slots = paneSlots(model);
    const before = core.profiling.snapshot();
    for (0..idle_flushes) |_| {
        try idle.flush();
    }

    const after = core.profiling.snapshot();
    if (!idle.quiet()) {
        return error.IdleFlushStartedWrite;
    }

    const prepares = idle_flushes * clients;
    try expectWork(&before, &after, .{
        .runtime_flush = idle_flushes,
        .runtime_flush_passes = idle_flushes,
        .runtime_pane_slots = idle_flushes * pane_slots,
        .runtime_live_panes = idle_flushes * panes,
        .runtime_prepare = prepares,
        .runtime_pending_scans = prepares,
        .runtime_attachment_slots = prepares * attachmentSlots(model),
        .runtime_eligibility_checks = prepares * panes,
        .runtime_eligible_attachments = 0,
        .runtime_lane_offers = 0,
        .runtime_foreground_slots = prepares * pane_slots,
        .runtime_commits = 0,
        .runtime_attachment_commits = 0,
        .runtime_cell_commits = 0,
    });
}

/// One title change reaches both clients' attachments to the first pane,
/// and the second client also owes that attachment a cell snapshot. The
/// first client offers it to every lane up to the title's; the second
/// delivers the snapshot at its first offer. Each client starts one write.
fn countProductiveFlush(idle: *IdleDelivery) !void {
    const model = &idle.runtime.model;
    const pane_slots = paneSlots(model);
    const pane = for (model.panes.items) |slot| {
        if (slot) |found| {
            break found;
        }
    } else return error.MissingPane;

    if (!pane.title.observe("work counters")) {
        return error.TitleUnchanged;
    }

    const slots = try clientSlots(model);
    const attachment = model.attachments.find(slots[1], pane.id) orelse return error.MissingAttachment;
    attachment.requestCellSnapshot();

    const before = core.profiling.snapshot();
    try idle.flush();
    const after = core.profiling.snapshot();

    try expectWork(&before, &after, .{
        .runtime_flush = 1,
        .runtime_flush_passes = 1,
        .runtime_pane_slots = pane_slots,
        .runtime_live_panes = panes,
        .runtime_prepare = clients,
        .runtime_pending_scans = clients,
        .runtime_attachment_slots = clients * attachmentSlots(model),
        .runtime_eligibility_checks = clients * panes,
        .runtime_eligible_attachments = clients,
        .runtime_lane_offers = std.enums.values(TitleLane).len + std.enums.values(SnapshotLane).len,
        .runtime_foreground_slots = pane_slots,
        .runtime_commits = clients,
        .runtime_attachment_commits = clients,
        .runtime_cell_commits = 1,
    });
}

/// A client whose write is in flight is never prepared; the pane pass
/// still visits every slot.
fn countFlushWhileSending(idle: *IdleDelivery) !void {
    const model = &idle.runtime.model;
    const pane_slots = paneSlots(model);
    const before = core.profiling.snapshot();
    try idle.flush();
    const after = core.profiling.snapshot();

    try expectWork(&before, &after, .{
        .runtime_flush = 1,
        .runtime_flush_passes = 1,
        .runtime_pane_slots = pane_slots,
        .runtime_live_panes = panes,
        .runtime_prepare = 0,
        .runtime_pending_scans = 0,
        .runtime_attachment_slots = 0,
        .runtime_eligibility_checks = 0,
        .runtime_eligible_attachments = 0,
        .runtime_lane_offers = 0,
        .runtime_foreground_slots = 0,
        .runtime_commits = 0,
        .runtime_attachment_commits = 0,
        .runtime_cell_commits = 0,
    });
}

/// Passes the runtime loop's own events to `Runtime.update` until both
/// writes complete. Timer and worker events may arrive in between, so the
/// fixture tallies every event it passes and the counters match the tally.
fn countRuntimeEvents(idle: *IdleDelivery) !void {
    const runtime = idle.runtime;
    const model = &runtime.model;
    var seen: [std.enums.values(Metric).len]u64 = @splat(0);
    var updates: u64 = 0;
    var completed_writes: usize = 0;
    const before = core.profiling.snapshot();
    while (completed_writes < clients) {
        const event = try runtime.loop.next();
        if (event == .client_sent) {
            completed_writes += 1;
        }

        seen[@intFromEnum(eventMetric(event))] += 1;
        updates += 1;
        if (try runtime.update(event)) {
            return error.RuntimeStopped;
        }
    }

    const after = core.profiling.snapshot();
    var failed = false;
    for (std.enums.values(Metric)) |metric| {
        if (!std.mem.startsWith(u8, @tagName(metric), event_metric_prefix)) {
            continue;
        }

        failed = !matches(
            &before,
            &after,
            metric,
            seen[@intFromEnum(metric)],
        ) or failed;
    }

    if (failed) {
        return error.WorkCountMismatch;
    }

    // No stop arrived, so every update flushed once.
    const scans = delta(&before, &after, .runtime_pending_scans);
    const checks = delta(&before, &after, .runtime_eligibility_checks);
    try expectWork(&before, &after, .{
        .runtime_flush = updates,
        .runtime_flush_passes = updates,
        .runtime_pane_slots = updates * paneSlots(model),
        .runtime_live_panes = updates * panes,
        .runtime_attachment_slots = scans * attachmentSlots(model),
        .runtime_eligibility_checks = scans * panes,
    });

    if (delta(&before, &after, .runtime_eligible_attachments) > checks or
        delta(&before, &after, .runtime_attachment_commits) > delta(&before, &after, .runtime_commits) or
        delta(&before, &after, .runtime_cell_commits) > delta(&before, &after, .runtime_attachment_commits))
    {
        return error.WorkCountOrder;
    }
}

/// The metric `Runtime.update` counts an event under, named independently
/// of the runtime so a renamed metric fails here as well.
fn eventMetric(event: anytype) Metric {
    return switch (std.meta.activeTag(event)) {
        inline else => |tag| @field(Metric, event_metric_prefix ++ @tagName(tag)),
    };
}

fn clientSlots(model: *RuntimeModel) ![clients]usize {
    var slots: [clients]usize = undefined;
    var found: usize = 0;
    for (model.clients.items) |entry| {
        const session = entry orelse continue;
        if (found == clients) {
            return error.UnexpectedClientCount;
        }

        slots[found] = session.slot;
        found += 1;
    }

    if (found != clients) {
        return error.UnexpectedClientCount;
    }

    return slots;
}

fn paneSlots(model: *const RuntimeModel) u64 {
    return model.panes.items.len;
}

fn attachmentSlots(model: *const RuntimeModel) u64 {
    return model.attachments.record[0].len;
}

fn delta(before: *const Counters, after: *const Counters, metric: Metric) u64 {
    return after.values[@intFromEnum(metric)] - before.values[@intFromEnum(metric)];
}

fn matches(before: *const Counters, after: *const Counters, metric: Metric, expected: u64) bool {
    const counted = delta(before, after, metric);
    if (counted == expected) {
        return true;
    }

    std.debug.print(
        "{s}: expected {d}, counted {d}\n",
        .{ @tagName(metric), expected, counted },
    );
    return false;
}

fn expectWork(before: *const Counters, after: *const Counters, expected: ExpectedWork) !void {
    var failed = false;
    inline for (std.meta.fields(ExpectedWork)) |field| {
        if (@field(expected, field.name)) |count| {
            failed = !matches(
                before,
                after,
                @field(Metric, field.name),
                count,
            ) or failed;
        }
    }

    if (failed) {
        return error.WorkCountMismatch;
    }
}
