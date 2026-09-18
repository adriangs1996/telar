//! A single-file entrypoint for writing and running your own Telar GUI widgets.
//!
//! Run: zig build run-widget
//! Build without opening a window: zig build build-widget
//! Check the runner: zig build test-widget
//!
//! Edit MyWidget's fields, draw and input below. The runner owns the window,
//! renderer, input queue, focus/capture registry and presentation lifecycle.
//! MyWidget owns your experimental state. Its input returns true after a change
//! that needs drawing. Canvas exposes text, shapes, sprites and an animation
//! clock; canvas.chrome.px(...) converts logical sizes to device pixels.
//!
//! Native input -> owned Inbox -> Runner.dispatch -> MyWidget.input -> state
//! Native draw  -> Runner.prepare -> MyWidget.draw -> Canvas -> quads/atlas
//!              -> GPU -> complete -> Inbox -> publish delivered hit regions.
//!
//! MyWidget.host exposes asynchronous clipboard requests. Their completions
//! return through input. Implement textContext when experimenting with an editor,
//! and accessibility when exposing its native semantics.
//!
//! No runtime, PTY or child process is needed. The single-file layout is
//! intentional here so the assembly and your widget can be read together.

const std = @import("std");
const client = @import("telar-client");
const native = @import("src/gui/native/native.zig");
const decode_input = @import("src/gui/native/decode_input.zig");
const Renderer = @import("src/gui/render/TerminalRenderer.zig");
const Canvas = @import("src/gui/widgets/Canvas.zig");
const Rect = @import("src/gui/render/Rect.zig");
const WidgetState = @import("src/gui/widgets/interaction/State.zig");
const Route = @import("src/gui/widgets/interaction/Route.zig");
const Id = @import("src/gui/widgets/interaction/Id.zig");
const Event = @import("src/gui/input/event.zig").Event;
const FrameClock = @import("src/gui/animation/FrameClock.zig");
const Services = @import("src/gui/host/Services.zig");
const GenericEventPool = @import("src/gui/input/GenericEventPool.zig").Type;

// Put your widget and its state here. Other widgets can be declared in this
// same file and composed by draw through their own draw(canvas) methods.
const MyWidget = struct {
    host: Services = .{},

    /// Draws synchronously; the GPU retains only renderer-owned frame resources.
    /// Register each interactive part with its painted bounds and a distinct
    /// custom action. The dispatcher then owns focus, hover and pointer capture.
    /// Example: try widget.draw(canvas);
    pub fn draw(widget: *const MyWidget, canvas: *Canvas) !void {
        _ = widget;
        const bounds: Rect = .{ .x = 0, .y = 0, .width = @floatFromInt(canvas.viewport[0]), .height = @floatFromInt(canvas.viewport[1]) };
        _ = try canvas.widgets.?.dispatcher.add(.{
            .id = .{ .generation = 1 },
            .bounds = bounds,
            .action = .{ .custom = 1 },
            .role = 6,
        });

        // Replace this label with your own drawing and widget composition.
        _ = try canvas.textAt(bounds, .{ .text = "MyWidget", .face = .sans, .size = .body });

        // Animated widgets sample canvas.animation and request their next frame,
        // for example: const step = canvas.animation.?.step(16_666_667);
    }

    /// Receives semantic events and their delivered target. Text is borrowed
    /// until this call returns; copy it into your state if you need to keep it.
    /// Return true when your state changed and should be drawn again.
    /// Example: const changed = try widget.input(event, route);
    pub fn input(widget: *MyWidget, event: Event, route: Route) !bool {
        _ = widget;
        _ = route;
        switch (event) {
            .key => |key| {
                _ = key;
            },
            .text => |text| {
                _ = text;
            },
            .pointer => |pointer| {
                _ = pointer;
            },
            .scroll => |scroll| {
                _ = scroll;
            },
            else => {},
        }

        return false;
    }

    /// An editor supplies current UTF-8 text, byte selection and delivered caret
    /// geometry here. The host copies this synchronous borrow for native IME.
    /// Example: if (widget.textContext(out)) publishTextContext(out);
    pub fn textContext(widget: *const MyWidget, out: *native.TextContext) bool {
        _ = widget;
        out.* = .{};
        return false;
    }

    /// Exposes your widget's native roles and actions. Any node storage must
    /// belong to the widget; the host copies it before this call returns.
    /// Example: if (widget.accessibility(out)) publishAccessibility(out);
    pub fn accessibility(widget: *const MyWidget, out: *native.AccessibilityTree) bool {
        _ = widget;
        out.* = .{};
        return false;
    }
};

const Completion = struct { token: u64, delivered: bool };

// Both input and GPU completions share this queue. Publishing new hit regions
// cannot overtake a click that arrived while the previous frame was visible.
// Borrowed native payloads are copied once into fixed storage before returning.
const Inbox = struct {
    const Message = union(enum) { input: u8, completed: Completion };

    pool: GenericEventPool(4096, 64) = .{},
    messages: [64]Message = undefined,
    head: usize = 0,
    len: usize = 0,

    fn push(inbox: *Inbox, event: Event) !void {
        // Reserve one slot for the single outstanding GPU completion.
        if (inbox.len >= inbox.messages.len - 1) {
            return error.NativeInputFull;
        }

        const slot = try inbox.pool.admit(event);
        inbox.messages[(inbox.head + inbox.len) % inbox.messages.len] = .{ .input = slot };
        inbox.len += 1;
    }

    fn completed(inbox: *Inbox, result: Completion) void {
        std.debug.assert(inbox.len < inbox.messages.len);
        inbox.messages[(inbox.head + inbox.len) % inbox.messages.len] = .{ .completed = result };
        inbox.len += 1;
    }

    fn drain(inbox: *Inbox, runner: *Runner) !void {
        while (inbox.len != 0) {
            const message = inbox.messages[inbox.head];
            inbox.head = (inbox.head + 1) % inbox.messages.len;
            inbox.len -= 1;
            switch (message) {
                .input => |slot| {
                    defer inbox.pool.release(slot);
                    try runner.dispatch(inbox.pool.view(slot));
                },
                .completed => |result| {
                    runner.completion_queued = false;
                    runner.finish(result);
                },
            }
        }
    }
};

const Runner = struct {
    io: std.Io,
    renderer: Renderer,
    widget: MyWidget = .{},
    widgets: WidgetState = .{},
    inbox: Inbox = .{},
    animation: FrameClock = .{},
    fds: [2]c_int = .{ -1, -1 },
    dirty: bool = true,
    focus_initialized: bool = false,
    next_token: u64 = 1,
    in_flight: ?u64 = null,
    completion_queued: bool = false,
    failure: ?anyerror = null,

    fn init(gpa: std.mem.Allocator, io: std.Io) !Runner {
        var runner: Runner = .{ .io = io, .renderer = Renderer.init(gpa) };
        runner.renderer.io = io;
        runner.renderer.sidebar_request.visible = false;
        if (native.telar_gui_pipe(&runner.fds) != 0) {
            return error.NativeWakePipeFailed;
        }

        return runner;
    }

    fn deinit(runner: *Runner) void {
        // The native loop has stopped its consumers before these buffers die.
        native.telar_gui_close_pipe(&runner.fds);
        runner.renderer.deinit();
    }

    fn now(runner: *const Runner) u64 {
        return @intCast(@max(0, std.Io.Clock.awake.now(runner.io).toNanoseconds()));
    }

    // One drawing opportunity: measure resources, lend a Canvas to the widget,
    // seal quads and hit regions, then submit one token. Nothing in this frame
    // is reused until its matching GPU completion returns.
    fn prepare(runner: *Runner, viewport: native.Viewport) !native.Frame {
        if (runner.in_flight != null or runner.failure != null) {
            return runner.renderer.frame(0);
        }

        // Reuses Telar's atlas, fallback fonts, sprites and bounded quad storage.
        // A display-scale change rebuilds resources only when no GPU borrows them.
        _ = runner.renderer.measure(viewport) catch |err| switch (err) {
            error.InvalidTerminalSize => return runner.renderer.frame(0),
            else => return err,
        };
        runner.renderer.begin();
        runner.animation.begin(runner.now());
        runner.widgets.begin(false);
        var canvas: Canvas = .{
            .atlas = &runner.renderer.atlas.?,
            .quads = &runner.renderer.quads,
            .metrics = runner.renderer.metrics,
            .origin = .{ 0, 0 },
            .theme = client.theme_support.default_theme,
            .chrome = runner.renderer.chrome,
            .viewport = runner.renderer.viewport,
            .sprites = if (runner.renderer.sprites) |*page| page else null,
            .terminal_renderer = &runner.renderer,
            .animation = &runner.animation,
            .widgets = &runner.widgets,
        };
        try runner.widget.draw(&canvas);
        runner.widgets.seal();
        runner.renderer.seal();
        const token = runner.next_token;
        runner.next_token = try std.math.add(u64, token, 1);
        runner.in_flight = token;
        runner.dirty = false;
        return runner.renderer.frame(token);
    }

    // Only the exact completed frame may publish its hit and editor geometry.
    // Failed delivery keeps the previous controls. Input during a flight keeps
    // dirty set so its changes are included in the following preparation.
    fn finish(runner: *Runner, result: Completion) void {
        if (runner.in_flight == null or runner.in_flight.? != result.token) {
            return;
        }

        runner.in_flight = null;
        const revision = runner.widgets.dispatcher.revision;
        runner.widgets.dispatcher.present(result.delivered);
        runner.widgets.editors.present(result.delivered);
        if (result.delivered and !runner.focus_initialized) {
            runner.focus_initialized = true;
            const registry = runner.widgets.dispatcher.maps.presented();
            for (registry.targets[0..registry.len]) |target| {
                if (runner.widgets.dispatcher.focus(target.id)) {
                    break;
                }
            }
        }
        runner.dirty = runner.dirty or !result.delivered or revision != runner.widgets.dispatcher.revision;
    }

    // The dispatcher chooses the delivered target and retains gesture/key
    // ownership. Your widget decides what the semantic event does to its state.
    fn dispatch(runner: *Runner, value: Event) !void {
        var event = value;
        if (event == .clipboard) {
            const operation = runner.widget.host.complete(event.clipboard) orelse return;
            event.clipboard.operation = if (operation == .read) .read else .write;
        }

        const revision = runner.widgets.dispatcher.revision;
        defer runner.dirty = runner.dirty or revision != runner.widgets.dispatcher.revision;
        var route = runner.widgets.dispatcher.route(event);
        if (event == .accessibility) {
            const action = event.accessibility;
            route.target = runner.widgets.dispatcher.maps.presented().find(.{ .target_id = action.target_id, .generation = action.generation }) orelse return;
            route.consumed = true;
            if (action.action == .focus) {
                route.focus_changed = runner.widgets.dispatcher.focus(route.target.?.id);
            }
        } else if (explicitTarget(event)) |id| {
            // Targeted IME, text and clipboard events cannot reach a replacement
            // editor. A clipboard write still reports completion to its owner.
            const write = event == .clipboard and event.clipboard.operation == .write;
            if (write) {
                route.target = runner.widgets.dispatcher.maps.presented().find(id) orelse return;
            } else if (route.target == null or !route.target.?.id.eql(id) or !std.meta.eql(runner.widgets.dispatcher.focused, @as(?Id, id))) {
                return;
            }
        }
        if (route.focus_changed or (event == .focus and !event.focus)) {
            runner.widgets.cancelComposition();
        }

        const changed = try runner.widget.input(event, route);
        runner.dirty = runner.dirty or changed;
    }

    fn fail(runner: *Runner, err: anyerror) void {
        if (runner.failure == null) {
            runner.failure = err;
            std.log.err("widget runner: {s}", .{@errorName(err)});
        }
        native.telar_gui_wake(runner.fds[1]);
    }
};

/// Opens the native window on the main thread. Example: zig build run-widget
pub fn main(init: std.process.Init) !void {
    const runner = try init.gpa.create(Runner);
    defer init.gpa.destroy(runner);
    runner.* = try Runner.init(init.gpa, init.io);
    defer runner.deinit();
    const callbacks: native.Callbacks = .{
        .render = render,
        .pump = pump,
        .complete = complete,
        .input = input,
        .wake_fd = runner.fds[0],
        .wakeup_after = wakeupAfter,
        .pointer_shape = pointerShape,
        .text_context = textContext,
        .host_request = hostRequest,
        .accessibility = accessibility,
    };
    const result = native.telar_gui_run("Telar widget runner", runner, &callbacks);
    if (runner.failure) |err| {
        return err;
    }
    if (result != 0) {
        return error.NativeWindowFailed;
    }
}

fn from(context: ?*anyopaque) *Runner {
    return @ptrCast(@alignCast(context.?));
}

// A zero frame token tells the native adapter to defer submission.
fn render(context: ?*anyopaque, viewport: native.Viewport, out: *native.Frame) callconv(.c) void {
    const runner = from(context);
    out.* = runner.prepare(viewport) catch |err| blk: {
        runner.fail(err);
        break :blk runner.renderer.frame(0);
    };
}

fn input(context: ?*anyopaque, raw: native.InputEvent) callconv(.c) c_int {
    const runner = from(context);
    var event = decode_input.decode(raw) catch return 0;
    if (event == .clipboard and event.clipboard.text.len > 4096) {
        event.clipboard.text = "";
        event.clipboard.status = .cancelled;
    }
    runner.inbox.push(event) catch |err| {
        if (err == error.InputTooLarge or err == error.InvalidUtf8) {
            return 0;
        }

        // Saturation stops the runner instead of losing a key/pointer release.
        runner.fail(err);
        return 0;
    };
    native.telar_gui_wake(runner.fds[1]);
    return 1;
}

fn complete(context: ?*anyopaque, token: u64, delivered: c_int) callconv(.c) void {
    const runner = from(context);
    if (token == 0 or runner.in_flight == null or runner.in_flight.? != token or runner.completion_queued) {
        return;
    }

    runner.inbox.completed(.{ .token = token, .delivered = delivered != 0 });
    runner.completion_queued = true;
    native.telar_gui_wake(runner.fds[1]);
}

fn pump(context: ?*anyopaque) callconv(.c) c_int {
    const runner = from(context);
    runner.inbox.drain(runner) catch |err| runner.fail(err);
    if (runner.failure != null) {
        return -1;
    }
    if (runner.in_flight != null) {
        return 0;
    }

    return @intFromBool(runner.dirty or runner.animation.requestPreparation(runner.now()));
}

fn wakeupAfter(context: ?*anyopaque) callconv(.c) u32 {
    const runner = from(context);
    return if (runner.in_flight != null) 0 else runner.animation.wakeupAfter(runner.now());
}

// Change this policy for your widget's handles, links or text fields.
// The codes match native/telar_gui.h; zero is the default arrow.
fn pointerShape(context: ?*anyopaque) callconv(.c) u32 {
    _ = context;
    return 0;
}

fn textContext(context: ?*anyopaque, out: *native.TextContext) callconv(.c) c_int {
    const runner = from(context);
    out.* = .{};
    if (runner.inbox.len != 0) {
        return -1;
    }
    if (!runner.widgets.dispatcher.window_focused) {
        return 0;
    }

    return @intFromBool(runner.widget.textContext(out));
}

fn hostRequest(context: ?*anyopaque, out: *native.HostRequest) callconv(.c) c_int {
    return @intFromBool(from(context).widget.host.next(out));
}

fn accessibility(context: ?*anyopaque, out: *native.AccessibilityTree) callconv(.c) c_int {
    return @intFromBool(from(context).widget.accessibility(out));
}

fn explicitTarget(event: Event) ?Id {
    return switch (event) {
        .text => |value| if (value.target_id == 0) null else .{ .target_id = value.target_id, .generation = value.generation },
        .key => |value| if (value.target_id == 0) null else .{ .target_id = value.target_id, .generation = value.generation },
        .composition => |value| .{ .target_id = value.target_id, .generation = value.generation },
        .clipboard => |value| if (value.target_id == 0) null else .{ .target_id = value.target_id, .generation = value.generation },
        .delete_surrounding => |value| .{ .target_id = value.target_id, .generation = value.generation },
        else => null,
    };
}

// build.zig calls this function; the platform helpers are the same ones used
// by telar-gui. This file is also the executable's module root.
/// Registers the executable and its checks. Example: run_widget.addBuild(b, app);
pub fn addBuild(b: *std.Build, app: @import("build/Application.zig")) void {
    const os = app.modules.target.result.os.tag;
    if (os != .macos and os != .linux) {
        return;
    }

    const module = b.createModule(.{ .root_source_file = b.path("run_widget.zig"), .target = app.modules.target, .optimize = app.modules.optimize, .link_libc = true });
    module.addImport("telar-core", app.modules.core);
    module.addImport("telar-client", app.modules.client);
    module.addImport("assets", app.modules.assets);
    module.addImport("freetype", app.modules.freetype);
    module.addCSourceFile(.{ .file = b.path("src/gui/native/wake.c"), .flags = &.{} });
    if (os == .macos) {
        @import("build/macos_gui.zig").add(b, module, app.coverage.enabled);
    } else {
        @import("build/linux_gui.zig").add(b, module, app.coverage.enabled);
    }

    const executable = b.addExecutable(.{ .name = "run-widget", .root_module = module });
    const install = b.addInstallArtifact(executable, .{});
    b.step("build-widget", "Build the single-file native widget runner").dependOn(&install.step);
    const run = b.addRunArtifact(executable);
    if (b.args) |args| {
        run.addArgs(args);
    }
    b.step("run-widget", "Run your widget with Telar's native GUI plumbing").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = module, .filters = &.{"widget runner"} });
    b.step("test-widget", "Check widget runner input and presentation ownership").dependOn(&b.addRunArtifact(tests).step);
}

fn testRunner() !*Runner {
    const runner = try std.testing.allocator.create(Runner);
    errdefer std.testing.allocator.destroy(runner);
    runner.* = try Runner.init(std.testing.allocator, std.testing.io);
    runner.renderer.io = null;
    return runner;
}

test "widget runner retains resources and delivered geometry until matching completion" {
    const runner = try testRunner();
    defer std.testing.allocator.destroy(runner);
    defer runner.deinit();
    const viewport: native.Viewport = .{ .width = 800, .height = 480, .scale = 1 };
    const first = try runner.prepare(viewport);
    try std.testing.expect(first.token != 0 and first.quad_count > 0);
    try std.testing.expectEqual(@as(usize, 0), runner.widgets.dispatcher.maps.presented().len);
    const deferred = try runner.prepare(.{ .width = 1600, .height = 960, .scale = 2 });
    try std.testing.expectEqual(@as(u64, 0), deferred.token);
    try std.testing.expectEqual(first.quads, deferred.quads);
    try std.testing.expectEqual(first.atlas, deferred.atlas);
    runner.finish(.{ .token = first.token + 1, .delivered = true });
    try std.testing.expectEqual(first.token, runner.in_flight.?);
    runner.finish(.{ .token = first.token, .delivered = true });
    try std.testing.expect(runner.widgets.dispatcher.focused != null);

    const resized = try runner.prepare(.{ .width = 320, .height = 200, .scale = 1 });
    try runner.inbox.push(.{ .pointer = .{ .kind = .press, .x = 700, .y = 400 } });
    complete(runner, resized.token, 1);
    complete(runner, resized.token, 1);
    _ = pump(runner);
    // The click preceded completion and therefore hit the old 800x480 widget.
    try std.testing.expect(runner.widgets.dispatcher.captures[0] != null);
    try std.testing.expectEqual(@as(f32, 320), runner.widgets.dispatcher.maps.presented().targets[0].bounds.width);
    try std.testing.expect(runner.dirty);

    const failed = try runner.prepare(viewport);
    runner.finish(.{ .token = failed.token, .delivered = false });
    try std.testing.expectEqual(@as(f32, 320), runner.widgets.dispatcher.maps.presented().targets[0].bounds.width);
    try std.testing.expect(runner.dirty);
    const retry = try runner.prepare(.{ .width = 320, .height = 200, .scale = 1 });
    runner.finish(.{ .token = retry.token, .delivered = true });
    try std.testing.expectEqual(@as(c_int, 0), pump(runner));
    try std.testing.expectEqual(@as(u32, 0), wakeupAfter(runner));
}

test "widget runner copies native payloads and reserves completion capacity" {
    const runner = try testRunner();
    defer std.testing.allocator.destroy(runner);
    defer runner.deinit();
    var bytes = [_]u8{ 'h', 'i' };
    try std.testing.expectEqual(@as(c_int, 1), input(runner, .{ .kind = 1, .text = &bytes, .len = bytes.len }));
    @memset(&bytes, 'x');
    const slot = runner.inbox.messages[0].input;
    try std.testing.expectEqualStrings("hi", runner.inbox.pool.view(slot).text.bytes);
    try runner.inbox.drain(runner);
    const oversized: [4097]u8 = @splat('x');
    try std.testing.expectError(error.InputTooLarge, runner.inbox.push(.{ .paste = &oversized }));
    for (0..63) |_| {
        try runner.inbox.push(.{ .focus = true });
    }
    try std.testing.expectError(error.NativeInputFull, runner.inbox.push(.{ .focus = false }));
    runner.inbox.completed(.{ .token = 0, .delivered = false });
    try std.testing.expectEqual(@as(usize, 64), runner.inbox.len);
    try runner.inbox.drain(runner);
    try std.testing.expectEqual(@as(usize, 0), runner.inbox.len);
    try runner.inbox.push(.{ .paste = "reused" });
}
