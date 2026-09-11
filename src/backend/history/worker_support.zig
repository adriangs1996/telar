//! Sequential execution of history requests against durable storage.

const std = @import("std");
const core = @import("telar-core");
const channel_mod = @import("channel_support.zig");
const metrics_mod = @import("metrics.zig");
const model = @import("model.zig");
const sqlite = @import("persistence/sqlite.zig");

pub const diagnostics = core.diagnostics;

pub const Context = @import("Context.zig");

pub const Execution = enum {
    continue_running,
    stop,
};

pub const Worker = @import("Worker.zig");

test "query replacement stops at writes and preserves clients, pages and CLI replies" {
    const query = try model.Query.init(.{ .request_id = @enumFromInt(1), .origin = .{
        .client = .{ .id = 1, .generation = 1 },
        .close_after_reply = false,
    }, .text = "g" });
    var newer = query;
    newer.request_id = @enumFromInt(2);
    try std.testing.expect(superseded(.{ .query = query }, &.{.{ .query = newer }}));
    const barrier: model.Request = .{ .session_finished = .{ .id = @splat(0), .finished_at_ms = 1 } };
    try std.testing.expect(!superseded(.{ .query = query }, &.{ barrier, .{ .query = newer } }));

    newer.origin.client.generation = 2;
    try std.testing.expect(!superseded(.{ .query = query }, &.{.{ .query = newer }}));
    newer.origin = query.origin;
    newer.offset = 20;
    try std.testing.expect(!superseded(.{ .query = query }, &.{.{ .query = newer }}));
    newer.offset = 0;
    newer.entry_id = 4;
    try std.testing.expect(!superseded(.{ .query = query }, &.{.{ .query = newer }}));
    newer.entry_id = 0;
    newer.snapshot_id = 5;
    try std.testing.expect(!superseded(.{ .query = query }, &.{.{ .query = newer }}));
    newer.snapshot_id = 0;
    newer.origin.close_after_reply = true;
    try std.testing.expect(!superseded(.{ .query = query }, &.{.{ .query = newer }}));
}

pub fn superseded(request: model.Request, later: []const model.Request) bool {
    const query = switch (request) {
        .query => |query| query,
        else => return false,
    };
    if (query.origin.close_after_reply or query.offset != 0 or query.snapshot_id != 0 or query.entry_id != 0) {
        return false;
    }

    for (later) |candidate| {
        const newer = switch (candidate) {
            .query => |value| value,
            // Writes and other requests are ordering barriers.
            else => break,
        };
        if (!newer.origin.close_after_reply and newer.offset == 0 and newer.snapshot_id == 0 and newer.entry_id == 0 and
            std.meta.eql(query.origin.client, newer.origin.client) and query.distinct == newer.distinct and
            query.request_id != newer.request_id)
        {
            return true;
        }
    }

    return false;
}

pub fn unavailableResponse(request_id: model.schema.RequestId, origin: model.QueryOrigin) model.Response {
    return .{ .failed = .{
        .request_id = request_id,
        .origin = origin,
        .message = "history database is unavailable",
    } };
}

pub fn respondPruned(context: Context, pruned: model.Pruned) void {
    context.channel.sendResponse(context.io, .{ .pruned = pruned }) catch {};
}

/// Writes one imported session and its commands idempotently. Both SQLite
/// operations use `OR IGNORE`, keyed by deterministic session and sequence.
pub fn writeImportBatch(database: *sqlite.Store, batch: *const model.ImportBatch) anyerror!void {
    const session: model.SessionStarted = .{
        .id = batch.session_id,
        .pane_id = batch.pane_id,
        .location = batch.location,
        .started_at_ms = batch.started_at_ms,
        .workspace_path = @constCast(""),
        .shell = batch.source,
    };
    try database.importSession(&session);

    for (batch.commands, batch.times, 0..) |command, time, index| {
        var value: model.CommandFinished = .{
            .session_id = batch.session_id,
            .pane_id = batch.pane_id,
            .location = batch.location,
            .sequence = batch.base_sequence + index,
            .started_at_ms = time,
            .duration_ns = 0,
            .exit_code = null,
            .status = .completed,
            .author = .human,
            .cols = 0,
            .rows = 0,
            .command = command,
            .cwd = @constCast(""),
            .workspace_path = @constCast(""),
            .command_truncated = false,
            .output = @constCast(""),
            .output_truncated = false,
            .output_observed = 0,
        };
        try database.importCommand(&value);
    }
}

pub fn elapsedSince(io: std.Io, started: std.Io.Timestamp) u64 {
    return elapsedNs(started, std.Io.Timestamp.now(io, .awake));
}

fn elapsedNs(started: std.Io.Timestamp, finished: std.Io.Timestamp) u64 {
    return @intCast(@max(@as(i96, 0), finished.nanoseconds - started.nanoseconds));
}

test "database open degradation is explicit" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, "{s}/missing/history.db", .{directory_buffer[0..directory_len]});
    var metrics: metrics_mod.Counters = .{};
    var worker = Worker.init(std.testing.allocator, path, &metrics);
    defer worker.deinit();

    try std.testing.expect(!worker.available());
    try std.testing.expect(worker.openError() != null);
    try std.testing.expectEqual(@as(u64, 1), metrics.snapshot(worker.available()).sqlite_open_failures);
}

test "sqlite byte sampling distinguishes memory and disk databases" {
    const io = std.testing.io;
    var metrics: metrics_mod.Counters = .{};
    var memory = Worker.init(std.testing.allocator, ":memory:", &metrics);
    defer memory.deinit();

    try std.testing.expectEqual(@as(u64, 0), memory.sqliteBytes(io));

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, "{s}/history.db", .{directory_buffer[0..directory_len]});
    var disk = Worker.init(std.testing.allocator, path, &metrics);
    defer disk.deinit();

    try std.testing.expect(disk.available());
    try std.testing.expect(disk.sqliteBytes(io) > 0);
}

test "import batches remain idempotent at the worker storage boundary" {
    const gpa = std.testing.allocator;
    var database = try sqlite.Store.open(":memory:");
    defer database.close();
    var buffer: [512]u8 = undefined;
    const entries = [_]model.schema.ImportEntry{
        .{ .started_at_ms = 1_000, .command = "git status" },
        .{ .started_at_ms = 2_000, .command = "make -j4" },
    };
    const encoded = try model.schema.encodeImportHistory(&buffer, .{
        .request_id = @enumFromInt(3),
        .source = "zsh:/tmp/histfile",
        .base_sequence = 0,
        .entries = &entries,
    });
    const view = (try model.schema.decodeClient(encoded)).import_history;
    const first = try model.ImportBatch.init(gpa, view);
    defer first.deinit(gpa);
    const second = try model.ImportBatch.init(gpa, view);
    defer second.deinit(gpa);

    try writeImportBatch(&database, first);
    try writeImportBatch(&database, second);

    const origin: model.QueryOrigin = .{
        .client = .{ .id = 1, .generation = 1 },
        .close_after_reply = false,
    };
    const result = try database.query(gpa, &(try model.Query.init(.{
        .request_id = @enumFromInt(9),
        .origin = origin,
    })));
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.entries.len);
    try std.testing.expectEqualStrings("make -j4", result.entries[0].command);
    try std.testing.expectEqual(model.schema.HistoryAuthor.human, result.entries[0].author);
}
