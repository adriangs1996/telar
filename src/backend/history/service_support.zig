//! Application facade for command history.

const std = @import("std");
const core = @import("telar-core");
const channel_mod = @import("channel_support.zig");
const metrics_mod = @import("metrics.zig");
const model = @import("model.zig");
const request_factory = @import("request_factory.zig");
const terminal = @import("terminal.zig");
const worker_mod = @import("worker_support.zig");

pub const Service = @import("Service.zig");

test "service configuration controls recording and output capture" {
    const io = std.testing.io;
    var filters: core.history_filter.Filters = .{};
    try filters.commands.add("vault kv");
    var service = try Service.init(std.testing.allocator, .{
        .database_path = ":memory:",
        .filters = filters,
        .capture_output = true,
    });
    defer {
        service.stop(io);
        service.deinit(io);
    }
    const context: Service.CommandContext = .{
        .session_id = @splat(7),
        .pane_id = @enumFromInt(1),
        .location = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) },
        .sequence = 1,
        .workspace_path = "/work",
        .cols = 80,
        .rows = 24,
    };
    const command: terminal.Command = .{
        .bytes = "vault kv get secret/x",
        .cwd = "/work",
        .started_at_ms = 1,
        .duration_ns = 1,
        .exit_code = 0,
        .status = .completed,
        .truncated = false,
    };

    try std.testing.expect(service.capturesOutput());
    try std.testing.expect(service.recordCommand(io, .{ .context = context, .command = command }));
    try std.testing.expectEqual(@as(u64, 0), service.statsSnapshot().queued);

    var accepted = command;
    accepted.bytes = "git status";
    try std.testing.expect(service.recordCommand(io, .{ .context = context, .command = accepted }));
    try std.testing.expectEqual(@as(u64, 1), service.statsSnapshot().queued);
}

test "database open degradation remains visible through the service facade" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, "{s}/missing/history.db", .{directory_buffer[0..directory_len]});
    var service = try Service.init(std.testing.allocator, .{ .database_path = path });
    defer service.deinit(io);

    const stats = service.statsSnapshot();

    try std.testing.expect(!stats.available);
    try std.testing.expectEqual(@as(u64, 1), stats.sqlite_open_failures);
    try std.testing.expect(service.openError() != null);
}

test "agent recording applies secret filtering by default but keeps leading spaces" {
    const io = std.testing.io;
    var service = try Service.init(std.testing.allocator, .{ .database_path = ":memory:" });
    defer {
        service.stop(io);
        service.deinit(io);
    }
    const context: Service.CommandContext = .{
        .session_id = @splat(4),
        .pane_id = @enumFromInt(2),
        .location = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) },
        .sequence = 1,
        .workspace_path = "/work",
        .cols = 80,
        .rows = 24,
    };
    const secret: terminal.Command = .{
        .bytes = "deploy token=cleartext",
        .cwd = "/work",
        .started_at_ms = 1,
        .duration_ns = 1,
        .exit_code = 0,
        .status = .completed,
        .truncated = false,
    };

    try std.testing.expect(service.recordAgentCommand(io, .{ .context = context, .command = secret, .provider = "tap", .origin = .plugin }));
    try std.testing.expectEqual(@as(u64, 0), service.statsSnapshot().queued);
    try std.testing.expect(service.recordAgentCommand(io, .{ .context = context, .command = secret, .provider = "tap", .origin = .plugin, .redact = false }));
    try std.testing.expectEqual(@as(u64, 1), service.statsSnapshot().queued);

    var spaced = secret;
    spaced.bytes = " git status";
    var next = context;
    next.sequence = 2;
    try std.testing.expect(service.recordAgentCommand(io, .{ .context = next, .command = spaced, .provider = "hook", .origin = .hook }));
    try std.testing.expectEqual(@as(u64, 2), service.statsSnapshot().queued);
}
