//! Native wake endpoint and the GUI consumer of the shared bounded inbox.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const native = @import("native/native.zig");
const GuiClient = @import("GuiClient.zig");
const Inbox = @import("gui_event.zig").Inbox;
const Loop = @This();

io: std.Io,
fds: [2]c_int,
inbox: Inbox,
configuration: @import("ConfigurationReload.zig"),

pub fn init(io: std.Io) !Loop {
    var fds: [2]c_int = undefined;
    if (native.telar_gui_pipe(&fds) != 0) {
        return error.WakePipeFailed;
    }

    return .{
        .io = io,
        .fds = fds,
        .inbox = .init(
            io,
            .{
                .context = @intCast(fds[1]),
                .notify_fn = wake,
            },
        ),
        .configuration = .{
            .io = io,
        },
    };
}

fn wake(fd: usize) void {
    native.telar_gui_wake(@intCast(fd));
}

/// Revoke admission, join producers, then release their wake endpoint.
/// Example: `loop.deinit();`
pub fn deinit(loop: *Loop) void {
    loop.inbox.close();
    loop.configuration.deinit();
    loop.inbox.deinit();
    native.telar_gui_close_pipe(&loop.fds);
}

pub fn startRead(loop: *Loop, state: *client.RuntimeTransportState) !void {
    try loop.inbox.start(.server, .{ client.RuntimeTransportState.read, .{ state, loop.io } });
}

pub fn startSend(loop: *Loop, request: @import("RuntimeSend.zig")) !void {
    try loop.inbox.start(
        .sent,
        .{
            send,
            .{
                loop.io,
                request,
            },
        },
    );
}

fn send(io: std.Io, request: @import("RuntimeSend.zig")) anyerror!void {
    core.mark(io, .client_send_start);
    defer core.mark(io, .client_send_done);
    try request.state.send(io, request.bytes);
}

/// The window thread is the only consumer. Workers and native callbacks only
/// publish owned messages. Example: `const status = try loop.drain(gui);`
pub fn drain(loop: *Loop, gui: *GuiClient) !?u8 {
    return @import("entrypoints/events.zig").drain(loop, gui);
}
