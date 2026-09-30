const client = @import("telar-client");
const core = @import("telar-core");
const std = @import("std");
const Session = @import("Session.zig");
const Options = @import("arguments/DiagnosticsOptions.zig");
const RuntimeConnector = client.RuntimeConnector;
const Log = @import("DiagnosticLog.zig");
const privatefile = @import("privatefile");
const Inode = privatefile.Inode;
const native = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});
const max_files = 64;
const max_directory_entries = 4096;

/// `logs` reads the runtime's log and the telemetry beside the socket
/// without connecting; `limits` lists the limits the runtime and its
/// windows reached. Example: `std.process.exit(diagnostics.run(init, options));`
pub fn run(init: std.process.Init, options: Options) u8 {
    const result = switch (options.action) {
        .logs => readLogs(init, options),
        .limits => listLimits(init, options),
    };
    result catch |err| {
        std.debug.print("telar diagnostics: {s}\n", .{@errorName(err)});
        if (err == error.DiagnosticLogsNotFound) {
            std.debug.print(
                "  the background runtime writes {s} beside its socket once it starts;\n" ++
                    "  per-process telemetry needs a build with -Ddiagnostics.\n",
                .{core.DiagnosticLogName.runtime_log_suffix},
            );
        }

        return if (err == error.DiagnosticLogsNotFound) 2 else 1;
    };
    return 0;
}

fn readLogs(init: std.process.Init, options: Options) !void {
    const connector = try RuntimeConnector.init(init.io, init.minimal.environ, options.socket);
    const endpoint = connector.endpointPath();
    const parent = std.fs.path.dirname(endpoint) orelse return error.InvalidSocketPath;
    const base = std.fs.path.basename(endpoint);
    var directory = std.Io.Dir.openDirAbsolute(init.io, parent, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.DiagnosticLogsNotFound,
        else => return err,
    };
    defer directory.close(init.io);
    var logs: std.ArrayList(Log) = .empty;
    defer {
        for (logs.items) |log| {
            init.gpa.free(log.name);
        }

        logs.deinit(init.gpa);
    }
    var iterator = directory.iterate();
    var visited: usize = 0;
    while (try iterator.next(init.io)) |entry| {
        visited += 1;
        if (visited > max_directory_entries) {
            return error.TooManyDirectoryEntries;
        }
        if (entry.kind != .file) {
            continue;
        }

        var log = Log.parse(entry.name, base) orelse continue;
        if ((options.component != .all and log.component != options.component) or (options.pid != null and log.pid != options.pid.?)) {
            continue;
        }
        if (logs.items.len == max_files) {
            return error.TooManyDiagnosticLogs;
        }

        log.name = try init.gpa.dupe(u8, log.name);
        errdefer init.gpa.free(log.name);
        try logs.append(init.gpa, log);
    }

    if (options.component != .client and options.pid == null) {
        var runtime_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const runtime_name = try std.fmt.bufPrint(&runtime_name_buffer, "{s}{s}", .{ base, core.DiagnosticLogName.runtime_log_suffix });
        if (directory.statFile(init.io, runtime_name, .{})) |_| {
            try logs.append(init.gpa, .{
                .name = try init.gpa.dupe(u8, runtime_name),
                .component = .runtime,
                .pid = 0,
            });
        } else |_| {}
    }

    if (logs.items.len == 0) {
        return error.DiagnosticLogsNotFound;
    }

    std.mem.sort(Log, logs.items, {}, lessThan);
    var output = std.Io.Writer.Allocating.init(init.gpa);
    defer output.deinit();
    if (options.json) {
        try output.writer.writeByte('[');
    }

    for (logs.items, 0..) |log, index| {
        var name_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const name = try std.fmt.bufPrintZ(&name_buffer, "{s}", .{log.name});
        const fd = native.openat(directory.handle, name.ptr, native.O_RDONLY | native.O_NOFOLLOW | native.O_NONBLOCK | native.O_CLOEXEC);
        if (fd < 0) {
            return error.CannotOpenDiagnosticLog;
        }

        const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
        defer file.close(init.io);
        const inode = Inode.fromDescriptor(fd) catch return error.UnsafeDiagnosticLog;
        if (inode.kind() != .regular or inode.owner != native.getuid()) {
            return error.UnsafeDiagnosticLog;
        }

        const offset = inode.size -| Log.max_tail_bytes;
        var bytes: [Log.max_tail_bytes]u8 = undefined;
        const read = try file.readPositionalAll(init.io, &bytes, offset);
        const start = if (offset != 0) (std.mem.indexOfScalar(u8, bytes[0..read], '\n') orelse return error.DiagnosticLineTooLong) + 1 else 0;
        const tail = Log.tail(bytes[start..read], options.lines);
        const truncated = offset != 0 or tail.len < read - start;
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ parent, log.name });
        if (options.json) {
            if (index != 0) {
                try output.writer.writeByte(',');
            }

            try std.json.Stringify.value(.{ .path = path, .component = log.component, .pid = log.pid, .truncated = truncated, .text = tail }, .{}, &output.writer);
        } else {
            try output.writer.print("{s}{s}\n{s}", .{ path, if (truncated) " (tail)" else "", tail });
            if (tail.len == 0 or tail[tail.len - 1] != '\n') {
                try output.writer.writeByte('\n');
            }
        }
    }

    if (options.json) {
        try output.writer.writeAll("]\n");
    }

    try std.Io.File.stdout().writeStreamingAll(init.io, output.written());
}

fn lessThan(_: void, left: Log, right: Log) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}

/// Asks a listening runtime for its limit registry and prints one line per
/// limit, or JSON with `--json`. Never starts a runtime.
fn listLimits(init: std.process.Init, options: Options) !void {
    var session = try Session.attach(init, options.socket);
    defer session.close();

    const response = try session.exchange(core.encodeQueryLimits, core.QueryLimits{ .request_id = .none });
    if (response != .limit_list) {
        return error.UnexpectedRuntimeResponse;
    }

    var output = std.Io.Writer.Allocating.init(init.gpa);
    defer output.deinit();
    try writeLimits(&output.writer, response.limit_list, options.json);
    try std.Io.File.stdout().writeStreamingAll(init.io, output.written());
}

fn writeLimits(writer: *std.Io.Writer, list: core.LimitListView, json: bool) !void {
    var entries = list.entries();
    if (json) {
        try writer.writeByte('[');
        var first = true;
        while (try entries.next()) |entry| {
            if (!first) {
                try writer.writeByte(',');
            }

            first = false;
            try std.json.Stringify.value(.{
                .name = entry.reach.limit.name,
                .noun = entry.reach.limit.noun,
                .value = entry.reach.limit.value,
                .requested = entry.reach.requested,
                .origin = @tagName(entry.origin),
                .hits = entry.hits,
                .last_ms = entry.last_ms,
            }, .{}, writer);
        }

        try writer.writeAll("]\n");
        return;
    }

    if (list.entry_count == 0) {
        try writer.writeAll("no limit reached\n");
        return;
    }

    while (try entries.next()) |entry| {
        var buffer: [core.LimitReach.max_description_bytes]u8 = undefined;
        const seconds: u64 = @intCast(@max(0, @divFloor(entry.last_ms, std.time.ms_per_s)));
        const day = (std.time.epoch.EpochSeconds{ .secs = seconds }).getDaySeconds();
        try writer.print("{s}  ({s}, last {d:0>2}:{d:0>2}:{d:0>2} UTC)\n", .{
            entry.reach.describe(&buffer, entry.hits),
            @tagName(entry.origin),
            day.getHoursIntoDay(),
            day.getMinutesIntoHour(),
            day.getSecondsIntoMinute(),
        });
    }
}

test "limits print one line per limit with where and when it was last reached" {
    var reaches: core.LimitReaches = .{};
    _ = reaches.record(
        .{
            .limit = .{
                .name = "bars.max_bar_actions",
                .noun = "click actions",
                .value = 4,
            },
            .requested = 17,
        },
        .client,
        45_296_000,
        3,
    );

    var wire: [512]u8 = undefined;
    const bytes = try core.encodeLimitList(&wire, @enumFromInt(1), &reaches);
    const decoded = try core.decodeServer(bytes);

    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeLimits(&writer, decoded.limit_list, false);
    try std.testing.expectEqualStrings("bars.max_bar_actions: 17 click actions; limit 4 (3 times)  (client, last 12:34:56 UTC)\n", writer.buffered());

    writer = .fixed(&buffer);
    try writeLimits(&writer, decoded.limit_list, true);
    try std.testing.expectEqualStrings("[{\"name\":\"bars.max_bar_actions\",\"noun\":\"click actions\",\"value\":4,\"requested\":17,\"origin\":\"client\",\"hits\":3,\"last_ms\":45296000}]\n", writer.buffered());
}
