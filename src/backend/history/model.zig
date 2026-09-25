//! Owned values exchanged with the history worker.

const core = @import("telar-core");
const StoredSessionTitle = @import("StoredSessionTitle.zig");
const std = @import("std");
const Query = @import("Query.zig");
const QueryOrigin = @import("QueryOrigin.zig");
const LaunchAttempt = @import("LaunchAttempt.zig");
const SessionStarted = @import("SessionStarted.zig");
const SessionFinished = @import("SessionFinished.zig");
const CommandFinished = @import("CommandFinished.zig");
const ImportBatch = @import("ImportBatch.zig");
const Delete = @import("Delete.zig");
const Prune = @import("Prune.zig");
const StatsQuery = @import("StatsQuery.zig");
const QueryResult = @import("QueryResult.zig");
const Pruned = @import("Pruned.zig");
const OutputResult = @import("OutputResult.zig");
const StatsResult = @import("StatsResult.zig");

pub const encoded_result_header_bytes = 20;
pub const encoded_entry_overhead_bytes = 51;

pub const SessionId = [16]u8;

pub const LaunchPhase = enum(u8) {
    pane_registration = 0,
    wait_actor = 1,
    output_actor = 2,
};

pub const CommandStatus = enum(u8) {
    completed = 0,
    interrupted = 1,
    running = 2,
};

test "session titles validate text and source authority before persistence" {
    const session_id = [_]u8{1} ** 16;
    _ = try StoredSessionTitle.init(.{ .id = session_id, .title = "Improve sidebar", .source = .generated, .state = .ready });
    _ = try StoredSessionTitle.init(.{ .id = session_id, .title = "", .source = .telar, .state = .failed });
    try std.testing.expectError(
        error.InvalidAgentTitle,
        StoredSessionTitle.init(.{ .id = session_id, .title = "bad\ntitle", .source = .generated, .state = .ready }),
    );
    try std.testing.expectError(
        error.InvalidAgentTitle,
        StoredSessionTitle.init(.{ .id = session_id, .title = "", .source = .generated, .state = .ready }),
    );
    try std.testing.expectError(
        error.InvalidAgentTitle,
        StoredSessionTitle.init(.{ .id = session_id, .title = "manual", .source = .manual, .state = .pending }),
    );
}

test "history queries own request text and scope bytes" {
    var text = [_]u8{ 'g', 'i', 't' };
    var scope = [_]u8{ '/', 'w', 'o', 'r', 'k' };
    const query = try Query.init(.{
        .request_id = @enumFromInt(7),
        .origin = .{
            .client = .{ .id = 3, .generation = 4 },
            .close_after_reply = true,
        },
        .text = &text,
        .scope = .workspace,
        .scope_value = &scope,
        .failed_only = true,
        .limit = 9,
    });

    @memset(&text, 'x');
    @memset(&scope, 'y');

    try std.testing.expectEqualStrings("git", query.textSlice());
    try std.testing.expectEqualStrings("/work", query.scopeSlice());
    try std.testing.expectEqual(@as(core.RequestId, @enumFromInt(7)), query.request_id);
    try std.testing.expectEqual(@as(u64, 3), query.origin.client.id);
    try std.testing.expectEqual(@as(u64, 4), query.origin.client.generation);
    try std.testing.expect(query.origin.close_after_reply);
    try std.testing.expectEqual(core.HistoryScope.workspace, query.scope);
    try std.testing.expect(query.failed_only);
    try std.testing.expectEqual(@as(u16, 9), query.limit);
}

test "history query validation rejects values that cannot enter the worker" {
    const origin: QueryOrigin = .{
        .client = .{ .id = 1, .generation = 2 },
        .close_after_reply = false,
    };
    const long_text = [_]u8{'q'} ** (core.max_history_query_bytes + 1);
    const long_scope = [_]u8{'s'} ** (core.max_cwd_bytes + 1);

    try std.testing.expectError(error.QueryTooLong, Query.init(.{
        .request_id = @enumFromInt(1),
        .origin = origin,
        .text = &long_text,
    }));
    try std.testing.expectError(error.ScopeTooLong, Query.init(.{
        .request_id = @enumFromInt(1),
        .origin = origin,
        .scope_value = &long_scope,
    }));
    try std.testing.expectError(error.InvalidLimit, Query.init(.{
        .request_id = @enumFromInt(1),
        .origin = origin,
        .limit = 0,
    }));
    try std.testing.expectError(error.InvalidLimit, Query.init(.{
        .request_id = @enumFromInt(1),
        .origin = origin,
        .limit = core.max_history_results + 1,
    }));
    try std.testing.expectError(error.InvalidPaneId, Query.init(.{
        .request_id = @enumFromInt(1),
        .origin = origin,
        .scope = .pane,
    }));
    try std.testing.expectError(error.UnexpectedPaneId, Query.init(.{
        .request_id = @enumFromInt(1),
        .origin = origin,
        .pane_id = @enumFromInt(2),
    }));
}

pub const Request = union(enum) {
    launch_attempt: *LaunchAttempt,
    session_started: *SessionStarted,
    session_finished: SessionFinished,
    session_title: StoredSessionTitle,
    command_finished: *CommandFinished,
    query: Query,
    import: *ImportBatch,
    delete: Delete,
    prune: Prune,
    read_output: Delete,
    stats: StatsQuery,
};

pub const Response = union(enum) {
    query_result: *QueryResult,
    failed: Failure,
    pruned: Pruned,
    output_result: *OutputResult,
    stats_result: *StatsResult,
};

pub fn deinitRequest(request: Request, gpa: std.mem.Allocator) void {
    switch (request) {
        .launch_attempt => |value| value.deinit(gpa),
        .session_started => |value| value.deinit(gpa),
        .command_finished => |value| value.deinit(gpa),
        .import => |value| value.deinit(gpa),
        .session_finished, .session_title, .query, .delete, .prune, .read_output, .stats => {},
    }
}

pub fn deinitResponse(response: Response, _: std.mem.Allocator) void {
    switch (response) {
        .query_result => |value| value.deinit(),
        .failed, .pruned => {},
        .output_result => |value| value.deinit(),
        .stats_result => |value| value.deinit(),
    }
}

const Failure = struct {
    request_id: core.RequestId,
    origin: QueryOrigin,
    message: []const u8,
};
