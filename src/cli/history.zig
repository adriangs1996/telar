//! The `telar history` command and its terminal-safe text presentation.

const max_history_query_bytes_module = @import("telar-core").max_history_query_bytes;
const max_cwd_bytes_module = @import("telar-core").max_cwd_bytes;
const std = @import("std");
const HistoryOptions = @import("arguments/HistoryOptions.zig");
const RuntimeConnector = @import("RuntimeConnector.zig");
const encodeQueryHistory_module = @import("telar-core").encodeQueryHistory;
const max_frame_size_module = @import("telar-core").max_frame_size;
const decodeServer_module = @import("telar-core").decodeServer;
const HistoryResultsViewType = @import("telar-core").HistoryResultsView;
const UtcTimestamp = @import("UtcTimestamp.zig");
const max_import_source_bytes_module = @import("telar-core").max_import_source_bytes;
const BatchSender = @import("BatchSender.zig");
const ImportParser = @import("ImportParser.zig");
const ResolvedImport = @import("ResolvedImport.zig");
const history = @import("arguments/history.zig");
const ImportedEntry = @import("ImportedEntry.zig");
const encodeDeleteHistory_module = @import("telar-core").encodeDeleteHistory;
const max_history_results_module = @import("telar-core").max_history_results;
const encodePruneHistory_module = @import("telar-core").encodePruneHistory;
const SocketChannelType = @import("telar-core").SocketChannel;
const encodeReadHistoryOutput_module = @import("telar-core").encodeReadHistoryOutput;
const encodeHistoryStatsQuery_module = @import("telar-core").encodeHistoryStatsQuery;

const request_buffer_size = max_history_query_bytes_module + max_cwd_bytes_module + 64;

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

    const connector = try RuntimeConnector.init(init, options.socket);
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
    try connection.send(init.io, try encodeQueryHistory_module(&send_buffer, .{
        .request_id = @enumFromInt(1),
        .query = query,
        .scope = options.scope,
        .scope_value = scope_value,
        .pane_id = options.pane_id,
        .failed_only = options.failed_only,
        .author = options.author,
        .limit = options.limit,
    }));

    const receive_buffer = try init.gpa.alloc(u8, max_frame_size_module);
    defer init.gpa.free(receive_buffer);
    const response = try decodeServer_module(try connection.receive(init.io, receive_buffer));
    switch (response) {
        .history_results => |results| try print(init.io, results),
        .request_failed => |failure| {
            std.debug.print("telar history: {s}\n", .{failure.message});
            return error.HistoryQueryFailed;
        },
        else => return error.UnexpectedRuntimeResponse,
    }
}

fn print(io: std.Io, results: HistoryResultsViewType) !void {
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
    var writer = std.Io.Writer.fixed(&storage);

    try writeField(&writer, "echo\n\r\t\x00\x1b\x7f[31m");

    try std.testing.expectEqualStrings("echo\\n\\r\\t\\x00\\x1b\\x7f[31m", writer.buffered());
}

test "history fields preserve printable UTF-8" {
    var storage: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);

    try writeField(&writer, "git commit -m 'listo ✓'");

    try std.testing.expectEqualStrings("git commit -m 'listo ✓'", writer.buffered());
}

const max_histfile_bytes = 32 * 1024 * 1024;

pub const max_batch_payload = 48 * 1024;

/// Streams one shell histfile to the runtime in bounded idempotent batches.
/// The source label pins the deterministic import session, so re-running the
/// import only adds entries the runtime has not seen.
fn runImport(init: std.process.Init, options: HistoryOptions) !void {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = try resolveImport(init, options, &path_buffer);
    const source_data = try std.Io.Dir.cwd().readFileAlloc(init.io, resolved.path, init.gpa, .limited(max_histfile_bytes));
    defer init.gpa.free(source_data);

    const connector = try RuntimeConnector.init(init, options.socket);
    var connection = try connector.connectOrStart(.{});
    defer connection.deinit(init.io);

    var source_buffer: [max_import_source_bytes_module]u8 = undefined;
    const source = try std.fmt.bufPrint(&source_buffer, "{s}:{s}", .{ @tagName(resolved.kind), resolved.path });

    var sender: BatchSender = .{
        .io = init.io,
        .gpa = init.gpa,
        .connection = &connection,
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

test "zsh extended history parses timestamps and continuations" {
    var state: ImportParser = .{ .kind = .zsh };
    var collected: [4]ImportedEntry = undefined;
    var commands: [4][64]u8 = undefined;
    var count: usize = 0;
    const file = ": 1700000000:0;git status\n: 1700000001:2;echo one \\\ntwo\nplain command\n";
    var lines = std.mem.splitScalar(u8, file, '\n');
    while (lines.next()) |line| {
        if (state.feed(line)) |entry| {
            @memcpy(commands[count][0..entry.command.len], entry.command);
            collected[count] = .{ .started_at_ms = entry.started_at_ms, .command = commands[count][0..entry.command.len] };
            count += 1;
        }
    }
    if (state.flush()) |entry| {
        @memcpy(commands[count][0..entry.command.len], entry.command);
        collected[count] = .{ .started_at_ms = entry.started_at_ms, .command = commands[count][0..entry.command.len] };
        count += 1;
    }

    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualStrings("git status", collected[0].command);
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), collected[0].started_at_ms);
    try std.testing.expectEqualStrings("echo one \ntwo", collected[1].command);
    try std.testing.expectEqualStrings("plain command", collected[2].command);
}

test "bash timestamp comments attach to the following command" {
    var state: ImportParser = .{ .kind = .bash };
    try std.testing.expect(state.feed("#1700000000") == null);

    const first = state.feed("make test").?;
    try std.testing.expectEqualStrings("make test", first.command);
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), first.started_at_ms);

    const second = state.feed("ls").?;
    try std.testing.expectEqualStrings("ls", second.command);
    try std.testing.expect(state.flush() == null);
}

test "fish history pairs cmd and when lines" {
    var state: ImportParser = .{ .kind = .fish };
    try std.testing.expect(state.feed("- cmd: git log") == null);
    const first = state.feed("  when: 1700000000").?;
    try std.testing.expectEqualStrings("git log", first.command);
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), first.started_at_ms);
    try std.testing.expect(state.feed("- cmd: htop") == null);
    const tail = state.flush().?;
    try std.testing.expectEqualStrings("htop", tail.command);
}

/// Deletes one entry or prunes by filters. Prune is destructive: without
/// `--yes` it shows the newest matches (a dry run) and asks for
/// confirmation on stdin.
fn runPrune(init: std.process.Init, options: HistoryOptions) !void {
    const connector = try RuntimeConnector.init(init, options.socket);
    var connection = try connector.connectOrStart(.{});
    defer connection.deinit(init.io);
    var stdout_buffer: [512]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const writer = &output.interface;

    var send_buffer: [4096]u8 = undefined;
    if (options.action == .delete) {
        try connection.send(init.io, try encodeDeleteHistory_module(&send_buffer, .{
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
        try connection.send(init.io, try encodeQueryHistory_module(&send_buffer, .{
            .request_id = @enumFromInt(1),
            .query = match,
            .scope = options.scope,
            .scope_value = scope_value,
            .pane_id = options.pane_id,
            .failed_only = options.failed_only,
            .limit = max_history_results_module,
        }));
        const receive_buffer = try init.gpa.alloc(u8, max_frame_size_module);
        defer init.gpa.free(receive_buffer);
        const response = try decodeServer_module(try connection.receive(init.io, receive_buffer));
        const results = switch (response) {
            .history_results => |results| results,
            .request_failed => |failure| {
                std.debug.print("telar history: {s}\n", .{failure.message});
                return error.HistoryQueryFailed;
            },
            else => return error.UnexpectedRuntimeResponse,
        };
        if (options.before_ms != 0) {
            try writer.print("{d} newest entries match the text/scope filters; --before applies on top and is not previewable\n", .{results.entry_count});
        } else {
            try writer.print("would remove {d} entries (counting at most the newest {d})\n", .{ results.entry_count, max_history_results_module });
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

    try connection.send(init.io, try encodePruneHistory_module(&send_buffer, .{
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

test "history prune confirmation stops reading at newline" {
    var reader = std.Io.Reader.fixed("yes\nstill open");

    try std.testing.expect(confirmPrune(&reader));
    try std.testing.expectEqualStrings("still open", reader.buffered());
}

test "history prune confirmation rejects any other line" {
    var rejected = std.Io.Reader.fixed("no\n");
    var empty = std.Io.Reader.fixed("");

    try std.testing.expect(!confirmPrune(&rejected));
    try std.testing.expect(!confirmPrune(&empty));
}

fn receivePruned(init: std.process.Init, connection: *SocketChannelType) !u64 {
    var receive_buffer: [1024]u8 = undefined;
    const response = try decodeServer_module(try connection.receive(init.io, &receive_buffer));
    return switch (response) {
        .history_pruned => |pruned| pruned.removed,
        .request_failed => |failure| blk: {
            std.debug.print("telar history: {s}\n", .{failure.message});
            break :blk error.HistoryPruneFailed;
        },
        else => error.UnexpectedRuntimeResponse,
    };
}

/// Prints the captured output of one exact entry, raw, to stdout.
fn runShow(init: std.process.Init, options: HistoryOptions) !void {
    const connector = try RuntimeConnector.init(init, options.socket);
    var connection = try connector.connectOrStart(.{});
    defer connection.deinit(init.io);

    var send_buffer: [64]u8 = undefined;
    try connection.send(init.io, try encodeReadHistoryOutput_module(&send_buffer, .{
        .request_id = @enumFromInt(1),
        .id = options.delete_id,
    }));

    const receive_buffer = try init.gpa.alloc(u8, max_frame_size_module);
    defer init.gpa.free(receive_buffer);
    const response = try decodeServer_module(try connection.receive(init.io, receive_buffer));
    const output = switch (response) {
        .history_output => |value| value,
        .request_failed => |failure| {
            std.debug.print("telar history: {s}\n", .{failure.message});
            return error.HistoryQueryFailed;
        },
        else => return error.UnexpectedRuntimeResponse,
    };

    if (output.observed_bytes == 0) {
        std.debug.print("telar history: no output captured for entry {d} (runtime.history.output = \"bounded\" enables capture)\n", .{output.id});
        return;
    }

    var stdout_buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    try writer.interface.writeAll(output.content);
    try writer.interface.flush();
    if (output.truncated) {
        std.debug.print("telar history: output truncated ({d} bytes observed)\n", .{output.observed_bytes});
    }
}

/// Prints aggregate history statistics for one scope and period.
fn runStats(init: std.process.Init, options: HistoryOptions) !void {
    const connector = try RuntimeConnector.init(init, options.socket);
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
    try connection.send(init.io, try encodeHistoryStatsQuery_module(&send_buffer, .{
        .request_id = @enumFromInt(1),
        .scope = options.scope,
        .scope_value = scope_value,
        .pane_id = options.pane_id,
        .since_ms = since_ms,
    }));

    const receive_buffer = try init.gpa.alloc(u8, max_frame_size_module);
    defer init.gpa.free(receive_buffer);
    const response = try decodeServer_module(try connection.receive(init.io, receive_buffer));
    const stats = switch (response) {
        .history_stats_result => |value| value,
        .request_failed => |failure| {
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
