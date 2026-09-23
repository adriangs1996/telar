const std = @import("std");
const Job = @import("Job.zig");
const Task = @import("ProcessTask.zig");
const worker = @import("worker.zig");

const drain = "while IFS= read -r line; do :; done\n";
const spin = "while :; do :; done\n";
const close_output = "exec 1>&-\nexec 2>&-\n";
const valid_image = "printf 'TLRD\\001\\000\\000\\000\\001\\000\\000\\000\\000\\000\\200\\077\\000\\000\\200\\077\\000\\000\\000\\000\\200\\000\\000\\200'\n";

test "diagram worker adopts exact pixels and reaps a successful helper" {
    var fixture = try Fixture.init(drain ++ valid_image);
    defer fixture.deinit();
    var task = fixture.task(2000);
    var image = try worker.renderTask(&task);
    defer image.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), image.width);
    try std.testing.expectEqualSlices(u8, &.{ 128, 0, 0, 128 }, image.pixels);
    try fixture.expectReaped();
}

test "diagram worker deadline kills and reaps a helper that never consumes stdin" {
    var fixture = try Fixture.init(spin);
    defer fixture.deinit();
    // JSON escaping makes this larger than the host pipe's writable capacity.
    @memset(&fixture.job.source, 1);
    fixture.job.len = fixture.job.source.len;
    var task = fixture.task(1000);
    try std.testing.expectError(error.Timeout, worker.renderTask(&task));
    try fixture.expectReaped();
}

test "diagram worker deadline covers a helper that consumes input but produces no output" {
    var fixture = try Fixture.init(drain ++ spin);
    defer fixture.deinit();
    var task = fixture.task(1000);
    try std.testing.expectError(error.Timeout, worker.renderTask(&task));
    try fixture.expectReaped();
}

test "diagram worker rejects endless excess output after the exact declared payload" {
    var fixture = try Fixture.init(drain ++ valid_image ++ "while :; do printf x; done\n");
    defer fixture.deinit();
    var task = fixture.task(2000);
    try std.testing.expectError(error.DiagramLimit, worker.renderTask(&task));
    try fixture.expectReaped();
}

test "diagram worker deadline covers child wait after a valid image and EOF" {
    var fixture = try Fixture.init(drain ++ valid_image ++ close_output ++ spin);
    defer fixture.deinit();
    var task = fixture.task(1000);
    try std.testing.expectError(error.Timeout, worker.renderTask(&task));
    try fixture.expectReaped();
}

test "diagram worker cancellation joins and reaps a live helper before returning" {
    const io = std.testing.io;
    var fixture = try Fixture.init(drain ++ spin);
    defer fixture.deinit();
    var task = fixture.task(8000);
    var future = try io.concurrent(worker.renderTask, .{&task});
    defer if (future.cancel(io)) |value| {
        var image = value;
        image.deinit(std.testing.allocator);
    } else |_| {};
    _ = try fixture.awaitPid();
    try std.testing.expectError(error.Canceled, future.cancel(io));
    try fixture.expectReaped();
}

test "diagram worker preserves explicit helper failure classifications" {
    inline for (.{ .{ "exit 3", error.UnsupportedDiagram }, .{ "exit 4", error.DiagramLimit } }) |case| {
        var fixture = try Fixture.init(drain ++ case[0]);
        defer fixture.deinit();
        var task = fixture.task(2000);
        try std.testing.expectError(case[1], worker.renderTask(&task));
        try fixture.expectReaped();
    }
}

test "diagram worker forcibly terminates a helper that ignores TERM" {
    var fixture = try Fixture.init("trap '' TERM\n" ++ drain ++ valid_image ++ close_output ++ spin);
    defer fixture.deinit();
    var task = fixture.task(1000);
    try std.testing.expectError(error.Timeout, worker.renderTask(&task));
    try fixture.expectReaped();
}

/// A helper made only of shell builtins, so terminating it leaves no descendants.
const Fixture = struct {
    temp: std.testing.TmpDir,
    executable: [:0]u8,
    job: Job = .{ .id = 1, .slot = 0, .len = 1, .source = @splat('A'), .scale = 1, .theme = .{ .bg = .{ 0, 0, 0 }, .fg = .{ 255, 255, 255 }, .accent = .{ 0, 128, 255 } } },

    /// Example: `var fixture = try Fixture.init("exit 4");`
    pub fn init(body: []const u8) !Fixture {
        const io = std.testing.io;
        const allocator = std.testing.allocator;
        var temp = std.testing.tmpDir(.{});
        errdefer temp.cleanup();
        const script = try std.fmt.allocPrint(allocator, "#!/bin/sh\nprintf '%s' \"$$\" > \"$0.pid\"\n{s}\n", .{body});
        defer allocator.free(script);
        try temp.dir.writeFile(io, .{ .sub_path = "helper", .data = script, .flags = .{ .permissions = .executable_file } });
        const executable = try temp.dir.realPathFileAlloc(io, "helper", allocator);
        return .{ .temp = temp, .executable = executable };
    }

    pub fn deinit(self: *Fixture) void {
        std.testing.allocator.free(self.executable);
        self.temp.cleanup();
    }

    /// Example: `var task = fixture.task(250);`
    pub fn task(self: *Fixture, timeout_ms: u32) Task {
        return .{ .io = std.testing.io, .allocator = std.testing.allocator, .job = &self.job, .executable = self.executable, .timeout_ms = timeout_ms };
    }

    /// Waits only for the child's first builtin, without requiring a model or network.
    /// Example: `const pid = try fixture.awaitPid();`
    pub fn awaitPid(self: *Fixture) !std.posix.pid_t {
        const io = std.testing.io;
        const started = std.Io.Timestamp.now(io, .awake);
        while (std.Io.Timestamp.now(io, .awake).toMilliseconds() - started.toMilliseconds() < 2000) {
            var buffer: [32]u8 = undefined;
            if (self.temp.dir.readFile(io, "helper.pid", &buffer)) |bytes| {
                if (std.fmt.parseInt(std.posix.pid_t, bytes, 10)) |pid| {
                    return pid;
                } else |_| {}
            } else |err| {
                if (err != error.FileNotFound) {
                    return err;
                }
            }

            try io.sleep(.fromMilliseconds(1), .awake);
        }

        return error.HelperDidNotStart;
    }

    /// A zombie still answers signal zero: ESRCH proves the child was also reaped.
    /// Example: `try fixture.expectReaped();`
    pub fn expectReaped(self: *Fixture) !void {
        const pid = try self.awaitPid();
        try std.testing.expectError(error.ProcessNotFound, std.posix.kill(pid, @enumFromInt(0)));
    }
};
