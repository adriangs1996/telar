const std = @import("std");
const experiment = @import("exper.zig");
const Renderer = @import("exper/Renderer.zig");

extern fn exper_native_open() c_int;
extern fn exper_native_run() c_int;
extern fn exper_native_close() void;
extern fn exper_native_present(i32) void;
extern fn exper_native_stop() void;

fn render(_: *anyopaque, value: i32) !void {
    exper_native_present(value);
}

fn run(io: std.Io, renderer: *Renderer, input: std.Io.File) !void {
    defer exper_native_stop();
    try experiment.run(io, renderer, input);
}

pub fn main(init: std.process.Init) !void {
    const fd = exper_native_open();
    if (fd < 0) {
        return error.NativeWindowFailed;
    }

    defer exper_native_close();
    var context: u8 = 0;
    var renderer: Renderer = .{ .context = &context, .render_fn = render };
    var task = try init.io.concurrent(run, .{ init.io, &renderer, std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } } });
    defer _ = task.cancel(init.io) catch {};

    const status = exper_native_run();
    try task.await(init.io);

    if (status != 0) {
        return error.NativeInputFailed;
    }
}
