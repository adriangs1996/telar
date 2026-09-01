//! The `telar history` command and its terminal-safe text presentation.

const std = @import("std");
const core = @import("telar-core");
const parser = @import("parser.zig");
const runtime_connection = @import("runtime_connection.zig");

const Io = std.Io;
const File = Io.File;
const HistoryOptions = parser.HistoryOptions;
const RuntimeConnector = runtime_connection.RuntimeConnector;
const request_buffer_size = core.schema.max_history_query_bytes + core.schema.max_cwd_bytes + 64;

/// Queries the local runtime using the selected history filters and writes
/// escaped, line-oriented results to stdout.
///
/// ```zig
/// try history.run(process_init, options);
/// ```
pub fn run(init: std.process.Init, options: HistoryOptions) !void {
    const connector = try RuntimeConnector.init(init, options.socket);
    var connection = try connector.connectOrStart(.{});
    defer connection.deinit(init.io);

    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const scope_value: []const u8 = switch (options.scope) {
        .cwd => cwd: {
            const len = try Io.Dir.cwd().realPathFile(init.io, ".", &cwd_buffer);
            break :cwd cwd_buffer[0..len];
        },
        .workspace => std.mem.span(options.scope_value.?),
        .global, .pane => "",
    };
    const query = if (options.query) |value| std.mem.span(value) else "";

    var send_buffer: [request_buffer_size]u8 = undefined;
    try connection.send(init.io, try core.schema.encodeQueryHistory(&send_buffer, .{
        .request_id = @enumFromInt(1),
        .query = query,
        .scope = options.scope,
        .scope_value = scope_value,
        .pane_id = options.pane_id,
        .failed_only = options.failed_only,
        .limit = options.limit,
    }));

    const receive_buffer = try init.gpa.alloc(u8, core.transport.max_frame_size);
    defer init.gpa.free(receive_buffer);
    const response = try core.schema.decodeServer(try connection.receive(init.io, receive_buffer));
    switch (response) {
        .history_results => |results| try print(init.io, results),
        .request_failed => |failure| {
            std.debug.print("telar history: {s}\n", .{failure.message});
            return error.HistoryQueryFailed;
        },
        else => return error.UnexpectedRuntimeResponse,
    }
}

fn print(io: Io, results: core.schema.HistoryResultsView) !void {
    var output_buffer: [16 * 1024]u8 = undefined;
    var output = File.stdout().writerStreaming(io, &output_buffer);
    const writer = &output.interface;
    var entries = results.entries();
    while (try entries.next()) |entry| {
        const timestamp = utcTimestamp(entry.started_at_ms);
        try writer.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}Z  ", .{
            timestamp.year,
            timestamp.month,
            timestamp.day,
            timestamp.hour,
            timestamp.minute,
            timestamp.second,
        });
        switch (entry.status) {
            .interrupted => try writer.writeAll("INT  "),
            .completed => if (entry.exit_code) |exit_code| {
                if (exit_code < 0) {
                    try writer.print("-{d}  ", .{@as(u64, @intCast(-@as(i64, exit_code)))});
                } else {
                    try writer.print("{d}  ", .{@as(u32, @intCast(exit_code))});
                }
            } else {
                try writer.writeAll("?  ");
            },
        }
        const duration_ms: u64 = @intCast(@max(@as(i64, 0), @divTrunc(entry.duration_ns, std.time.ns_per_ms)));
        try writer.print("{d}ms  ", .{duration_ms});
        try writeField(writer, entry.cwd);
        try writer.writeAll("  ");
        try writeField(writer, entry.command);
        try writer.writeByte('\n');
    }
    try writer.flush();
}

const UtcTimestamp = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

fn utcTimestamp(milliseconds: i64) UtcTimestamp {
    const seconds: u64 = @intCast(@max(@as(i64, 0), @divFloor(milliseconds, 1000)));
    const epoch = std.time.epoch.EpochSeconds{ .secs = seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return .{
        .year = year_day.year,
        .month = @intFromEnum(month_day.month),
        .day = month_day.day_index + 1,
        .hour = day_seconds.getHoursIntoDay(),
        .minute = day_seconds.getMinutesIntoHour(),
        .second = day_seconds.getSecondsIntoMinute(),
    };
}

fn writeField(writer: *Io.Writer, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => if (byte < 0x20 or byte == 0x7f) {
            try writer.print("\\x{x:0>2}", .{byte});
        } else {
            try writer.writeByte(byte);
        },
    };
}

test "history timestamps are rendered in UTC" {
    try std.testing.expectEqual(UtcTimestamp{
        .year = 2024,
        .month = 1,
        .day = 1,
        .hour = 0,
        .minute = 0,
        .second = 0,
    }, utcTimestamp(1_704_067_200_000));
}

test "negative history timestamps clamp to the Unix epoch" {
    try std.testing.expectEqual(UtcTimestamp{
        .year = 1970,
        .month = 1,
        .day = 1,
        .hour = 0,
        .minute = 0,
        .second = 0,
    }, utcTimestamp(-1));
}

test "history fields escape terminal control bytes" {
    var storage: [128]u8 = undefined;
    var writer = Io.Writer.fixed(&storage);

    try writeField(&writer, "echo\n\r\t\x00\x1b\x7f[31m");

    try std.testing.expectEqualStrings("echo\\n\\r\\t\\x00\\x1b\\x7f[31m", writer.buffered());
}

test "history fields preserve printable UTF-8" {
    var storage: [128]u8 = undefined;
    var writer = Io.Writer.fixed(&storage);

    try writeField(&writer, "git commit -m 'listo ✓'");

    try std.testing.expectEqualStrings("git commit -m 'listo ✓'", writer.buffered());
}
