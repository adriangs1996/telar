//! Adapts the native C ABI to the one GUI owner; holds no application state.
const std = @import("std");
const core = @import("telar-core");
const GuiAdapter = @import("../GuiAdapter.zig");
const native = @import("native.zig");
const decode_input = @import("decode_input.zig");
const pane_images = @import("../image/pane_images.zig");
const limit_reached = @import("../limit_reached.zig");

/// Binds native callbacks to the stable GUI owner. Example: `const table = bind(gui);`
pub fn bind(gui: *GuiAdapter) native.Callbacks {
    return .{
        .render = render,
        .pump = pump,
        .complete = complete,
        .input = input,
        .wake_fd = gui.driver.fds[0],
        .wakeup_after = wakeupAfter,
        .pointer_shape = pointerShape,
        .text_context = textContext,
        .host_request = hostRequest,
        .accessibility = accessibility,
        .frame_delay_ns = frameDelayNs,
        .window_title = windowTitle,
        .ready = ready,
        .image_ready = imageReady,
    };
}

fn from(context: ?*anyopaque) *GuiAdapter {
    return @ptrCast(@alignCast(context.?));
}

fn ready(context: ?*anyopaque, viewport: native.Viewport) callconv(.c) void {
    const gui = from(context);
    gui.windowReady(viewport) catch |err| gui.fail(err);
}

fn render(context: ?*anyopaque, viewport: native.Viewport, out: *native.Frame) callconv(.c) void {
    const gui = from(context);
    core.mark(gui.app.io, .compose_start);
    defer core.mark(gui.app.io, .host_flush_start);
    // Token 0 keeps the previous frame on screen.
    const token = gui.draw(viewport) catch |err| blk: {
        if (err != error.PresentationBusy and !limit_reached.absorb(gui, .window_draw, err)) {
            gui.fail(err);
        }

        break :blk 0;
    };
    out.* = gui.renderer.frame(token);
    pane_images.handOff(&gui.images, out);
}

fn imageReady(context: ?*anyopaque, handle: u32, success: c_int) callconv(.c) void {
    from(context).imageReady(handle, success != 0);
}

fn pump(context: ?*anyopaque) callconv(.c) c_int {
    const gui = from(context);
    if (gui.failure != null or gui.exit_status != null) {
        return -1;
    }

    if (gui.update() catch |err| {
        if (limit_reached.absorb(gui, .window_update, err)) {
            // The rest of the batch stays queued; a draw shows the notice.
            return 1;
        }

        gui.fail(err);
        return -1;
    }) |_| {
        return -1;
    }

    return @intFromBool(gui.needs_draw);
}

fn complete(context: ?*anyopaque, token: u64, delivered: c_int) callconv(.c) void {
    const gui = from(context);
    core.mark(gui.app.io, .host_flush_done);
    if (token != 0) {
        gui.driver.inbox.post(
            .{
                .presented = .{
                    .token = token,
                    .delivered = delivered != 0,
                },
            },
        ) catch |err| gui.fail(err);
    }
}

fn input(context: ?*anyopaque, event: native.InputEvent) callconv(.c) c_int {
    const gui = from(context);
    const decoded = decode_input.decode(event) catch return 0;
    const accepted = gui.input(decoded) catch |err| {
        gui.fail(err);
        return 0;
    };
    return @intFromBool(accepted);
}

fn wakeupAfter(context: ?*anyopaque) callconv(.c) u32 {
    return from(context).wakeupAfter();
}

fn frameDelayNs(context: ?*anyopaque) callconv(.c) u64 {
    return from(context).frameDelayNs();
}

fn pointerShape(context: ?*anyopaque) callconv(.c) u32 {
    return @intFromEnum(from(context).pointer.hover.shape);
}

fn textContext(context: ?*anyopaque, out: *native.TextContext) callconv(.c) c_int {
    out.* = .{};
    const gui = from(context);
    if (gui.input_queue.len != 0) {
        return -1;
    }

    return @intFromBool(gui.widgetTextContext(out));
}

fn hostRequest(context: ?*anyopaque, out: *native.HostRequest) callconv(.c) c_int {
    return @intFromBool(from(context).host.next(out));
}

fn accessibility(context: ?*anyopaque, out: *native.AccessibilityTree) callconv(.c) c_int {
    out.* = .{};
    return @intFromBool(from(context).widgetAccessibility(out));
}

fn windowTitle(context: ?*anyopaque, out: *native.WindowTitle) callconv(.c) c_int {
    return @intFromBool(from(context).windowTitle(out) catch |err| {
        std.log.warn(
            "could not prepare window title: {s}",
            .{
                @errorName(err),
            },
        );
        return 0;
    });
}
