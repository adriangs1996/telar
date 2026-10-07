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
