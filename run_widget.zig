//! A single challenge: maintain a contiguous array of quads across input changes.
//! Edit src/gui/experiments/frame/problem.zig, function solve.
//! Run: zig build run-widget -Doptimize=ReleaseFast
//! Measure without a window: zig build run-widget -Doptimize=ReleaseFast -- --bench
//!
//! This file contains only native window/input/frame ownership and build wiring.
const std = @import("std");
const data = @import("model");
const macos_gui = @import("build/macos_gui.zig");
const linux_gui = @import("build/linux_gui.zig");
const native = @import("src/gui/native/native.zig");
const event_module = @import("telar-window");
const benchmark = @import("src/gui/experiments/frame/benchmark.zig");
const BuildApplication = @import("build/Application.zig");
const Renderer = @import("src/gui/render/Renderer.zig");
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
    // SAFETY: Enqueue writes each ring slot before increasing len; drain reads only queued slots.
    messages: [64]Message = undefined,
    head: usize = 0,
    len: usize = 0,

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

    fn finish(self: *Runner, result: Completion) void {
        if (self.in_flight == null or self.in_flight.? != result.token) {
            return;
        }

        self.in_flight = null;
        const revision = self.widgets.dispatcher.revision;
        self.widgets.dispatcher.present(result.delivered);
        self.dirty = self.dirty or !result.delivered or revision != self.widgets.dispatcher.revision;
    }

    fn dispatch(self: *Runner, value: event_module.Input) !void {
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

    // The native callback loop has been removed. Keep --bench available while
    // this experiment's scene drawing is ported to the new renderer contract.
    return error.WindowLoopMigrationPending;
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
        macos_gui.add(b, module);
    } else {
        linux_gui.add(b, module);
    }

    const executable = b.addExecutable(.{ .name = "run-widget", .root_module = module });
    const install = b.addInstallArtifact(executable, .{});
    b.step("build-widget", "Build the single-file native widget runner").dependOn(&install.step);
    const run = b.addRunArtifact(executable);
    if (b.args) |args| {
        run.addArgs(args);
    }
    b.step("run-widget", "Run your widget with Telar's native GUI plumbing").dependOn(&run.step);
}

fn from(context: ?*anyopaque) *Runner {
    return @ptrCast(@alignCast(context.?));
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
