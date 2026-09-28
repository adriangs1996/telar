const std = @import("std");
const Request = @import("Request.zig");
const Task = @import("Task.zig");
const render = @import("render.zig");

const drain = "while IFS= read -r line; do :; done\n";
const spin = "while :; do :; done\n";
const close_output = "exec 1>&-\nexec 2>&-\n";
const valid_image = "printf 'TLRD\\001\\000\\000\\000\\001\\000\\000\\000\\000\\000\\200\\077\\000\\000\\200\\077\\000\\000\\000\\000\\200\\000\\000\\200'\n";

test "diagram render adopts exact pixels and reaps a successful helper" {
    var fixture = try Fixture.init(drain ++ valid_image);
    defer fixture.deinit();
    var task = fixture.task(2000);
    var image = try render.renderTask(&task);
    defer image.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), image.width);
    try std.testing.expectEqualSlices(u8, &.{ 128, 0, 0, 128 }, image.pixels);
    try fixture.expectReaped();
}

test "diagram render deadline kills and reaps a helper that never consumes stdin" {
    var fixture = try Fixture.init(spin);
    defer fixture.deinit();
    // JSON escaping makes this larger than the host pipe's writable capacity.
    var source: [48 * 1024]u8 = @splat(1);
    fixture.request.source = &source;
    var task = fixture.task(1000);
    try std.testing.expectError(error.Timeout, render.renderTask(&task));
    try fixture.expectReaped();
}

test "diagram render deadline covers a helper that consumes input but produces no output" {
    var fixture = try Fixture.init(drain ++ spin);
    defer fixture.deinit();
    var task = fixture.task(1000);
    try std.testing.expectError(error.Timeout, render.renderTask(&task));
    try fixture.expectReaped();
}

test "diagram render rejects endless excess output after the exact declared payload" {
    var fixture = try Fixture.init(drain ++ valid_image ++ "while :; do printf x; done\n");
    defer fixture.deinit();
    var task = fixture.task(2000);
    try std.testing.expectError(error.DiagramLimit, render.renderTask(&task));
    try fixture.expectReaped();
}

test "diagram render deadline covers child wait after a valid image and EOF" {
    var fixture = try Fixture.init(drain ++ valid_image ++ close_output ++ spin);
    defer fixture.deinit();
    var task = fixture.task(1000);
    try std.testing.expectError(error.Timeout, render.renderTask(&task));
    try fixture.expectReaped();
}

test "diagram render cancellation joins and reaps a live helper before returning" {
    const io = std.testing.io;
    var fixture = try Fixture.init(drain ++ spin);
    defer fixture.deinit();
    var task = fixture.task(8000);
    var future = try io.concurrent(render.renderTask, .{&task});
    defer if (future.cancel(io)) |value| {
        var image = value;
        image.deinit(std.testing.allocator);
    } else |_| {};
    _ = try fixture.awaitPid();
    try std.testing.expectError(error.Canceled, future.cancel(io));
    try fixture.expectReaped();
}

test "diagram render preserves explicit helper failure classifications" {
    inline for (.{ .{ "exit 3", error.UnsupportedDiagram }, .{ "exit 4", error.DiagramLimit } }) |case| {
        var fixture = try Fixture.init(drain ++ case[0]);
        defer fixture.deinit();
        var task = fixture.task(2000);
        try std.testing.expectError(case[1], render.renderTask(&task));
        try fixture.expectReaped();
    }
}

test "diagram render forcibly terminates a helper that ignores TERM" {
    var fixture = try Fixture.init("trap '' TERM\n" ++ drain ++ valid_image ++ close_output ++ spin);
    defer fixture.deinit();
    var task = fixture.task(1000);
    try std.testing.expectError(error.Timeout, render.renderTask(&task));
    try fixture.expectReaped();
}

/// A helper made only of shell builtins, so terminating it leaves no descendants.
const Fixture = struct {
    temp: std.testing.TmpDir,
    executable: [:0]u8,
    executables: [1][]const u8 = undefined,
    request: Request = .{ .source = "A", .scale = 1, .theme = .{ .bg = .{ 0, 0, 0 }, .fg = .{ 255, 255, 255 }, .accent = .{ 0, 128, 255 } } },

    /// Writes the helper and runs it once, so the host's first-exec cost is
    /// paid before any render deadline starts counting.
    /// Example: `var fixture = try Fixture.init("exit 4");`
    pub fn init(body: []const u8) !Fixture {
        const io = std.testing.io;
        const allocator = std.testing.allocator;
        var temp = std.testing.tmpDir(.{});
        errdefer temp.cleanup();

        // The render passes no arguments; the warm-up passes one and stops
        // before the helper records a pid or reads its body.
        const script = try std.fmt.allocPrint(allocator, "#!/bin/sh\n[ \"$#\" -eq 0 ] || exit 0\nprintf '%s' \"$$\" > \"$0.pid\"\n{s}\n", .{body});
        defer allocator.free(script);
        try temp.dir.writeFile(io, .{ .sub_path = "helper", .data = script, .flags = .{ .permissions = .executable_file } });
        const executable = try temp.dir.realPathFileAlloc(io, "helper", allocator);
        errdefer allocator.free(executable);

        try warm(executable);
        return .{ .temp = temp, .executable = executable };
    }

    /// macOS assesses a new executable on its first exec. Under load that took
    /// up to 1.7 s, long enough for a 1000 ms deadline to kill the helper
    /// before its first builtin. Later execs of the same file take milliseconds.
    fn warm(executable: []const u8) !void {
        const io = std.testing.io;
        var child = try std.process.spawn(io, .{ .argv = &.{ executable, "warm" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
        defer child.kill(io);

        const term = try child.wait(io);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
    }

    pub fn deinit(self: *Fixture) void {
        std.testing.allocator.free(self.executable);
        self.temp.cleanup();
    }

    /// Example: `var task = fixture.task(250);`
    pub fn task(self: *Fixture, timeout_ms: u32) Task {
        self.executables = .{self.executable};
        return .{ .io = std.testing.io, .allocator = std.testing.allocator, .request = self.request, .executables = &self.executables, .timeout_ms = timeout_ms };
    }

    /// Waits only for the child's first builtin, without requiring a model or network.
    /// Example: `const pid = try fixture.awaitPid();`
    pub fn awaitPid(self: *Fixture) !std.posix.pid_t {
        const io = std.testing.io;
        const started = std.Io.Timestamp.now(io, .awake);
        while (std.Io.Timestamp.now(io, .awake).toMilliseconds() - started.toMilliseconds() < 2000) {
            if (try self.readPid()) |pid| {
                return pid;
            }

            try io.sleep(.fromMilliseconds(1), .awake);
        }

        return error.HelperDidNotStart;
    }

    /// A zombie still answers signal zero: ESRCH proves the child was also reaped.
    /// Once the render returns the helper is gone, so a missing pid means it
    /// never reached its first builtin and the test did not run its scenario.
    /// Example: `try fixture.expectReaped();`
    pub fn expectReaped(self: *Fixture) !void {
        const pid = try self.readPid() orelse return error.HelperDidNotStart;
        try std.testing.expectError(error.ProcessNotFound, std.posix.kill(pid, @enumFromInt(0)));
    }

    fn readPid(self: *Fixture) !?std.posix.pid_t {
        var buffer: [32]u8 = undefined;
        const bytes = self.temp.dir.readFile(std.testing.io, "helper.pid", &buffer) catch |err| {
            if (err == error.FileNotFound) {
                return null;
            }

            return err;
        };

        return std.fmt.parseInt(std.posix.pid_t, bytes, 10) catch null;
    }
};
