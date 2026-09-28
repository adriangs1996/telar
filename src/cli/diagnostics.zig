const client = @import("telar-client");
const std = @import("std");
const Options = @import("arguments/DiagnosticsOptions.zig");
const RuntimeConnector = client.RuntimeConnector;
const Log = @import("DiagnosticLog.zig");
const native = @cImport({
    @cInclude("fcntl.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
});
const max_files = 64;
const max_directory_entries = 4096;

/// Reads existing runtime/client telemetry without connecting. Example: `std.process.exit(diagnostics.run(init, options));`
pub fn run(init: std.process.Init, options: Options) u8 {
    execute(init, options) catch |err| {
        std.debug.print("telar diagnostics: {s}\n", .{@errorName(err)});
        return if (err == error.DiagnosticLogsNotFound) 2 else 1;
    };
    return 0;
}

fn execute(init: std.process.Init, options: Options) !void {
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
        var stat: native.struct_stat = undefined;
        if (native.fstat(fd, &stat) != 0 or (stat.st_mode & native.S_IFMT) != native.S_IFREG or stat.st_uid != native.getuid()) {
            return error.UnsafeDiagnosticLog;
        }

        const size = std.math.cast(u64, stat.st_size) orelse return error.InvalidLogSize;
        const offset = size -| Log.max_tail_bytes;
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
