const decodeClient_module = @import("telar-core").decodeClient;
const ClientMessageType = @import("telar-core").ClientMessage;
const std = @import("std");
const LaunchViewType = @import("telar-core").LaunchView;

pub export fn zig_fuzz_init() callconv(.c) void {}

pub export fn zig_fuzz_test(buf: [*]const u8, len: usize) callconv(.c) void {
    const message = decodeClient_module(buf[0..len]) catch return;
    exercise(message) catch return;
}

fn exercise(message: ClientMessageType) !void {
    std.mem.doNotOptimizeAway(message);
    switch (message) {
        .open_pane => |payload| if (payload.launch) |launch| try exhaustLaunch(launch),
        .create_pane => |payload| try exhaustLaunch(payload.launch),
        .create_tab => |payload| try exhaustLaunch(payload.launch),
        .create_workspace => |payload| try exhaustLaunch(payload.launch),
        else => {},
    }
}

fn exhaustLaunch(launch: LaunchViewType) !void {
    var arguments = launch.arguments();
    while (try arguments.next()) |argument| {
        std.mem.doNotOptimizeAway(argument);
    }

    var environment = launch.environment();
    while (try environment.next()) |entry| {
        std.mem.doNotOptimizeAway(entry);
    }
}
