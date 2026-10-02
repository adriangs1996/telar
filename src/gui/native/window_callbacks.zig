//! Adapts the native C ABI to the one GUI owner; holds no application state.
//! Native backends invoke these callbacks on the window thread. GPU and image
//! workers report their results back to that thread before calling into Zig.
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
        .display_interval = displayInterval,
        .frame_interval_ns = frameIntervalNs,
        .window_title = windowTitle,
        .ready = ready,
        .image_ready = imageReady,
    };
}

fn from(context: ?*anyopaque) *GuiAdapter {
    return @ptrCast(@alignCast(context.?));
}

/// Called by macOS TelarView.resizeDrawable and Linux surface_configure when
/// the window has usable geometry, including subsequent resize/configure events.
fn ready(context: ?*anyopaque, native_viewport: native.Viewport) callconv(.c) void {
    const gui = from(context);
    const viewport = limit_reached.boundViewport(gui, native_viewport);
    gui.windowReady(viewport) catch |err| gui.fail(err);
}

/// Called by macOS TelarView.drawWithDrawable or Linux window.c's draw when a
/// dirty window is allowed to submit a frame. Produces the frame and image work;
/// a zero token tells the backend to keep the previous frame and retry later.
fn render(context: ?*anyopaque, native_viewport: native.Viewport, out: *native.Frame) callconv(.c) void {
    const gui = from(context);
    const viewport = limit_reached.boundViewport(gui, native_viewport);
    core.mark(gui.app.io, .compose_start);
    defer core.mark(gui.app.io, .host_flush_start);
    // Token 0 keeps the previous frame on screen.
    const token = gui.draw(viewport) catch |err| blk: {
        if (err != error.PresentationBusy and !limit_reached.absorbFrame(gui, viewport, err)) {
            gui.fail(err);
        }

        break :blk 0;
    };
    out.* = gui.renderer.frame(token);
    pane_images.handOff(&gui.images, out);
}

/// Called by TelarView's Metal image completion block or Linux's
/// telar_renderer_take_images after an upload finishes or is rejected.
/// The backend has stopped reading its pixels; success says the handle can draw.
fn imageReady(context: ?*anyopaque, handle: u32, success: c_int) callconv(.c) void {
    from(context).imageReady(handle, success != 0);
}

/// Called by macOS TelarView.pumpEvents on wake-pipe, timer and render/upload
/// completion notifications, and by Linux's window loop before drawing/polling.
/// Drains client work; returns -1 to close, 0 for no redraw, or 1 to request one.
fn pump(context: ?*anyopaque) callconv(.c) c_int {
    const gui = from(context);
    if (gui.failure != null or gui.exit_status != null) {
        return -1;
    }

    gui.postUnposted();
    const status = gui.update() catch |err| {
        if (limit_reached.absorb(gui, .window_update, err)) {
            // The rest of the batch stays queued. A draw shows the notice,
            // once: the same error again asks for nothing.
            const repeated = if (gui.update_limited) |previous| previous == err else false;
            gui.update_limited = err;
            return @intFromBool(!repeated);
        }

        gui.fail(err);
        return -1;
    };
    gui.update_limited = null;

    if (status != null) {
        return -1;
    }

    return @intFromBool(gui.needs_draw);
}

/// Called by TelarView after Metal completion or by Linux's window loop after
/// taking a frame-worker result, once the GPU no longer reads the frame.
/// Both also call it with delivered = 0 when discarding a prepared submission.
fn complete(context: ?*anyopaque, token: u64, delivered: c_int) callconv(.c) void {
    const gui = from(context);
    core.mark(gui.app.io, .host_flush_done);
    if (token != 0) {
        gui.completePresentation(
            .{
                .token = token,
                .delivered = delivered != 0,
            },
        );
    }
}

/// Called by the macOS AppKit views or Linux Wayland input adapters for key,
/// text/IME, pointer, scroll and focus events. Native clipboard services and
/// accessibility adapters also call it to deliver results and requested actions.
fn input(context: ?*anyopaque, event: native.InputEvent) callconv(.c) c_int {
    const gui = from(context);
    const decoded = decode_input.decode(event) catch |err| {
        // A native paste past the clipboard capacity is refused whole.
        if (err == error.InputTooLarge) {
            _ = limit_reached.absorbInput(gui, null, err);
        }

        return 0;
    };
    // An event that reaches a limit is refused alone; the window goes on.
    const accepted = gui.input(decoded) catch |err| {
        if (!limit_reached.absorbInput(gui, decoded, err)) {
            gui.fail(err);
        }

        return 0;
    };
    return @intFromBool(accepted);
}

/// Queried by macOS TelarView.scheduleWake when arming its one-shot timer and
/// by Linux's window loop before poll. Returns the next client wake delay in
/// milliseconds; zero means the client needs no timer wakeup.
fn wakeupAfter(context: ?*anyopaque) callconv(.c) u32 {
    return from(context).wakeupAfter();
}

/// Queried by macOS TelarView.drawDelay before acquiring a drawable to check
/// whether frame pacing allows submission. Zero admits a frame; otherwise the
/// result is the remaining delay in nanoseconds. Linux does not call this hook.
fn frameDelayNs(context: ?*anyopaque) callconv(.c) u64 {
    return from(context).frameDelayNs();
}

/// Called by macOS TelarView.reportDisplay when attaching to a screen or after
/// screen/rate changes, and by Linux's window loop when telar_display_rate_take
/// yields a refresh interval. Reports the display interval in nanoseconds.
fn displayInterval(context: ?*anyopaque, interval_ns: u64) callconv(.c) void {
    const gui = from(context);
    gui.observeDisplay(interval_ns) catch |err| gui.fail(err);
}

/// Queried by macOS TelarView.followFrameInterval after display reports and
/// frame preparation, and by Linux's draw before requesting a frame-clock tick.
/// Returns the paced interval, including any configured FPS cap, in nanoseconds.
fn frameIntervalNs(context: ?*anyopaque) callconv(.c) u64 {
    return from(context).driver.frame_pacer.cadence.interval;
}

/// Queried by macOS TelarView.desiredPointerShape during native cursor refresh
/// and by Linux's pointer update after drawing. Reads the current hover shape
/// so cursor changes do not need to wait for GPU presentation.
fn pointerShape(context: ?*anyopaque) callconv(.c) u32 {
    return @intFromEnum(from(context).pointer.hover.shape);
}

/// Queried through macOS TelarView.copyTextContext when refreshing IME state
/// and by Linux telar_text_input_update during native input-service processing.
/// Returns -1 to preserve cached text while input is queued, 0 to disable the
/// context, or 1 to publish the focused widget's text and caret state.
fn textContext(context: ?*anyopaque, out: *native.TextContext) callconv(.c) c_int {
    out.* = .{};
    const gui = from(context);
    if (gui.input_queue.len != 0) {
        return -1;
    }

    return @intFromBool(gui.widgetTextContext(out));
}

/// Called by macOS TelarHostServices.drain after pumping and by Linux
/// telar_input_services to take the next queued native clipboard request.
/// Each successful call consumes one request; zero means the queue is empty.
fn hostRequest(context: ?*anyopaque, out: *native.HostRequest) callconv(.c) c_int {
    return @intFromBool(from(context).host.next(out));
}

/// Called by macOS TelarAccessibility.refresh after pumping and by Linux
/// telar_accessibility_update in the window loop to refresh their native
/// accessibility snapshots using the client's delivered widget geometry.
fn accessibility(context: ?*anyopaque, out: *native.AccessibilityTree) callconv(.c) c_int {
    out.* = .{};
    return @intFromBool(from(context).widgetAccessibility(out));
}

/// Queried after pumping by macOS TelarView.refreshWindowTitle and Linux
/// refresh_window_title. A positive result supplies a title for the native
/// window; zero leaves its existing title unchanged.
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
