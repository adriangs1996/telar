const std = @import("std");
const core = @import("telar-core");
const Options = @import("HistoryOptions.zig");
const Provider = @import("ProviderHistory.zig");
const Fixture = @This();

temp: std.testing.TmpDir,
executable: [:0]u8,
timeout_ms: u32 = 3000,

/// Example: `var fixture = try HistoryFixture.init(fake_provider);`
pub fn init(body: []const u8) !Fixture {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    errdefer temp.cleanup();
    const script = try std.fmt.allocPrint(gpa, "#!/bin/sh\nprintf '%s' \"$$\" > \"$0.pid\"\n{s}\n", .{body});
    defer gpa.free(script);
    try temp.dir.writeFile(io, .{ .sub_path = "provider", .data = script, .flags = .{ .permissions = .executable_file } });
    const executable = try temp.dir.realPathFileAlloc(io, "provider", gpa);
    return .{ .temp = temp, .executable = executable };
}

/// Example: `fixture.deinit();`
pub fn deinit(fixture: *Fixture) void {
    std.testing.allocator.free(fixture.executable);
    fixture.temp.cleanup();
}

/// Example: `const page = try fixture.read(query);`
pub fn read(fixture: *Fixture, query: core.QueryAgentHistory) !*core.AgentHistoryPage {
    var arguments = [_][]const u8{fixture.executable};
    var options: Options = .{
        .gpa = std.testing.allocator,
        .cwd = "/tmp",
        .arguments = &arguments,
        .environment = .init(std.testing.allocator),
        .timeout_ms = fixture.timeout_ms,
    };
    defer options.environment.deinit();
    return Provider.read(std.testing.io, std.testing.allocator, .{ .options = &options, .query = query, .thread_id = "thread-1" });
}

/// Example: `_ = try fixture.awaitPid();`
pub fn awaitPid(fixture: *Fixture) !std.posix.pid_t {
    const io = std.testing.io;
    const started = std.Io.Timestamp.now(io, .awake);
    while (std.Io.Timestamp.now(io, .awake).toMilliseconds() - started.toMilliseconds() < 2000) {
        if (try fixture.publishedPid()) |pid| {
            return pid;
        }

        try io.sleep(.fromMilliseconds(1), .awake);
    }

    return error.ProviderDidNotStart;
}

/// A child still awaiting waitpid answers signal zero too.
/// Example: `try fixture.expectReaped();`
pub fn expectReaped(fixture: *Fixture) !void {
    const pid = try fixture.awaitPid();
    try std.testing.expectError(error.ProcessNotFound, std.posix.kill(pid, @enumFromInt(0)));
}

/// The outer deadline can expire before the shell publishes its PID. Call only
/// after the read has joined, so an absent PID cannot appear later.
/// Example: `try fixture.expectReapedIfPublished();`
pub fn expectReapedIfPublished(fixture: *Fixture) !void {
    const pid = try fixture.publishedPid() orelse return;
    try std.testing.expectError(error.ProcessNotFound, std.posix.kill(pid, @enumFromInt(0)));
}

fn publishedPid(fixture: *Fixture) !?std.posix.pid_t {
    var buffer: [32]u8 = undefined;
    const bytes = fixture.temp.dir.readFile(std.testing.io, "provider.pid", &buffer) catch |err| {
        if (err == error.FileNotFound) {
            return null;
        }
        return err;
    };
    if (bytes.len == 0) {
        return null;
    }
    return try std.fmt.parseInt(std.posix.pid_t, bytes, 10);
}
