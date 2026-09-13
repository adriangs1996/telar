//! One off-thread Lua/font preparation and one pending adoption. Only the
//! window thread resolves client state, after native frame consumers finish.
const std = @import("std");
const client = @import("telar-client");
const native = @import("native/native.zig");
const Renderer = @import("render/TerminalRenderer.zig");
const GuiClient = @import("GuiClient.zig");
const Request = @import("ConfigurationRequest.zig");
const reloads = client.controllers.config_reloads;
const font_rendering = @import("text/font_rendering.zig");
const Reload = @This();

io: std.Io,
inbox: *@import("gui_event.zig").Inbox = undefined,
ticket: ?@import("telar-client").InboxProducerTicket = null,
worker: ?std.Io.Future(void) = null,
ready: std.atomic.Value(bool) = .init(false),
scheduled: ?client.ConfigWaitArgs = null,
request: ?Request = null,
pending: bool = false,
result: anyerror!client.ConfigReload = error.NotStarted,
failure: ?client.Diagnostic = null,
prepared: ?Renderer = null,
retired: ?Renderer = null,
current: client.GuiConfig = .{},
viewport: native.Viewport = .{ .width = 800, .height = 600, .scale = 1 },

/// Captures values, never renderer pointers, for the next preparation.
/// Example: `reload.observe(renderer.config, viewport);`
pub fn observe(reload: *Reload, config: client.GuiConfig, viewport: native.Viewport) void {
    reload.current = config;
    reload.viewport = viewport;
}

/// Rearming records the new generation's borrows; poll starts it after adoption.
/// Example: `try reload.schedule(args);`
pub fn schedule(reload: *Reload, args: client.ConfigWaitArgs) !void {
    if (reload.scheduled != null or reload.worker != null) {
        return error.ConfigWatchAlreadyRunning;
    }

    reload.scheduled = args;
}

/// Joins only completed work. Unchanged fingerprints never request a frame.
/// Example: `try reload.accept(app);`
pub fn accept(reload: *Reload, app: *client.AttachedClient) !void {
    if (reload.ready.swap(false, .acquire)) {
        reload.worker.?.await(reload.io);
        reload.worker = null;
        reload.pending = true;
        if (try reload.result == .unchanged) {
            reload.pending = false;
            reload.request = null;
            _ = try reloads.handle(app, reload.result);
        }
    }
}

/// Starts a scheduled watcher after adoption captured the current generation.
/// Example: `try reload.poll(app);`
pub fn poll(reload: *Reload, _: *client.AttachedClient) !void {
    if (reload.scheduled) |args| {
        std.debug.assert(!reload.pending and reload.worker == null);
        const request: Request = .{ .wait = args, .current = reload.current, .viewport = reload.viewport };
        reload.request = request;
        try reload.launch(load, request);
        reload.scheduled = null;
    }
}

/// Applies one complete generation at the native consumer boundary.
/// Example: `const changed = try reload.apply(gui, &renderer);`
pub fn apply(reload: *Reload, gui: *GuiClient, renderer: *Renderer) !bool {
    if (!reload.pending or gui.lifecycle.active != null) {
        return false;
    }

    var result = try reload.result;
    if (result == .loaded and !font_rendering.same(result.loaded.generation.snapshot.gui.font, reload.request.?.current.font) and
        !std.meta.eql(reload.viewport, reload.request.?.viewport))
    {
        var request = reload.request.?;
        request.viewport = reload.viewport;
        reload.request = request;
        try reload.launch(restage, request);
        reload.pending = false;
        return false;
    }

    if (reload.failure) |diagnostic| {
        const mtime_ns = result.loaded.mtime_ns;
        gui.app.reload.deinit(gui.app.gpa);
        gui.app.reload.clearOrphans();
        result = .{ .failed = .{ .diagnostic = diagnostic, .mtime_ns = mtime_ns } };
        reload.failure = null;
    }

    const config = if (result == .loaded) result.loaded.generation.snapshot.gui else null;
    const theme = if (result == .loaded) result.loaded.generation.snapshot.resolveTheme(
        gui.app.model.hostCapabilities().appearance,
        if (gui.app.options.theme_locked) gui.app.options.theme else null,
    ).terminal else null;
    const generation = if (result == .loaded) result.loaded.generation.number else null;
    reload.pending = false;
    reload.request = null;
    // Physical downstream effects can fail after the common model commits.
    // Keep native resources on that same generation even on this failure path.
    var delivery_error: ?anyerror = null;
    const outcome = reloads.handle(&gui.app, result) catch |err| blk: {
        delivery_error = err;
        break :blk null;
    };
    const adopted = generation != null and gui.app.lua_generation != null and
        gui.app.lua_generation.?.number == generation.?;
    if (adopted) {
        if (reload.prepared) |replacement| {
            std.debug.assert(reload.retired == null);
            reload.retired = renderer.*;
            renderer.* = replacement;
            renderer.atlas_version = reload.retired.?.atlas_version;
            reload.prepared = null;
        }

        renderer.config = config.?;
        renderer.theme = theme.?;
        reload.current = config.?;
    } else if (reload.prepared) |replacement| {
        std.debug.assert(reload.retired == null);
        reload.retired = replacement;
        reload.prepared = null;
    }

    if (outcome != null and outcome.? == .rejected) {
        std.log.scoped(.gui_config).warn("GUI configuration unchanged: {s}", .{gui.app.model.diagnostic() orelse "reload rejected"});
    }

    if (delivery_error) |err| {
        return err;
    }

    return adopted;
}

/// Stop before destroying client generations or closing the wake pipe.
/// Example: `reload.deinit();`
pub fn deinit(reload: *Reload) void {
    if (reload.worker) |*worker| {
        worker.cancel(reload.io);
        reload.worker = null;
    }

    reload.discardPrepared();
    reload.discardRetired();
    reload.scheduled = null;
}

fn load(reload: *Reload, request: Request) void {
    reload.discardRetired();
    reload.result = client.config_reload.wait(request.wait);
    reload.prepare(request);
    reload.publish();
}

fn restage(reload: *Reload, request: Request) void {
    reload.discardPrepared();
    reload.prepare(request);
    reload.publish();
}

fn prepare(reload: *Reload, request: Request) void {
    reload.failure = null;
    const result = reload.result catch return;
    if (result != .loaded) {
        return;
    }

    const config = result.loaded.generation.snapshot.gui;
    if (font_rendering.same(config.font, request.current.font)) {
        return;
    }

    reload.prepared = Renderer.configured(request.wait.gpa, reload.io, .{ .config = config, .viewport = request.viewport }) catch |err| {
        var diagnostic: client.Diagnostic = .{};
        diagnostic.set("cannot prepare GUI font '{s}': {s}", .{ config.font.family.name(), @errorName(err) });
        reload.failure = diagnostic;
        return;
    };
}

fn publish(reload: *Reload) void {
    reload.ready.store(true, .release);
    _ = reload.inbox.publish(reload.ticket.?, .configuration_ready);
}

fn launch(reload: *Reload, comptime function: anytype, request: Request) !void {
    const ticket = try reload.inbox.reserve();
    errdefer reload.inbox.release(ticket);
    reload.ticket = ticket;
    reload.worker = try std.Io.concurrent(reload.io, function, .{ reload, request });
}

fn discardPrepared(reload: *Reload) void {
    if (reload.prepared) |*prepared| {
        prepared.deinit();
        reload.prepared = null;
    }
}

fn discardRetired(reload: *Reload) void {
    if (reload.retired) |*retired| {
        retired.deinit();
        reload.retired = null;
    }
}
