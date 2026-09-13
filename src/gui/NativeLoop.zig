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

    return .{ .io = io, .fds = fds, .inbox = .init(io, .{ .context = @intCast(fds[1]), .notify_fn = wake }), .configuration = .{ .io = io } };
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
    try loop.inbox.start(.sent, .{ send, .{ loop.io, request } });
}

fn send(io: std.Io, request: @import("RuntimeSend.zig")) anyerror!void {
    core.mark(io, .client_send_start);
    defer core.mark(io, .client_send_done);
    try request.state.send(io, request.bytes);
}

/// The window thread is the only consumer. Workers and native callbacks only
/// publish owned messages. Example: `const status = try loop.drain(gui);`
pub fn drain(loop: *Loop, gui: *GuiClient) !?u8 {
    var turn = try loop.inbox.begin();
    defer loop.inbox.end();
    while (try loop.inbox.next(&turn)) |event| {
        const path = core.enter(if (event == .configuration_ready) .observation else .interactive);
        defer path.restore();
        switch (event) {
            .server => |result| {
                if (try gui.receive(result)) |status| {
                    return status;
                }
            },
            .sent => |result| try client.runtime_io.handleSent(&gui.app, result),
            .input_ready => try gui.inputReady(),
            .focus => |focused| gui.focus(focused),
            .presented => |result| try gui.complete(result.token, result.delivered),
            .configuration_ready => try loop.configuration.accept(&gui.app),
        }
    }

    try loop.configuration.poll(&gui.app);
    return null;
}
