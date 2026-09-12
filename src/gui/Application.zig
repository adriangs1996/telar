//! Native window assembly. All client mutations run on the window thread;
//! socket workers own only their outstanding transport buffers.
const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const native = @import("native/native.zig");
const GuiClient = @import("GuiClient.zig");
const RuntimeDriver = @import("RuntimeDriver.zig");
const Renderer = @import("render/TerminalRenderer.zig");
const cell_colors = @import("render/cell_colors.zig");
const Application = @This();

params: client.ClientInit,
driver: RuntimeDriver,
renderer: Renderer,
gui: ?*GuiClient = null,
failure: ?anyerror = null,
exit_status: ?u8 = null,

pub fn init(params: client.ClientInit) !Application {
    return .{ .params = params, .driver = try .init(params.io), .renderer = .init(params.gpa) };
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
    const callbacks: native.Callbacks = .{ .render = render, .pump = pump, .complete = complete, .input = input, .wake_fd = app.driver.fds[0] };
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
        const foreground = cell_colors.resolve(params.options.theme.palette.text, .white);
        const background = cell_colors.resolve(params.options.theme.palette.panel_bg, .black);
        try app.gui.?.start(.{
            .foreground = .{ @intFromFloat(foreground.r * 255), @intFromFloat(foreground.g * 255), @intFromFloat(foreground.b * 255) },
            .background = .{ @intFromFloat(background.r * 255), @intFromFloat(background.g * 255), @intFromFloat(background.b * 255) },
        });
    }

    const gui = app.gui.?;
    try gui.resize(size);
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
        const version = gui.app.model.version();
        return @intFromBool(!std.meta.eql(version, gui.lifecycle.prepared.model) or gui.lifecycle.preparation_invalid);
    }

    return 0;
}

fn complete(context: ?*anyopaque, token: u64, delivered: c_int) callconv(.c) void {
    const app = from(context);
    if (app.gui) |gui| {
        gui.complete(token, delivered != 0) catch |err| app.fail(err);
    }
}

fn input(context: ?*anyopaque, event: native.InputEvent) callconv(.c) c_int {
    const app = from(context);
    const gui = app.gui orelse return 0;
    gui.input.accept(event) catch return 0;
    gui.input.drain(&gui.app) catch |err| {
        app.fail(err);
        return 0;
    };
    return 1;
}

fn fail(app: *Application, err: anyerror) void {
    if (app.failure == null) {
        std.log.err("native client: {s}", .{@errorName(err)});
        app.failure = err;
    }

    native.telar_gui_wake(app.driver.fds[1]);
}
