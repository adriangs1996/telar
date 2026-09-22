const core = @import("telar-core");
const std = @import("std");

pub export fn zig_fuzz_init() callconv(.c) void {}

pub export fn zig_fuzz_test(buf: [*]const u8, len: usize) callconv(.c) void {
    const message = core.decodeClient(buf[0..len]) catch return;
    exercise(message) catch return;
}

fn exercise(message: core.ClientMessage) !void {
    std.mem.doNotOptimizeAway(message);
    switch (message) {
        .open_pane => |payload| if (payload.launch) |launch| try exhaustLaunch(launch),
        .create_pane => |payload| try exhaustLaunch(payload.launch),
        .create_tab => |payload| try exhaustLaunch(payload.launch),
        .create_workspace => |payload| try exhaustLaunch(payload.launch),
        else => {},
    }
}

fn exhaustLaunch(launch: core.LaunchView) !void {
    var arguments = launch.arguments();
    while (try arguments.next()) |argument| {
        std.mem.doNotOptimizeAway(argument);
    }

    var environment = launch.environment();
    while (try environment.next()) |entry| {
        std.mem.doNotOptimizeAway(entry);
    }
}
