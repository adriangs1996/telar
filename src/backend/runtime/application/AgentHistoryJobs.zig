const std = @import("std");
const Job = @import("AgentHistoryJob.zig");
const ClientKey = @import("../../history/ClientKey.zig");
const Jobs = @This();

items: [4]?*Job = @splat(null),
storage: [4]Job = undefined,

/// Reserves at most four readers globally and one per client connection.
/// Example: `const slot = try jobs.available(client);`.
pub fn available(jobs: *const Jobs, client: ClientKey) !usize {
    var vacant: ?usize = null;
    for (jobs.items, 0..) |item, index| {
        if (item) |job| {
            if (std.meta.eql(job.client, client)) {
                return error.AgentHistoryBusy;
            }
        } else if (vacant == null) {
            vacant = index;
        }
    }

    return vacant orelse error.AgentHistoryBusy;
}

/// Removes exactly the job whose actor has joined.
/// Example: `jobs.remove(job);`.
pub fn remove(jobs: *Jobs, completed: *Job) void {
    for (&jobs.items) |*item| {
        if (item.* == completed) {
            item.* = null;
            return;
        }
    }

    unreachable;
}

/// Cancelling the select discards completion events, so ownership stays here
/// until every actor has joined. Example: `jobs.deinitJoined();`.
pub fn deinitJoined(jobs: *Jobs) void {
    for (&jobs.items) |*item| {
        if (item.*) |job| {
            job.deinit();
            item.* = null;
        }
    }
}

test "agent history readers enforce global and connection generation bounds" {
    var storage: [4]Job = undefined;
    var jobs: Jobs = .{};
    for (&storage, 0..) |*job, index| {
        job.client = .{ .id = index + 1, .generation = 10 };
        const slot = try jobs.available(job.client);
        jobs.items[slot] = job;
        try std.testing.expectError(error.AgentHistoryBusy, jobs.available(job.client));
    }

    try std.testing.expectError(error.AgentHistoryBusy, jobs.available(.{ .id = 9, .generation = 10 }));
    jobs.remove(&storage[2]);
    try std.testing.expectEqual(@as(usize, 2), try jobs.available(.{ .id = 1, .generation = 11 }));
    try std.testing.expectError(error.AgentHistoryBusy, jobs.available(.{ .id = 1, .generation = 10 }));
}

test "agent history shutdown releases an owned result whose completion was discarded" {
    const core = @import("telar-core");
    const OwnedPage = @import("../delivery/OwnedAgentHistoryPage.zig");
    const gpa = std.testing.allocator;
    var jobs: Jobs = .{};
    const job = &jobs.storage[0];
    const options = try gpa.create(@import("../../agent_panes/HistoryOptions.zig"));
    options.* = .{
        .gpa = gpa,
        .cwd = try gpa.dupe(u8, "/tmp"),
        .arguments = try gpa.alloc([]const u8, 0),
        .environment = .init(gpa),
    };
    job.* = .{
        .gpa = gpa,
        .client = .{ .id = 1, .generation = 4 },
        .pane = .{ .id = @enumFromInt(2), .generation = 8 },
        .request_id = @enumFromInt(3),
        .view_generation = 5,
        .direction = .older,
        .cursor = .{},
        .anchor = .{},
        .thread_id_len = 0,
        .options = options,
    };
    jobs.items[0] = job;
    defer jobs.deinitJoined();
    const page = try gpa.create(core.AgentHistoryPage);
    page.* = .{
        .request_id = job.request_id,
        .view_generation = job.view_generation,
        .snapshot = .{ .pane_id = job.pane.id, .pane_generation = job.pane.generation },
    };
    job.result = gpa.create(OwnedPage) catch |err| {
        gpa.destroy(page);
        return err;
    };
    job.result.?.* = .{ .gpa = gpa, .value = page };
    jobs.deinitJoined();

    for (jobs.items) |item| {
        try std.testing.expect(item == null);
    }
}
