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

const data = @import("model");
const macos_gui = @import("build/macos_gui.zig");
const linux_gui = @import("build/linux_gui.zig");
const event_module = @import("src/gui/input/event.zig");
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
const FrameClock = @import("src/gui/animation/FrameClock.zig");
const Services = @import("src/gui/host/Services.zig");
const GenericEventPool = @import("src/gui/input/GenericEventPool.zig").Type;

const Fixture = @import("src/gui/experiments/review/fixture.zig");
const LiveReview = @import("src/gui/experiments/review/live_review.zig");
const LiveBridge = @import("src/gui/experiments/review/LiveBridge.zig");
const MyWidget = @import("src/gui/change_review/Widget.zig");

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

    fn push(inbox: *Inbox, event: event_module.Event) !void {
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
    live: ?*LiveBridge = null,
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
        errdefer native.telar_gui_close_pipe(&runner.fds);
        try Fixture.prepare(&runner.widget, gpa, io);

        return runner;
    }

    fn deinit(runner: *Runner) void {
        // The native loop has stopped its consumers before these buffers die.
        if (runner.live) |bridge| {
            bridge.deinit();
        }
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
            .theme = data.theme_support.default_theme,
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
        runner.widget.present(result.delivered);
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
    fn dispatch(runner: *Runner, value: event_module.Event) !void {
        var event = value;
        if (event == .clipboard) {
            const operation = runner.widget.host.complete(event.clipboard) orelse return;
            event.clipboard.operation = if (operation == .read) .read else .write;
        }

        const revision = runner.widgets.dispatcher.revision;
        defer runner.dirty = runner.dirty or revision != runner.widgets.dispatcher.revision;
        var route = if (event == .key and runner.widget.ownsKey(event.key)) runner.widgets.dispatcher.editorKey(event.key) else runner.widgets.dispatcher.route(event);
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
    if (std.process.Environ.getPosix(init.minimal.environ, "TELAR_REVIEW_SOCKET")) |path| {
        runner.live = try LiveBridge.open(init, .{ .path = path, .wake_fd = runner.fds[1] });
        try LiveReview.load(&runner.widget, runner.live.?.initial.?);
    }
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

    runner.dirty = (if (runner.live) |bridge| LiveReview.pump(&runner.widget, bridge) else false) or runner.dirty;
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

fn explicitTarget(event: event_module.Event) ?Id {
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
    module.addImport("model", app.modules.data);
    module.addImport("assets", app.modules.assets);
    module.addImport("freetype", app.modules.freetype);
    module.addObjectFile(app.modules.syntax_library.?);
    module.addCSourceFile(.{ .file = b.path("src/gui/native/wake.c"), .flags = &.{} });
    if (os == .macos) {
        macos_gui.add(b, module, app.coverage.enabled);
    } else {
        linux_gui.add(b, module, app.coverage.enabled);
    }

    const executable = b.addExecutable(.{ .name = "run-widget", .root_module = module });
    const install = b.addInstallArtifact(executable, .{});
    b.step("build-widget", "Build the single-file native widget runner").dependOn(&install.step);
    const run = b.addRunArtifact(executable);
    if (b.args) |args| {
        run.addArgs(args);
    }
    b.step("run-widget", "Run your widget with Telar's native GUI plumbing").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = module, .filters = &.{ "widget runner", "review prototype" } });
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
    try runner.inbox.drain(runner);
    // The click still uses the old delivered geometry while resize is in flight.
    try std.testing.expect(runner.widgets.dispatcher.captures[0] != null);
    complete(runner, resized.token, 1);
    complete(runner, resized.token, 1);
    _ = pump(runner);
    // A code fragment retired by wrapping sinks its eventual pointer release.
    try std.testing.expect(runner.widgets.dispatcher.captures[0] != null or runner.widgets.dispatcher.discarded[0]);
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

const review_actions = @import("src/gui/change_review/action.zig");
const ReviewInput = @import("src/gui/change_review/input.zig");
const ReviewTarget = @import("src/gui/widgets/interaction/Target.zig");

fn reviewFrame(runner: *Runner) !void {
    const frame = try runner.prepare(.{ .width = 1100, .height = 720, .scale = 1 });
    runner.finish(.{ .token = frame.token, .delivered = true });
}

test "review prototype native editor keeps navigation text literal and rejects retired owners" {
    const runner = try testRunner();
    defer std.testing.allocator.destroy(runner);
    defer runner.deinit();
    try reviewFrame(runner);
    try runner.dispatch(.{ .text = .{ .bytes = "j" } });
    try runner.dispatch(.{ .text = .{ .bytes = "c" } });
    const anchor = runner.widget.model.comments[0].anchor;
    try reviewFrame(runner);
    const target = runner.widgets.dispatcher.focusedTarget().?;
    try std.testing.expectEqual(review_actions.Kind.editor, review_actions.kind(target.action.custom).?);
    try runner.dispatch(.{ .text = .{ .bytes = "c j k n p t · café 界" } });
    try std.testing.expectEqualStrings("c j k n p t · café 界", runner.widget.model.comments[0].body.text());
    try std.testing.expectEqual(anchor.last, runner.widget.model.head);
    var context: native.TextContext = .{};
    try std.testing.expect(runner.widget.textContext(&context));
    try std.testing.expectEqualStrings(runner.widget.model.comments[0].body.text(), context.text.?[0..context.len]);
    try runner.dispatch(.{ .key = .{ .code = .enter, .mods = .{ .super = true } } });
    try std.testing.expect(runner.widget.model.editing == null);
    try std.testing.expect(!runner.widget.model.comments[0].draft);
    try std.testing.expect(!try runner.widget.input(.{ .text = .{ .bytes = "late" } }, .{ .target = target, .consumed = true }));
    try std.testing.expectEqualDeep(anchor, runner.widget.model.comments[0].anchor);
    try reviewFrame(runner);
    ReviewInput.activate(&runner.widget, .{ .kind = .simulate });
    ReviewInput.activate(&runner.widget, .{ .kind = .version });
    try reviewFrame(runner);
    try std.testing.expectEqual(@as(usize, 1), runner.widget.model.revision);
    try std.testing.expectEqualDeep(anchor, runner.widget.model.comments[0].anchor);
    ReviewInput.activate(&runner.widget, .{ .kind = .version });
    try reviewFrame(runner);
    try std.testing.expectEqualStrings("c j k n p t · café 界", runner.widget.model.comments[0].body.text());
}

test "review prototype composition cancellation capacity and clipboard preserve committed drafts" {
    const runner = try testRunner();
    defer std.testing.allocator.destroy(runner);
    defer runner.deinit();
    try reviewFrame(runner);
    try runner.dispatch(.{ .text = .{ .bytes = "c" } });
    try reviewFrame(runner);
    try runner.dispatch(.{ .text = .{ .bytes = "base" } });
    const target = runner.widgets.dispatcher.focusedTarget().?;
    try runner.dispatch(.{ .composition = .{ .target_id = target.id.target_id, .generation = target.id.generation, .text = "界", .selection_start = 3, .selection_end = 3 } });
    try reviewFrame(runner);
    try std.testing.expectEqualStrings("base", runner.widget.model.comments[0].body.text());
    try runner.dispatch(.{ .key = .{ .code = .escape } });
    try std.testing.expect(runner.widget.model.editing != null);
    try std.testing.expect(runner.widgets.preedit.owner == null);
    const large: [2049]u8 = @splat('a');
    try runner.dispatch(.{ .paste = &large });
    try std.testing.expectEqualStrings("base", runner.widget.model.comments[0].body.text());
    try runner.dispatch(.{ .key = .{ .code = .{ .char = .{ .bytes = .{ 'v', 0, 0, 0 }, .len = 1 } }, .mods = .{ .super = true } } });
    var request: native.HostRequest = .{};
    try std.testing.expect(runner.widget.host.next(&request));
    try runner.dispatch(.{ .text = .{ .bytes = " changed" } });
    try runner.dispatch(.{ .clipboard = .{ .request_id = request.request_id, .target_id = request.target_id, .generation = request.generation, .text = "late paste", .status = .success } });
    try std.testing.expectEqualStrings("base changed", runner.widget.model.comments[0].body.text());
    try runner.dispatch(.{ .key = .{ .code = .escape } });
    try std.testing.expect(runner.widget.model.editing == null);
    try std.testing.expect(runner.widget.model.comments[0].draft);
}

test "review prototype gutter selection uses delivered rows and copies code without diff markers" {
    const runner = try testRunner();
    defer std.testing.allocator.destroy(runner);
    defer runner.deinit();
    try reviewFrame(runner);
    var source_target: ?ReviewTarget = null;
    const registry = runner.widgets.dispatcher.maps.presented();
    for (registry.targets[0..registry.len]) |target| {
        if (target.action == .custom and review_actions.kind(target.action.custom) == .code) {
            source_target = target;
            break;
        }
    }
    const target = source_target.?;
    try runner.dispatch(.{ .pointer = .{ .kind = .press, .x = target.bounds.x, .y = target.bounds.y + 3 } });
    try runner.dispatch(.{ .pointer = .{ .kind = .drag, .x = target.bounds.x + runner.widget.cell * 2, .y = target.bounds.y + 3 } });
    try runner.dispatch(.{ .pointer = .{ .kind = .release, .x = target.bounds.x + runner.widget.cell * 2, .y = target.bounds.y + 3 } });
    try runner.dispatch(.{ .key = .{ .code = .{ .char = .{ .bytes = .{ 'c', 0, 0, 0 }, .len = 1 } }, .mods = .{ .super = true } } });
    var request: native.HostRequest = .{};
    try std.testing.expect(runner.widget.host.next(&request));
    try std.testing.expectEqualStrings("fn", request.text.?[0..request.len]);
    ReviewInput.activate(&runner.widget, .{ .kind = .next });
    try std.testing.expectEqual(@as(usize, 1), runner.widget.model.file);
}

test "review prototype visual motions comment on ranges and escape restores single line navigation" {
    const runner = try testRunner();
    defer std.testing.allocator.destroy(runner);
    defer runner.deinit();
    try reviewFrame(runner);
    try runner.dispatch(.{ .text = .{ .bytes = "j" } });
    const start = runner.widget.model.head;
    try runner.dispatch(.{ .text = .{ .bytes = "v" } });
    try runner.dispatch(.{ .text = .{ .bytes = "j" } });
    try runner.dispatch(.{ .key = .{ .code = .down } });
    try std.testing.expect(runner.widget.model.visual);
    try std.testing.expectEqual(start, runner.widget.model.tail);
    try std.testing.expectEqual(start + 2, runner.widget.model.head);
    try runner.dispatch(.{ .text = .{ .bytes = "k" } });
    try std.testing.expectEqual(start + 1, runner.widget.model.head);
    try runner.dispatch(.{ .text = .{ .bytes = "c" } });
    const anchor = runner.widget.model.comments[0].anchor;
    try std.testing.expectEqual(start, anchor.first);
    try std.testing.expectEqual(start + 1, anchor.last);
    try std.testing.expect(!runner.widget.model.visual);
    try reviewFrame(runner);
    try runner.dispatch(.{ .text = .{ .bytes = "v" } });
    try std.testing.expectEqualStrings("v", runner.widget.model.comments[0].body.text());
    try runner.dispatch(.{ .key = .{ .code = .enter, .mods = .{ .super = true } } });
    try std.testing.expectEqualDeep(anchor, runner.widget.model.comments[0].anchor);
    try reviewFrame(runner);
    try runner.dispatch(.{ .text = .{ .bytes = "v" } });
    try runner.dispatch(.{ .text = .{ .bytes = "j" } });
    try runner.dispatch(.{ .key = .{ .code = .escape } });
    try std.testing.expect(!runner.widget.model.visual);
    try std.testing.expectEqual(runner.widget.model.head, runner.widget.model.tail);
    try runner.dispatch(.{ .text = .{ .bytes = "j" } });
    try std.testing.expectEqual(runner.widget.model.head, runner.widget.model.tail);
}

test {
    _ = @import("src/gui/experiments/review/live_review_test.zig");
}
