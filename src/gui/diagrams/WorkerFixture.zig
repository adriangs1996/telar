//! A helper made only of shell builtins, so terminating it leaves no descendants.
const std = @import("std");
const Job = @import("Job.zig");
const Task = @import("ProcessTask.zig");
const Fixture = @This();

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

pub fn deinit(fixture: *Fixture) void {
    std.testing.allocator.free(fixture.executable);
    fixture.temp.cleanup();
}

/// Example: `var task = fixture.task(250);`
pub fn task(fixture: *Fixture, timeout_ms: u32) Task {
    return .{ .io = std.testing.io, .allocator = std.testing.allocator, .job = &fixture.job, .executable = fixture.executable, .timeout_ms = timeout_ms };
}

/// Waits only for the child's first builtin, without requiring a model or network.
/// Example: `const pid = try fixture.awaitPid();`
pub fn awaitPid(fixture: *Fixture) !std.posix.pid_t {
    const io = std.testing.io;
    const started = std.Io.Timestamp.now(io, .awake);
    while (std.Io.Timestamp.now(io, .awake).toMilliseconds() - started.toMilliseconds() < 2000) {
        var buffer: [32]u8 = undefined;
        if (fixture.temp.dir.readFile(io, "helper.pid", &buffer)) |bytes| {
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
pub fn expectReaped(fixture: *Fixture) !void {
    const pid = try fixture.awaitPid();
    try std.testing.expectError(error.ProcessNotFound, std.posix.kill(pid, @enumFromInt(0)));
}
