const std = @import("std");
const core = @import("telar-core");
const ClientKey = @import("../../history/ClientKey.zig");
const PaneKey = @import("../../pane/PaneKey.zig");
const HistoryOptions = @import("../../agent_panes/HistoryOptions.zig");
const ProviderHistory = @import("../../agent_panes/ProviderHistory.zig");
const OwnedPage = @import("../delivery/OwnedAgentHistoryPage.zig");
const Init = @import("AgentHistoryJobInit.zig");
const Job = @This();

gpa: std.mem.Allocator,
client: ClientKey,
pane: PaneKey,
request_id: core.RequestId,
view_generation: u64,
direction: core.agent_history.Direction,
cursor: core.AgentHistoryCursor,
anchor: core.AgentHistoryCursor,
anchor_turn: [128]u8 = undefined,
anchor_turn_len: u8 = 0,
thread_id: [128]u8 = undefined,
thread_id_len: u8,
options: *HistoryOptions,
result: ?*OwnedPage = null,
failure: ?anyerror = null,

/// Copies bounded authority and retains immutable provider configuration without allocating.
/// Example: `job.* = try Job.init(gpa, input);`.
pub fn init(gpa: std.mem.Allocator, input: Init) !Job {
    const thread_id = input.thread_id;
    if (thread_id.len == 0 or thread_id.len > 128) {
        return error.AgentNotReady;
    }
    if (input.request.anchor_turn.len > 128) {
        return error.InvalidHistoryCursor;
    }

    const cursor = try core.AgentHistoryCursor.init(input.request.cursor);
    const anchor = try core.AgentHistoryCursor.init(input.request.anchor);
    var job: Job = .{
        .gpa = gpa,
        .client = input.client,
        .pane = input.pane,
        .request_id = input.request.request_id,
        .view_generation = input.request.view_generation,
        .direction = input.request.direction,
        .cursor = cursor,
        .anchor = anchor,
        .anchor_turn_len = @intCast(input.request.anchor_turn.len),
        .thread_id_len = @intCast(thread_id.len),
        .options = input.options.retain(),
    };
    @memcpy(job.thread_id[0..thread_id.len], thread_id);
    @memcpy(job.anchor_turn[0..input.request.anchor_turn.len], input.request.anchor_turn);
    return job;
}

/// Runs only with owned data; closing a pane never invalidates this reader.
/// Example: `try select.concurrent(.agent_history_completed, Job.run, .{ job, io });`.
pub fn run(job: *Job, io: std.Io) *Job {
    const path = core.enter(.observation);
    defer path.restore();
    const page = ProviderHistory.read(io, job.gpa, .{
        .options = job.options,
        .query = job.query(),
        .thread_id = job.thread_id[0..job.thread_id_len],
    }) catch |err| {
        job.failure = err;
        return job;
    };
    const owned = job.gpa.create(OwnedPage) catch |err| {
        job.gpa.destroy(page);
        job.failure = err;
        return job;
    };
    owned.* = .{ .gpa = job.gpa, .value = page };
    job.result = owned;
    return job;
}

/// Releases a joined job, including a completion discarded during shutdown.
/// Example: `job.deinit();`.
pub fn deinit(job: *Job) void {
    if (job.result) |result| {
        result.deinit();
    }

    job.options.release();
    job.result = null;
}

fn query(job: *const Job) core.QueryAgentHistory {
    return .{
        .request_id = job.request_id,
        .pane_id = job.pane.id,
        .pane_generation = job.pane.generation,
        .view_generation = job.view_generation,
        .cursor = job.cursor.slice(),
        .anchor = job.anchor.slice(),
        .anchor_turn = job.anchor_turn[0..job.anchor_turn_len],
        .direction = job.direction,
    };
}

test "agent history admission owns positions and allocates nothing" {
    const gpa = std.testing.allocator;
    const options = try gpa.create(HistoryOptions);
    options.* = .{
        .gpa = gpa,
        .cwd = try gpa.dupe(u8, "/tmp"),
        .arguments = try gpa.alloc([]const u8, 0),
        .environment = .init(gpa),
    };
    defer options.release();
    for ([_]bool{ false, true }) |anchored| {
        var cursor = "older-position".*;
        var anchor = "oldest-live-item".*;
        var anchor_turn = "oldest-live-turn".*;
        var thread_id = "provider-thread".*;
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
        var job = try Job.init(failing.allocator(), .{
            .client = .{ .id = 1, .generation = 3 },
            .pane = .{ .id = @enumFromInt(2), .generation = 4 },
            .thread_id = &thread_id,
            .options = options,
            .request = .{
                .request_id = @enumFromInt(5),
                .pane_id = @enumFromInt(2),
                .pane_generation = 4,
                .view_generation = 6,
                .cursor = if (anchored) "" else &cursor,
                .anchor = if (anchored) &anchor else "",
                .anchor_turn = if (anchored) &anchor_turn else "",
            },
        });
        defer job.deinit();
        @memset(&cursor, 'x');
        @memset(&anchor, 'y');
        @memset(&anchor_turn, 'y');
        @memset(&thread_id, 'z');
        const owned = job.query();

        try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
        try std.testing.expectEqualStrings(if (anchored) "" else "older-position", owned.cursor);
        try std.testing.expectEqualStrings(if (anchored) "oldest-live-item" else "", owned.anchor);
        try std.testing.expectEqualStrings(if (anchored) "oldest-live-turn" else "", owned.anchor_turn);
        try std.testing.expectEqualStrings("provider-thread", job.thread_id[0..job.thread_id_len]);
        try std.testing.expectEqual(@as(u64, 6), owned.view_generation);
        try std.testing.expectEqual(@as(usize, 2), options.references.load(.acquire));
    }
}
