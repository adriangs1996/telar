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
    if (options.action == .import) {
        return runImport(init, options);
    }
    if (options.action == .delete or options.action == .prune) {
        return runPrune(init, options);
    }

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
        .author = options.author,
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

const max_histfile_bytes = 32 * 1024 * 1024;
const max_batch_entries = core.schema.max_import_entries;
const max_batch_payload = 48 * 1024;

/// Streams one shell histfile to the runtime in bounded idempotent batches.
/// The source label pins the deterministic import session, so re-running the
/// import only adds entries the runtime has not seen.
fn runImport(init: std.process.Init, options: HistoryOptions) !void {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = try resolveImport(init, options, &path_buffer);
    const source_data = try Io.Dir.cwd().readFileAlloc(init.io, resolved.path, init.gpa, .limited(max_histfile_bytes));
    defer init.gpa.free(source_data);

    const connector = try RuntimeConnector.init(init, options.socket);
    var connection = try connector.connectOrStart(.{});
    defer connection.deinit(init.io);

    var source_buffer: [core.schema.max_import_source_bytes]u8 = undefined;
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
    var output = File.stdout().writerStreaming(init.io, &stdout_buffer);
    try output.interface.print("imported {d} commands from {s}\n", .{ sender.total, resolved.path });
    try output.interface.flush();
}

const ResolvedImport = struct {
    kind: parser.HistoryImportKind,
    path: []const u8,
};

fn resolveImport(init: std.process.Init, options: HistoryOptions, buffer: *[std.fs.max_path_bytes]u8) !ResolvedImport {
    if (options.import_file) |file| {
        const path = std.mem.span(file);
        const kind = if (options.import_kind != .auto)
            options.import_kind
        else if (std.mem.endsWith(u8, path, "fish_history"))
            parser.HistoryImportKind.fish
        else if (std.mem.indexOf(u8, path, "bash") != null)
            parser.HistoryImportKind.bash
        else
            parser.HistoryImportKind.zsh;
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
        Io.Dir.cwd().access(init.io, path, .{}) catch continue;
        return .{ .kind = candidate.kind, .path = path };
    }

    return error.HistfileNotFound;
}

/// Line-driven histfile parser producing (timestamp, command) entries.
/// zsh extended history joins backslash continuations; plain lines fall back
/// to a zero timestamp the runtime stores as-is.
const ImportParser = struct {
    kind: parser.HistoryImportKind,
    pending_time_ms: i64 = 0,
    /// Two alternating buffers: `flush` returns a slice into the active one
    /// and `begin` switches to the other, so a finished entry stays valid
    /// while the next command starts on the same fed line.
    command_storage: [2][core.schema.max_import_command_bytes]u8 = undefined,
    active: u1 = 0,
    command_len: usize = 0,
    command_active: bool = false,

    fn feed(state: *ImportParser, raw_line: []const u8) ?ImportedEntry {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        return switch (state.kind) {
            .auto => unreachable,
            .zsh => state.feedZsh(line),
            .bash => state.feedBash(line),
            .fish => state.feedFish(line),
        };
    }

    fn flush(state: *ImportParser) ?ImportedEntry {
        if (!state.command_active or state.command_len == 0) {
            return null;
        }

        state.command_active = false;
        return .{ .started_at_ms = state.pending_time_ms, .command = state.command_storage[state.active][0..state.command_len] };
    }

    fn feedZsh(state: *ImportParser, line: []const u8) ?ImportedEntry {
        if (state.command_active) {
            if (state.command_len != 0 and state.command_storage[state.active][state.command_len - 1] == '\\') {
                state.command_len -= 1;
                state.append("\n");
                state.append(line);
                if (line.len != 0 and line[line.len - 1] == '\\') {
                    return null;
                }

                return state.flush();
            }
        }

        const finished = state.flush();
        if (std.mem.startsWith(u8, line, ": ")) {
            const semicolon = std.mem.indexOfScalar(u8, line, ';') orelse return finished;
            const meta = line[2..semicolon];
            const colon = std.mem.indexOfScalar(u8, meta, ':') orelse return finished;
            const seconds = std.fmt.parseInt(i64, meta[0..colon], 10) catch 0;
            state.begin(seconds * 1_000, line[semicolon + 1 ..]);
            if (line.len != 0 and line[line.len - 1] == '\\') {
                return finished;
            }
        } else if (line.len != 0) {
            state.begin(0, line);
        } else {
            return finished;
        }

        if (state.command_len != 0 and state.command_storage[state.active][state.command_len - 1] == '\\') {
            return finished;
        }
        if (finished) |value| {
            // Two complete commands cannot finish on one line; the previous
            // one is returned and the current one waits for the next feed.
            return value;
        }

        return state.flush();
    }

    fn feedBash(state: *ImportParser, line: []const u8) ?ImportedEntry {
        if (line.len > 1 and line[0] == '#') {
            const seconds = std.fmt.parseInt(i64, line[1..], 10) catch return state.emitPlain(line);
            const finished = state.flush();
            state.pending_time_ms = seconds * 1_000;
            return finished;
        }

        return state.emitPlain(line);
    }

    fn emitPlain(state: *ImportParser, line: []const u8) ?ImportedEntry {
        if (line.len == 0) {
            return null;
        }

        const finished = state.flush();
        const time = state.pending_time_ms;
        state.begin(time, line);
        if (finished) |value| {
            return value;
        }

        return state.flush();
    }

    fn feedFish(state: *ImportParser, line: []const u8) ?ImportedEntry {
        if (std.mem.startsWith(u8, line, "- cmd: ")) {
            const finished = state.flush();
            state.begin(0, line["- cmd: ".len..]);
            state.command_active = true;
            if (finished) |value| {
                return value;
            }

            return null;
        }
        if (std.mem.startsWith(u8, line, "  when: ")) {
            const seconds = std.fmt.parseInt(i64, line["  when: ".len..], 10) catch 0;
            state.pending_time_ms = seconds * 1_000;
            return state.flush();
        }

        return null;
    }

    fn begin(state: *ImportParser, time_ms: i64, command: []const u8) void {
        state.active ^= 1;
        state.pending_time_ms = time_ms;
        state.command_len = 0;
        state.command_active = true;
        state.append(command);
    }

    fn append(state: *ImportParser, bytes: []const u8) void {
        const buffer = &state.command_storage[state.active];
        const room = buffer.len - state.command_len;
        const take = @min(room, bytes.len);
        @memcpy(buffer[state.command_len .. state.command_len + take], bytes[0..take]);
        state.command_len += take;
    }
};

const ImportedEntry = struct {
    started_at_ms: i64,
    command: []const u8,
};

/// Accumulates entries and sends one bounded import_history request per
/// batch, waiting for each acknowledgement before the next batch.
const BatchSender = struct {
    io: Io,
    gpa: std.mem.Allocator,
    connection: *core.transport.SocketChannel,
    source: []const u8,
    entries: [max_batch_entries]core.schema.ImportEntry = undefined,
    storage: [max_batch_payload]u8 = undefined,
    used: usize = 0,
    count: usize = 0,
    sequence: u64 = 0,
    total: u64 = 0,
    next_request: u64 = 1,

    fn push(sender: *BatchSender, entry: ImportedEntry) !void {
        if (entry.command.len == 0 or entry.command.len > core.schema.max_import_command_bytes) {
            return;
        }
        if (sender.count == max_batch_entries or entry.command.len > sender.storage.len - sender.used) {
            try sender.finish();
        }

        const copy = sender.storage[sender.used .. sender.used + entry.command.len];
        @memcpy(copy, entry.command);
        sender.used += entry.command.len;
        sender.entries[sender.count] = .{ .started_at_ms = entry.started_at_ms, .command = copy };
        sender.count += 1;
    }

    fn finish(sender: *BatchSender) !void {
        if (sender.count == 0) {
            return;
        }

        var send_buffer: [max_batch_payload + 1024]u8 = undefined;
        const request_id: core.schema.RequestId = @enumFromInt(sender.next_request);
        sender.next_request += 1;
        try sender.connection.send(sender.io, try core.schema.encodeImportHistory(&send_buffer, .{
            .request_id = request_id,
            .source = sender.source,
            .base_sequence = sender.sequence,
            .entries = sender.entries[0..sender.count],
        }));

        var receive_buffer: [1024]u8 = undefined;
        const response = try core.schema.decodeServer(try sender.connection.receive(sender.io, &receive_buffer));
        switch (response) {
            .request_completed => {},
            .request_failed => |failure| {
                std.debug.print("telar history import: {s}\n", .{failure.message});
                return error.HistoryImportFailed;
            },
            else => return error.UnexpectedRuntimeResponse,
        }

        sender.sequence += sender.count;
        sender.total += sender.count;
        sender.count = 0;
        sender.used = 0;
    }
};

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
    var output = File.stdout().writerStreaming(init.io, &stdout_buffer);
    const writer = &output.interface;

    var send_buffer: [4096]u8 = undefined;
    if (options.action == .delete) {
        try connection.send(init.io, try core.schema.encodeDeleteHistory(&send_buffer, .{
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
            const len = try Io.Dir.cwd().realPathFile(init.io, ".", &cwd_buffer);
            break :cwd cwd_buffer[0..len];
        },
        .workspace => std.mem.span(options.scope_value.?),
        .global, .pane => "",
    };
    const match = if (options.query) |value| std.mem.span(value) else "";

    if (options.dry_run or !options.assume_yes) {
        try connection.send(init.io, try core.schema.encodeQueryHistory(&send_buffer, .{
            .request_id = @enumFromInt(1),
            .query = match,
            .scope = options.scope,
            .scope_value = scope_value,
            .pane_id = options.pane_id,
            .failed_only = options.failed_only,
            .limit = core.schema.max_history_results,
        }));
        const receive_buffer = try init.gpa.alloc(u8, core.transport.max_frame_size);
        defer init.gpa.free(receive_buffer);
        const response = try core.schema.decodeServer(try connection.receive(init.io, receive_buffer));
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
            try writer.print("would remove {d} entries (counting at most the newest {d})\n", .{ results.entry_count, core.schema.max_history_results });
        }
        try writer.flush();
        if (options.dry_run) {
            return;
        }

        try writer.writeAll("prune permanently? type yes to continue: ");
        try writer.flush();
        var line_buffer: [16]u8 = undefined;
        var stdin_reader = File.stdin().readerStreaming(init.io, &.{});
        const len = stdin_reader.interface.readSliceShort(&line_buffer) catch 0;
        const answer = std.mem.trim(u8, line_buffer[0..len], " \r\n");
        if (!std.mem.eql(u8, answer, "yes")) {
            try writer.writeAll("aborted\n");
            try writer.flush();
            return;
        }
    }

    try connection.send(init.io, try core.schema.encodePruneHistory(&send_buffer, .{
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

fn receivePruned(init: std.process.Init, connection: *core.transport.SocketChannel) !u64 {
    var receive_buffer: [1024]u8 = undefined;
    const response = try core.schema.decodeServer(try connection.receive(init.io, &receive_buffer));
    return switch (response) {
        .history_pruned => |pruned| pruned.removed,
        .request_failed => |failure| blk: {
            std.debug.print("telar history: {s}\n", .{failure.message});
            break :blk error.HistoryPruneFailed;
        },
        else => error.UnexpectedRuntimeResponse,
    };
}
