//! Native wake endpoint and producers of the shared bounded inbox.
const gui_event = @import("gui_event.zig");
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const native = @import("native/native.zig");
const Loop = @This();
const FramePacer = @import("FramePacer.zig");

io: std.Io,
fds: [2]c_int,
inbox: gui_event.Inbox,
configuration: @import("ConfigurationReload.zig"),
frame_pacer: FramePacer = .{},

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

