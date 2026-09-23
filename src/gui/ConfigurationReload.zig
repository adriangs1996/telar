//! One off-thread Lua/font preparation and one pending adoption. Only the
//! window thread resolves client state, after native frame consumers finish.
const gui_event = @import("gui_event.zig");
const data = @import("model");
const std = @import("std");
const client = @import("telar-client");
const native = @import("native/native.zig");
const Renderer = @import("render/TerminalRenderer.zig");
const GuiClient = @import("GuiClient.zig");
const Request = @import("ConfigurationRequest.zig");
const font_rendering = @import("text/font_rendering.zig");
const Reload = @This();

io: std.Io,
inbox: *gui_event.Inbox = undefined,
ticket: ?client.InboxProducerTicket = null,
worker: ?std.Io.Future(void) = null,
ready: std.atomic.Value(bool) = .init(false),
scheduled: ?client.ConfigWaitArgs = null,
request: ?Request = null,
pending: bool = false,
result: anyerror!client.ConfigReload = error.NotStarted,
failure: ?data.Diagnostic = null,
prepared: ?Renderer = null,
retired: ?Renderer = null,
current: client.GuiConfig = .{},
viewport: native.Viewport = .{ .width = 800, .height = 600, .scale = 1 },

/// Captures values, never renderer pointers, for the next preparation.
/// Example: `reload.observe(renderer.config, viewport);`
pub fn observe(self: *Reload, config: client.GuiConfig, viewport: native.Viewport) void {
    self.current = config;
    self.viewport = viewport;
}

/// Rearming records the new generation's borrows; poll starts it after adoption.
/// Example: `try reload.schedule(args);`
pub fn schedule(self: *Reload, args: client.ConfigWaitArgs) !void {
    if (self.scheduled != null or self.worker != null) {
        return error.ConfigWatchAlreadyRunning;
    }

    self.scheduled = args;
}

/// Joins only completed work. Unchanged fingerprints never request a frame.
/// Example: `try reload.accept(app);`
pub fn accept(self: *Reload, app: *client.AttachedClient) !void {
    if (self.ready.swap(false, .acquire)) {
        self.worker.?.await(self.io);
        self.worker = null;
        self.pending = true;
        if (try self.result == .unchanged) {
            self.pending = false;
            self.request = null;
            _ = try client.config_adoption.completeConfigReload(app, self.result);
        }
    }
}

/// Starts a scheduled watcher after adoption captured the current generation.
/// Example: `try reload.poll(app);`
pub fn poll(self: *Reload, _: *client.AttachedClient) !void {
    if (self.scheduled) |args| {
        std.debug.assert(!self.pending and self.worker == null);
        const request: Request = .{ .wait = args, .current = self.current, .viewport = self.viewport };
        self.request = request;
        try self.launch(load, request);
        self.scheduled = null;
    }
}

/// Applies one complete generation at the native consumer boundary.
/// Example: `const changed = try reload.apply(gui, &renderer);`
pub fn apply(self: *Reload, gui: *GuiClient, renderer: *Renderer) !bool {
    if (!self.pending or gui.app.presentation.active != null) {
        return false;
    }

    var result = try self.result;
    if (result == .loaded and !font_rendering.same(result.loaded.generation.snapshot.gui.font, self.request.?.current.font) and
        !std.meta.eql(self.viewport, self.request.?.viewport))
    {
        var request = self.request.?;
        request.viewport = self.viewport;
        self.request = request;
        try self.launch(restage, request);
        self.pending = false;
        return false;
    }

    if (self.failure) |diagnostic| {
        const mtime_ns = result.loaded.mtime_ns;
        gui.app.reload.deinit(gui.app.gpa);
        gui.app.reload.clearOrphans();
        result = .{ .failed = .{ .diagnostic = diagnostic, .mtime_ns = mtime_ns } };
        self.failure = null;
    }

    const config = if (result == .loaded) result.loaded.generation.snapshot.gui else null;
    const theme = if (result == .loaded) result.loaded.generation.snapshot.resolveTheme(
        gui.app.model.host.host_capabilities.appearance,
        if (gui.app.options.theme_locked) gui.app.options.theme else null,
    ).terminal else null;
    const generation = if (result == .loaded) result.loaded.generation.number else null;
    self.pending = false;
    self.request = null;
    // Physical downstream effects can fail after the common model commits.
    // Keep native resources on that same generation even on this failure path.
    var delivery_error: ?anyerror = null;
    const outcome = client.config_adoption.completeConfigReload(&gui.app, result) catch |err| blk: {
        delivery_error = err;
        break :blk null;
    };
    const adopted = generation != null and gui.app.lua_generation != null and
        gui.app.lua_generation.?.number == generation.?;
    if (adopted) {
        if (self.prepared) |replacement| {
            std.debug.assert(self.retired == null);
            self.retired = renderer.*;
            renderer.* = replacement;
            renderer.atlas_version = self.retired.?.atlas_version;
            renderer.sprites_version = self.retired.?.sprites_version;
            self.prepared = null;
        }

        renderer.config = config.?;
        renderer.theme = theme.?;
        self.current = config.?;
        if (gui.sidebar.reload(config.?.sidebar.width)) {
            gui.chrome.invalidate();
        }
    } else if (self.prepared) |replacement| {
        std.debug.assert(self.retired == null);
        self.retired = replacement;
        self.prepared = null;
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
pub fn deinit(self: *Reload) void {
    if (self.worker) |*worker| {
        worker.cancel(self.io);
        self.worker = null;
    }

    self.discardPrepared();
    self.discardRetired();
    self.scheduled = null;
}

fn load(self: *Reload, request: Request) void {
    self.discardRetired();
    self.result = client.config_reload.wait(request.wait);
    self.prepare(request);
    self.publish();
}

fn restage(self: *Reload, request: Request) void {
    self.discardPrepared();
    self.prepare(request);
    self.publish();
}

fn prepare(self: *Reload, request: Request) void {
    self.failure = null;
    const result = self.result catch return;
    if (result != .loaded) {
        return;
    }

    const config = result.loaded.generation.snapshot.gui;
    if (font_rendering.same(config.font, request.current.font)) {
        return;
    }

    self.prepared = Renderer.configured(request.wait.gpa, self.io, .{ .config = config, .viewport = request.viewport }) catch |err| {
        var diagnostic: data.Diagnostic = .{};
        diagnostic.set("cannot prepare GUI font '{s}': {s}", .{ config.font.family.name(), @errorName(err) });
        self.failure = diagnostic;
        return;
    };
}

fn publish(self: *Reload) void {
    self.ready.store(true, .release);
    _ = self.inbox.publish(self.ticket.?, .configuration_ready);
}

fn launch(self: *Reload, comptime function: anytype, request: Request) !void {
    const ticket = try self.inbox.reserve();
    errdefer self.inbox.release(ticket);
    self.ticket = ticket;
    self.worker = try std.Io.concurrent(self.io, function, .{ self, request });
}

fn discardPrepared(self: *Reload) void {
    if (self.prepared) |*prepared| {
        prepared.deinit();
        self.prepared = null;
    }
}

fn discardRetired(self: *Reload) void {
    if (self.retired) |*retired| {
        retired.deinit();
        self.retired = null;
    }
}
