//! The `telar history` command and its terminal-safe text presentation.

const client = @import("telar-client");
const localsocket = @import("localsocket");
const core = @import("telar-core");
const std = @import("std");
const HistoryOptions = @import("arguments/HistoryOptions.zig");
const RuntimeConnector = client.RuntimeConnector;
const UtcTimestamp = @import("UtcTimestamp.zig");
const BatchSender = @import("BatchSender.zig");
const ImportParser = @import("ImportParser.zig");
const ResolvedImport = @import("ResolvedImport.zig");
const history = @import("arguments/history.zig");
const Session = @import("Session.zig");
const limit_reached = @import("limit_reached.zig");

const request_buffer_size = core.max_history_query_bytes + core.max_cwd_bytes + 64;

/// Queries the local runtime using the selected history filters and writes
/// escaped, line-oriented results to stdout.
///
/// ```zig
/// try history.run(process_init, options);
/// ```
pub fn run(init: std.process.Init, options: HistoryOptions) !void {
    if (options.action == .import) {
        return runImport(init, options);
    }
    if (options.action == .delete or options.action == .prune) {
        return runPrune(init, options);
    }
    if (options.action == .show) {
        return runShow(init, options);
    }
    if (options.action == .stats) {
        return runStats(init, options);
    }

    const connector = try RuntimeConnector.init(init.io, init.minimal.environ, options.socket);
    var connection = try connector.connectOrStart(.{});
    defer connection.deinit(init.io);

    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const scope_value: []const u8 = switch (options.scope) {
        .cwd => cwd: {
            const len = try std.Io.Dir.cwd().realPathFile(init.io, ".", &cwd_buffer);
            break :cwd cwd_buffer[0..len];
        },
        .workspace => std.mem.span(options.scope_value.?),
        .global, .pane => "",
    };
    const query = if (options.query) |value| std.mem.span(value) else "";

    var send_buffer: [request_buffer_size]u8 = undefined;
    try connection.send(init.io, try core.encodeQueryHistory(&send_buffer, .{
        .request_id = @enumFromInt(1),
        .query = query,
        .scope = options.scope,
        .scope_value = scope_value,
        .pane_id = options.pane_id,
        .failed_only = options.failed_only,
        .author = options.author,
        .limit = options.limit,
    }));

    const receive_buffer = try init.gpa.alloc(u8, localsocket.transport.max_frame_size);
    defer init.gpa.free(receive_buffer);
    const response = try core.decodeServer(try connection.receive(init.io, receive_buffer));
    switch (response) {
        .history_results => |results| try print(init.io, results),
        .request_failed => |failure| {
            // This is the command failure diagnostic on stderr; keep its CLI prefix and leave stdout available for results.
            std.debug.print("telar history: {s}\n", .{failure.message});
            return error.HistoryQueryFailed;
        },
        else => return error.UnexpectedRuntimeResponse,
    }
}

fn print(io: std.Io, results: core.HistoryResultsView) !void {
    var output_buffer: [16 * 1024]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(io, &output_buffer);
    const writer = &output.interface;
    var entries = results.entries();
    while (try entries.next()) |entry| {
        try writer.print("#{d}  ", .{entry.id});
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
            .running => try writer.writeAll("RUN  "),
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
        if (entry.author == .agent and entry.provider.len != 0) {
            try writer.writeAll("\x1b[2m[");
            try writeField(writer, entry.provider);
            try writer.writeAll("]\x1b[22m ");
        }
        try writeField(writer, entry.command);
        try writer.writeByte('\n');
    }
    try writer.flush();
}

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

fn writeField(writer: *std.Io.Writer, value: []const u8) !void {
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

/// The newest bytes of a histfile imported; older commands are left out
/// and the limit is named.
pub const max_histfile_bytes = 32 * 1024 * 1024;
const histfile_limit = core.Limit.declare("history.max_histfile_bytes", "bytes", max_histfile_bytes);

/// Command bytes one import batch carries: room for the longest command
/// the wire accepts several times over, far below a frame.
pub const max_batch_payload = 4 * core.max_import_command_bytes;

/// Streams one shell histfile to the runtime in bounded idempotent batches.
/// The source label pins the deterministic import session, so re-running the
/// import only adds entries the runtime has not seen.
fn runImport(init: std.process.Init, options: HistoryOptions) !void {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = try resolveImport(init, options, &path_buffer);
    const histfile = try readNewest(init, resolved.path, histfile_limit);
    defer init.gpa.free(histfile.buffer);
    const source_data = histfile.lines;

    var session = try Session.open(init, options.socket);
    defer session.close();

    var source_buffer: [core.max_import_source_bytes]u8 = undefined;
    const source = try std.fmt.bufPrint(&source_buffer, "{s}:{s}", .{ @tagName(resolved.kind), resolved.path });

    var sender: BatchSender = .{
        .io = init.io,
        .gpa = init.gpa,
        .connection = &session.connection,
        .source = source,
    };
    var parser_state: ImportParser = .{ .kind = resolved.kind };
    var lines = std.mem.splitScalar(u8, source_data, '\n');
    while (lines.next()) |line| {
        if (parser_state.feed(line)) |entry| {
            try sender.push(entry);
        }
    }
    if (parser_state.flush()) |entry| {
        try sender.push(entry);
    }

    try sender.finish();
    var stdout_buffer: [256]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    try output.interface.print("imported {d} commands from {s}\n", .{ sender.total, resolved.path });
    try output.interface.flush();

    if (parser_state.skipped != 0) {
        limit_reached.reportThrough(&session, .{
            .limit = core.import_command_limit,
            .requested = parser_state.largest_skipped,
        });
    }

    // Older or longer commands were left out: the import did not do all it
    // was asked, and a script must not read it as complete.
    if (histfile.truncated or parser_state.skipped != 0) {
        std.process.exit(limit_reached.exit_status);
    }
}

/// A histfile's newest whole lines, in `buffer`, and whether older ones
/// did not fit.
const NewestLines = struct {
    buffer: []u8,
    lines: []const u8,
    truncated: bool = false,
};

// Reads at most `limit.value` bytes from the end of the file. A longer file
// starts at its first whole line in that window, and the limit is named:
// the newest commands are the ones worth keeping.
fn readNewest(init: std.process.Init, path: []const u8, limit: core.Limit) !NewestLines {
    const file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
    defer file.close(init.io);

    const size = (try file.stat(init.io)).size;
    const offset = size -| limit.value;
    const buffer = try init.gpa.alloc(u8, @intCast(size - offset));
    errdefer init.gpa.free(buffer);

    const read = try file.readPositionalAll(init.io, buffer, offset);

    if (offset == 0) {
        return .{
            .buffer = buffer,
            .lines = buffer[0..read],
        };
    }

    limit_reached.report(.{
        .limit = limit,
        .requested = size,
    });
    const first_line = if (std.mem.indexOfScalar(u8, buffer[0..read], '\n')) |at| at + 1 else read;
    return .{
        .buffer = buffer,
        .lines = buffer[first_line..read],
        .truncated = true,
    };
}

fn resolveImport(init: std.process.Init, options: HistoryOptions, buffer: *[std.fs.max_path_bytes]u8) !ResolvedImport {
    if (options.import_file) |file| {
        const path = std.mem.span(file);
        const kind = if (options.import_kind != .auto)
            options.import_kind
        else if (std.mem.endsWith(u8, path, "fish_history"))
            history.HistoryImportKind.fish
        else if (std.mem.indexOf(u8, path, "bash") != null)
            history.HistoryImportKind.bash
        else
            history.HistoryImportKind.zsh;
        return .{ .kind = kind, .path = path };
    }

    const home = init.minimal.environ.getPosix("HOME") orelse return error.HistfileNotFound;
    const candidates: []const ResolvedImport = &.{
        .{ .kind = .zsh, .path = ".zsh_history" },
        .{ .kind = .bash, .path = ".bash_history" },
        .{ .kind = .fish, .path = ".local/share/fish/fish_history" },
    };
    for (candidates) |candidate| {
        if (options.import_kind != .auto and options.import_kind != candidate.kind) {
            continue;
        }

        const path = try std.fmt.bufPrint(buffer, "{s}/{s}", .{ home, candidate.path });
        std.Io.Dir.cwd().access(init.io, path, .{}) catch continue;
        return .{ .kind = candidate.kind, .path = path };
    }

    return error.HistfileNotFound;
}

/// Deletes one entry or prunes by filters. Prune is destructive: without
/// `--yes` it shows the newest matches (a dry run) and asks for
/// confirmation on stdin.
fn runPrune(init: std.process.Init, options: HistoryOptions) !void {
    const connector = try RuntimeConnector.init(init.io, init.minimal.environ, options.socket);
    var connection = try connector.connectOrStart(.{});
    defer connection.deinit(init.io);
    var stdout_buffer: [512]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const writer = &output.interface;

    var send_buffer: [4096]u8 = undefined;
    if (options.action == .delete) {
        try connection.send(init.io, try core.encodeDeleteHistory(&send_buffer, .{
            .request_id = @enumFromInt(1),
            .id = options.delete_id,
        }));
        const removed = try receivePruned(init, &connection);
        try writer.print("removed {d} entries\n", .{removed});
        try writer.flush();
        return;
    }

    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const scope_value: []const u8 = switch (options.scope) {
        .cwd => cwd: {
            const len = try std.Io.Dir.cwd().realPathFile(init.io, ".", &cwd_buffer);
            break :cwd cwd_buffer[0..len];
        },
        .workspace => std.mem.span(options.scope_value.?),
        .global, .pane => "",
    };
    const match = if (options.query) |value| std.mem.span(value) else "";

    if (options.dry_run or !options.assume_yes) {
        try connection.send(init.io, try core.encodeQueryHistory(&send_buffer, .{
            .request_id = @enumFromInt(1),
            .query = match,
            .scope = options.scope,
            .scope_value = scope_value,
            .pane_id = options.pane_id,
            .failed_only = options.failed_only,
            .limit = core.max_history_results,
        }));
        const receive_buffer = try init.gpa.alloc(u8, localsocket.transport.max_frame_size);
        defer init.gpa.free(receive_buffer);
        const response = try core.decodeServer(try connection.receive(init.io, receive_buffer));
        const results = switch (response) {
            .history_results => |results| results,
            .request_failed => |failure| {
                // This is the command failure diagnostic on stderr; keep its CLI prefix and leave stdout available for results.
                std.debug.print("telar history: {s}\n", .{failure.message});
                return error.HistoryQueryFailed;
            },
            else => return error.UnexpectedRuntimeResponse,
        };
        if (options.before_ms != 0) {
            try writer.print("{d} newest entries match the text/scope filters; --before applies on top and is not previewable\n", .{results.entry_count});
        } else {
            try writer.print("would remove {d} entries (counting at most the newest {d})\n", .{ results.entry_count, core.max_history_results });
        }
        try writer.flush();
        if (options.dry_run) {
            return;
        }

        try writer.writeAll("prune permanently? type yes to continue: ");
        try writer.flush();
        var line_buffer: [16]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().readerStreaming(init.io, &line_buffer);
        if (!confirmPrune(&stdin_reader.interface)) {
            try writer.writeAll("aborted\n");
            try writer.flush();
            return;
        }

        connection.deinit(init.io);
        connection = try connector.connectOrStart(.{});
    }

    try connection.send(init.io, try core.encodePruneHistory(&send_buffer, .{
        .request_id = @enumFromInt(2),
        .scope = options.scope,
        .scope_value = scope_value,
        .pane_id = options.pane_id,
        .before_ms = options.before_ms,
        .failed_only = options.failed_only,
        .match = match,
    }));
    const removed = try receivePruned(init, &connection);
    try writer.print("removed {d} entries\n", .{removed});
    try writer.flush();
}

fn confirmPrune(reader: *std.Io.Reader) bool {
    const line = reader.takeDelimiter('\n') catch return false;
    const answer = std.mem.trim(u8, line orelse return false, " \r");

    return std.mem.eql(u8, answer, "yes");
}

fn receivePruned(init: std.process.Init, connection: *localsocket.SocketChannel) !u64 {
    var receive_buffer: [1024]u8 = undefined;
    const response = try core.decodeServer(try connection.receive(init.io, &receive_buffer));
    return switch (response) {
        .history_pruned => |pruned| pruned.removed,
        .request_failed => |failure| blk: {
            // This is the command failure diagnostic on stderr; keep its CLI prefix and leave stdout available for results.
            std.debug.print("telar history: {s}\n", .{failure.message});
            break :blk error.HistoryPruneFailed;
        },
        else => error.UnexpectedRuntimeResponse,
    };
}

/// Prints the captured output of one exact entry, raw, to stdout.
fn runShow(init: std.process.Init, options: HistoryOptions) !void {
    const connector = try RuntimeConnector.init(init.io, init.minimal.environ, options.socket);
    var connection = try connector.connectOrStart(.{});
    defer connection.deinit(init.io);

    var send_buffer: [64]u8 = undefined;
    try connection.send(init.io, try core.encodeReadHistoryOutput(&send_buffer, .{
        .request_id = @enumFromInt(1),
        .id = options.delete_id,
    }));

    const receive_buffer = try init.gpa.alloc(u8, localsocket.transport.max_frame_size);
    defer init.gpa.free(receive_buffer);
    const response = try core.decodeServer(try connection.receive(init.io, receive_buffer));
    const output = switch (response) {
        .history_output => |value| value,
        .request_failed => |failure| {
            // This is the command failure diagnostic on stderr; keep its CLI prefix and leave stdout available for results.
            std.debug.print("telar history: {s}\n", .{failure.message});
            return error.HistoryQueryFailed;
        },
        else => return error.UnexpectedRuntimeResponse,
    };

    if (output.observed_bytes == 0) {
        // Explain absent captured output on stderr without adding bytes to the history output stream.
        std.debug.print("telar history: no output captured for entry {d} (runtime.history.output = \"bounded\" enables capture)\n", .{output.id});
        return;
    }

    var stdout_buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    try writer.interface.writeAll(output.content);
    try writer.interface.flush();
    if (output.truncated) {
        // The truncation notice belongs on stderr, separate from the captured history bytes.
        std.debug.print("telar history: output truncated ({d} bytes observed)\n", .{output.observed_bytes});
    }
}

/// Prints aggregate history statistics for one scope and period.
fn runStats(init: std.process.Init, options: HistoryOptions) !void {
    const connector = try RuntimeConnector.init(init.io, init.minimal.environ, options.socket);
    var connection = try connector.connectOrStart(.{});
    defer connection.deinit(init.io);

    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const scope_value: []const u8 = switch (options.scope) {
        .cwd => cwd: {
            const len = try std.Io.Dir.cwd().realPathFile(init.io, ".", &cwd_buffer);
            break :cwd cwd_buffer[0..len];
        },
        .workspace => std.mem.span(options.scope_value.?),
        .global, .pane => "",
    };
    const since_ms: i64 = if (options.period_days == 0)
        0
    else
        std.Io.Timestamp.now(init.io, .real).toMilliseconds() - @as(i64, options.period_days) * 86_400_000;

    var send_buffer: [4096]u8 = undefined;
    try connection.send(init.io, try core.encodeHistoryStatsQuery(&send_buffer, .{
        .request_id = @enumFromInt(1),
        .scope = options.scope,
        .scope_value = scope_value,
        .pane_id = options.pane_id,
        .since_ms = since_ms,
    }));

    const receive_buffer = try init.gpa.alloc(u8, localsocket.transport.max_frame_size);
    defer init.gpa.free(receive_buffer);
    const response = try core.decodeServer(try connection.receive(init.io, receive_buffer));
    const stats = switch (response) {
        .history_stats_result => |value| value,
        .request_failed => |failure| {
            // This is the command failure diagnostic on stderr; keep its CLI prefix and leave stdout available for results.
            std.debug.print("telar history: {s}\n", .{failure.message});
            return error.HistoryQueryFailed;
        },
        else => return error.UnexpectedRuntimeResponse,
    };

    var stdout_buffer: [8 * 1024]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const writer = &output.interface;
    try writer.print("commands: {d}\nunique:   {d}\n", .{ stats.total, stats.unique });
    var top = stats.top();
    var first = true;
    while (try top.next()) |entry| {
        if (first) {
            try writer.writeAll("top:\n");
            first = false;
        }

        try writer.print("  {d:>7}  ", .{entry.count});
        try writeField(writer, entry.command);
        try writer.writeAll("\n");
    }
    try writer.flush();
}
