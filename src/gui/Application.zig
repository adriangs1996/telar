//! Native window assembly. All client mutations run on the window thread;
//! socket workers own only their outstanding transport buffers.
const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const native = @import("native/native.zig");
const GuiClient = @import("GuiClient.zig");
const NativeLoop = @import("NativeLoop.zig");
const Renderer = @import("render/TerminalRenderer.zig");
const Application = @This();

params: client.ClientInit,
driver: NativeLoop,
renderer: Renderer,
gui: ?*GuiClient = null,
failure: ?anyerror = null,
exit_status: ?u8 = null,
cursor_clock: @import("CursorClock.zig") = .{},
input_revision: u64 = 0,

pub fn init(params: client.ClientInit) !Application {
    var renderer = try Renderer.configured(params.gpa, params.io, .{ .config = params.options.gui, .theme = params.options.theme.terminal });
    errdefer renderer.deinit();
    return .{ .params = params, .driver = try .init(params.io), .renderer = renderer, .cursor_clock = .{ .config = params.options.gui.cursor } };
}

pub fn deinit(app: *Application) void {
    app.driver.deinit();
    app.renderer.deinit();
    if (app.gui) |gui| {
        gui.deinit();
    } else {
        const options = app.params.options;
        if (options.lua_generation) |generation| {
            generation.deinit();
        }

        if (options.plugin_registry) |registry| {
            app.params.gpa.destroy(registry);
        }

        if (options.trust_store) |store| {
            app.params.gpa.destroy(store);
        }
    }
}

/// Runs the window and returns only after native GPU consumers have stopped.
/// Example: `const status = try app.run("Telar");`
pub fn run(app: *Application, title: [*:0]const u8) !u8 {
    const callbacks: native.Callbacks = .{ .render = render, .pump = pump, .complete = complete, .input = input, .wake_fd = app.driver.fds[0], .wakeup_after = wakeupAfter };
    const result = native.telar_gui_run(title, app, &callbacks);
    if (app.failure) |err| {
        return err;
    }

    if (result != 0) {
        return error.NativeWindowFailed;
    }

    return app.exit_status orelse 0;
}

fn from(context: ?*anyopaque) *Application {
    return @ptrCast(@alignCast(context.?));
}

fn render(context: ?*anyopaque, viewport: native.Viewport, out: *native.Frame) callconv(.c) void {
    const app = from(context);
    core.mark(app.params.io, .compose_start);
    defer core.mark(app.params.io, .host_flush_start);
    const token = app.prepare(viewport) catch |err| {
        app.fail(err);
        out.* = app.renderer.frame(0);
        return;
    };
    out.* = app.renderer.frame(token);
}

fn prepare(app: *Application, viewport: native.Viewport) !u64 {
    if (app.failure != null or app.exit_status != null) {
        return 0;
    }

    if (app.gui) |gui| {
        if (gui.lifecycle.active != null) {
            return 0;
        }
    }

    app.driver.configuration.observe(app.renderer.config, viewport);
    if (app.gui) |gui| {
        if (try app.driver.configuration.apply(gui, &app.renderer)) {
            app.cursor_clock.config = app.renderer.config.cursor;
            app.cursor_clock.reset(app.now());
        }
    }

    const size = app.renderer.measure(viewport) catch |err| switch (err) {
        error.InvalidTerminalSize => return 0,
        else => return err,
    };
    if (app.gui == null) {
        var params = app.params;
        params.host_size = size;
        params.window_width_px = @as(u32, size.cols) * size.cell_width_px;
        params.window_height_px = @as(u32, size.rows) * size.cell_height_px;
        app.gui = try GuiClient.init(params, &app.driver);
        try app.gui.?.start(.{
            .foreground = params.options.theme.terminal.foreground,
            .background = params.options.theme.terminal.background,
            .palette = params.options.theme.terminal.palette,
        });
    }

    const gui = app.gui.?;
    try gui.resize(size, app.renderer.theme);
    gui.input.setGeometry(app.renderer.origin, size);
    const now_ns = app.now();
    app.cursor_clock.observe(gui.cursorTarget(), now_ns);
    app.renderer.cursor_on = app.cursor_clock.shown(now_ns);
    app.renderer.focused = app.cursor_clock.focused;
    return gui.prepare(&app.renderer);
}

fn pump(context: ?*anyopaque) callconv(.c) c_int {
    const app = from(context);
    if (app.gui) |gui| {
        app.exit_status = gui.pump() catch |err| blk: {
            app.fail(err);
            break :blk null;
        };
    }

    if (app.failure != null or app.exit_status != null) {
        return -1;
    }

    if (app.gui) |gui| {
        const now_ns = app.now();
        if (app.input_revision != gui.input_revision) {
            app.input_revision = gui.input_revision;
            app.cursor_clock.focused = gui.focused;
            app.cursor_clock.reset(now_ns);
        }

        app.cursor_clock.observe(gui.cursorTarget(), now_ns);
        _ = gui.lifecycle.observe(gui.observation());
        if (gui.lifecycle.active != null) {
            return 0;
        }

        return @intFromBool(gui.lifecycle.needsPreparation() or
            app.driver.configuration.pending or
            app.renderer.cursor_on != app.cursor_clock.shown(now_ns) or app.renderer.focused != app.cursor_clock.focused);
    }

    return 0;
}

fn complete(context: ?*anyopaque, token: u64, delivered: c_int) callconv(.c) void {
    const app = from(context);
    core.mark(app.params.io, .host_flush_done);
    if (app.gui != null and token != 0) {
        app.driver.inbox.post(.{ .presented = .{ .token = token, .delivered = delivered != 0 } }) catch |err| app.fail(err);
    }
}

fn input(context: ?*anyopaque, event: native.InputEvent) callconv(.c) c_int {
    const app = from(context);
    if (event.kind == 5) {
        app.driver.inbox.notify(.{ .focus = event.code != 0 }) catch |err| {
            app.fail(err);
            return 0;
        };
        return 1;
    }

    core.mark(app.params.io, .client_input);
    const gui = app.gui orelse return 0;
    gui.input.accept(event) catch return 0;
    app.driver.inbox.notify(.input_ready) catch |err| {
        app.fail(err);
        return 0;
    };
    return 1;
}

fn now(app: *const Application) u64 {
    return @intCast(@max(0, std.Io.Clock.awake.now(app.params.io).toNanoseconds()));
}

fn wakeupAfter(context: ?*anyopaque) callconv(.c) u32 {
    const app = from(context);
    return app.cursor_clock.wakeupAfter(app.now());
}

fn fail(app: *Application, err: anyerror) void {
    if (app.failure == null) {
        std.log.err("native client: {s}", .{@errorName(err)});
        app.failure = err;
    }

    native.telar_gui_wake(app.driver.fds[1]);
}
