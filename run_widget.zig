//! A single challenge: maintain a contiguous array of quads across input changes.
//! Edit src/gui/experiments/frame/problem.zig, function solve.
//! Run: zig build run-widget -Doptimize=ReleaseFast
//! Measure without a window: zig build run-widget -Doptimize=ReleaseFast -- --bench
//! Test: zig build test-widget
//!
//! This file contains only native window/input/frame ownership and build wiring.
const std = @import("std");
const data = @import("model");
const macos_gui = @import("build/macos_gui.zig");
const linux_gui = @import("build/linux_gui.zig");
const native = @import("src/gui/native/native.zig");
const decode_input = @import("src/gui/native/decode_input.zig");
const event_module = @import("src/gui/input/event.zig");
const benchmark = @import("src/gui/experiments/frame/benchmark.zig");
const BuildApplication = @import("build/Application.zig");
const Renderer = @import("src/gui/render/TerminalRenderer.zig");
const Canvas = @import("src/gui/widgets/Canvas.zig");
const WidgetState = @import("src/gui/widgets/interaction/State.zig");
const Widget = @import("src/gui/experiments/frame/Widget.zig");
const GenericEventPool = @import("src/gui/input/GenericEventPool.zig").Type;

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
    renderer: Renderer,
    widget: Widget,
    widgets: WidgetState = .{},
    inbox: Inbox = .{},
    fds: [2]c_int = .{ -1, -1 },
    dirty: bool = true,
    next_token: u64 = 1,
    in_flight: ?u64 = null,
    completion_queued: bool = false,
    failure: ?anyerror = null,

    fn init(allocator: std.mem.Allocator, io: std.Io) !Runner {
        var self: Runner = .{ .renderer = .init(allocator), .widget = .{ .io = io } };
        errdefer self.renderer.deinit();
        self.renderer.io = io;
        self.renderer.sidebar_request.visible = false;
        if (native.telar_gui_pipe(&self.fds) != 0) {
            return error.NativeWakePipeFailed;
        }

        return self;
    }

    fn deinit(self: *Runner) void {
        native.telar_gui_close_pipe(&self.fds);
        self.renderer.deinit();
    }

    // The consumer owns a submitted frame until its exact completion arrives.
    fn prepare(self: *Runner, viewport: native.Viewport) !native.Frame {
        if (self.in_flight != null or self.failure != null) {
            return self.renderer.frame(0);
        }

        _ = self.renderer.measure(viewport) catch |err| switch (err) {
            error.InvalidTerminalSize => return self.renderer.frame(0),
            else => return err,
        };
        self.renderer.begin();
        self.widgets.begin(false);
        var canvas: Canvas = .{
            .atlas = &self.renderer.atlas.?,
            .quads = &self.renderer.quads,
            .metrics = self.renderer.metrics,
            .origin = .{ 0, 0 },
            .theme = data.theme_support.default_theme,
            .chrome = self.renderer.chrome,
            .viewport = self.renderer.viewport,
            .widgets = &self.widgets,
        };
        try self.widget.draw(&canvas);
        self.widgets.seal();
        self.renderer.seal();
        const token = self.next_token;
        self.next_token = try std.math.add(u64, token, 1);
        self.in_flight = token;
        self.dirty = false;
        return self.renderer.frame(token);
    }

    fn finish(self: *Runner, result: Completion) void {
        if (self.in_flight == null or self.in_flight.? != result.token) {
            return;
        }

        self.in_flight = null;
        const revision = self.widgets.dispatcher.revision;
        self.widgets.dispatcher.present(result.delivered);
        self.dirty = self.dirty or !result.delivered or revision != self.widgets.dispatcher.revision;
    }

    fn dispatch(self: *Runner, value: event_module.Event) !void {
        const revision = self.widgets.dispatcher.revision;
        const route = self.widgets.dispatcher.route(value);
        self.dirty = try self.widget.input(value, route) or self.dirty or revision != self.widgets.dispatcher.revision;
    }

    fn fail(self: *Runner, err: anyerror) void {
        self.failure = err;
        std.log.err("frame challenge: {s}", .{@errorName(err)});
        native.telar_gui_wake(self.fds[1]);
    }
};

/// Example: `zig build run-widget -Doptimize=ReleaseFast -- --bench`.
pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--bench")) {
            return benchmark.main(init);
        }

        if (!std.mem.eql(u8, arg, "gui")) {
            return error.UnknownArgument;
        }
    }

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
    };
    const result = native.telar_gui_run("Telar frame challenge", runner, &callbacks);
    if (runner.failure) |err| {
        return err;
    }

    if (result != 0) {
        return error.NativeWindowFailed;
    }
}

/// Registers the executable and its checks. Example: run_widget.addBuild(b, app);
pub fn addBuild(b: *std.Build, app: BuildApplication) void {
    const os = app.modules.target.result.os.tag;
    if (!app.modules.native_client) {
        return;
    }

    const module = b.createModule(.{ .root_source_file = b.path("run_widget.zig"), .target = app.modules.target, .optimize = app.modules.optimize, .link_libc = true });
    module.addImport("telar-core", app.modules.core);
    module.addImport("telar-client", app.modules.client);
    module.addImport("model", app.modules.data);
    module.addImport("assets", app.modules.assets);
    module.addImport("freetype", app.modules.freetype);
    app.modules.libraries.addImports(module);
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
    const tests = b.addTest(.{ .root_module = module, .filters = &.{ "widget runner", "frame challenge" } });
    b.step("test-widget", "Check widget runner input and presentation ownership").dependOn(&b.addRunArtifact(tests).step);
}

fn from(context: ?*anyopaque) *Runner {
    return @ptrCast(@alignCast(context.?));
}

fn render(context: ?*anyopaque, viewport: native.Viewport, out: *native.Frame) callconv(.c) void {
    const runner = from(context);
    out.* = runner.prepare(viewport) catch |err| blk: {
        runner.fail(err);
        break :blk runner.renderer.frame(0);
    };
}

fn input(context: ?*anyopaque, raw: native.InputEvent) callconv(.c) c_int {
    const runner = from(context);
    const event = decode_input.decode(raw) catch return 0;
    // Only these events belong to this challenge; no clipboard/editor services.
    switch (event) {
        .text, .key, .pointer, .focus => {},
        else => return 0,
    }

    runner.inbox.push(event) catch |err| {
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

    return @intFromBool(runner.in_flight == null and runner.dirty);
}

test "widget runner challenge preserves in-flight frames and delivered controls" {
    const runner = try std.testing.allocator.create(Runner);
    defer std.testing.allocator.destroy(runner);
    runner.* = try Runner.init(std.testing.allocator, std.testing.io);
    defer runner.deinit();
    runner.renderer.io = null;
    const viewport: native.Viewport = .{ .width = 1100, .height = 720, .scale = 1 };
    const first = try runner.prepare(viewport);
    try std.testing.expect(first.token != 0);
    const saved = try std.testing.allocator.dupe(u8, std.mem.sliceAsBytes(runner.renderer.quads.items()));
    defer std.testing.allocator.free(saved);
    try runner.dispatch(.{ .text = .{ .bytes = "1" } });
    const blocked = try runner.prepare(.{ .width = 1600, .height = 960, .scale = 2 });
    try std.testing.expectEqual(@as(u64, 0), blocked.token);
    try std.testing.expectEqualSlices(u8, saved, std.mem.sliceAsBytes(runner.renderer.quads.items()));
    runner.finish(.{ .token = first.token + 1, .delivered = true });
    try std.testing.expectEqual(first.token, runner.in_flight.?);
    complete(runner, first.token, 1);
    complete(runner, first.token, 1);
    try std.testing.expectEqual(@as(c_int, 1), pump(runner));
    const frame = try runner.prepare(viewport);
    runner.finish(.{ .token = frame.token, .delivered = true });
    const steps = runner.widget.demo.steps;
    try runner.dispatch(.{ .pointer = .{ .kind = .press, .x = 50, .y = 160 } });
    try runner.dispatch(.{ .pointer = .{ .kind = .release, .x = 50, .y = 160 } });
    try std.testing.expectEqual(steps + 1, runner.widget.demo.steps);
    try std.testing.expectEqual(@as(usize, 0), runner.widget.demo.cost.quads_copied);
    const next = try runner.prepare(viewport);
    runner.finish(.{ .token = next.token, .delivered = false });
    try std.testing.expect(runner.dirty);
    const retry = try runner.prepare(viewport);
    runner.finish(.{ .token = retry.token, .delivered = true });
    try std.testing.expectEqual(@as(c_int, 0), pump(runner));
}

test {
    _ = @import("src/gui/experiments/frame/tests.zig");
}
