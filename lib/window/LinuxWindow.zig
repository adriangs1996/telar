const std = @import("std");
pub const ClipboardSource = @import("linux/ClipboardSource.zig");
const Appearance = @import("Appearance.zig");
const Options = @import("Options.zig");
const event = @import("Event.zig");
pub const Event = event.Event;
const input = @import("input/Input.zig");
pub const Input = input.Input;
const native_input = @import("input/NativeInput.zig");
pub const NativeInput = native_input.NativeInput;
const LinuxSurface = @import("LinuxSurface.zig");
pub const Surface = LinuxSurface;
pub const Viewport = @import("Viewport.zig");
const wake_pipe = @import("wake_pipe.zig");
const wayland = @import("wayland.zig");
const c = wayland.c;

const LinuxWindow = @This();
const HostState = @import("HostState.zig");
const LinuxInput = @import("linux/Input.zig");
const Accessibility = @import("linux/Accessibility.zig");
const display_rate = @import("linux/display_rate.zig");
pub const TextContext = c.telar_gui_text_context;
pub const HostRequest = c.telar_gui_host_request;
pub const AccessibilityTree = c.telar_gui_accessibility_tree;

// Wayland retains listener data, so its address must survive returning init.
const Native = struct {
    display: *c.wl_display,
    host: HostState = .{},
    input: ?LinuxInput = null,
    accessibility: ?*Accessibility = null,
    outputs: c.telar_outputs = std.mem.zeroes(c.telar_outputs),
    rate: c.telar_display_rate = std.mem.zeroes(c.telar_display_rate),
    fullscreen: bool = false,
    decoration: c.telar_decoration = std.mem.zeroes(c.telar_decoration),
    background: c.telar_background_effect = std.mem.zeroes(c.telar_background_effect),
    registry: ?*c.wl_registry = null,
    compositor: ?*c.wl_compositor = null,
    shell: ?*c.xdg_wm_base = null,
    drawing_surface: ?LinuxSurface = null,
    xdg_surface: ?*c.xdg_surface = null,
    toplevel: ?*c.xdg_toplevel = null,
    configured: bool = false,
    closed: bool = false,
    wake_pending: bool = false,
    width: i32 = 800,
    height: i32 = 480,
};

const ProtocolVersion = enum(u32) {
    initial = 1,
    compositor = 4,
};

const minimum_width = 320;
const minimum_height = 200;

const registry_listener: c.wl_registry_listener = .{
    .global = global,
    .global_remove = globalRemove,
};

const shell_listener: c.xdg_wm_base_listener = .{
    .ping = ping,
};

const surface_listener: c.xdg_surface_listener = .{
    .configure = configure,
};

const toplevel_listener: c.xdg_toplevel_listener = .{
    .configure = resize,
    .close = close,
    .configure_bounds = null,
    .wm_capabilities = null,
};

native: *Native,
/// Borrowed descriptor, polled alongside the Wayland display by event retrieval.
wake_fd: c_int,

/// Connects to Wayland and creates an unmapped toplevel. Mapping requires the
/// renderer's first buffer; configure events remain the window's responsibility.
pub fn init(options: Options) !LinuxWindow {
    if (!wake_pipe.isReadable(options.wake_fd)) {
        return error.InvalidWakeDescriptor;
    }

    if (!std.unicode.utf8ValidateSlice(std.mem.span(options.title))) {
        return error.InvalidTitle;
    }

    const display = c.wl_display_connect(null) orelse return error.DisplayConnectionFailed;

    const native = std.heap.c_allocator.create(Native) catch |err| {
        c.wl_display_disconnect(display);
        return err;
    };

    native.* = .{
        .display = display,
    };

    var self: LinuxWindow = .{
        .native = native,
        .wake_fd = options.wake_fd,
    };

    errdefer self.deinit();

    native.input = try LinuxInput.init(&native.host, &native.outputs);
    native.accessibility = try Accessibility.init(&native.host);
    native.registry = c.wl_display_get_registry(display) orelse return error.WindowCreationFailed;

    if (c.wl_registry_add_listener(native.registry, &registry_listener, native) != 0) {
        return error.ListenerRegistrationFailed;
    }

    if (c.wl_display_roundtrip(display) < 0) {
        return error.DisplayConnectionFailed;
    }

    if (native.compositor == null or native.shell == null) {
        return error.MissingWindowProtocol;
    }

    native.drawing_surface = try LinuxSurface.init(display, native.compositor.?);
    native.xdg_surface = c.xdg_wm_base_get_xdg_surface(native.shell, native.drawing_surface.?.handle) orelse return error.WindowCreationFailed;

    if (c.xdg_surface_add_listener(native.xdg_surface, &surface_listener, native) != 0) {
        return error.ListenerRegistrationFailed;
    }

    native.toplevel = c.xdg_surface_get_toplevel(native.xdg_surface) orelse return error.WindowCreationFailed;

    if (c.xdg_toplevel_add_listener(native.toplevel, &toplevel_listener, native) != 0) {
        return error.ListenerRegistrationFailed;
    }

    c.xdg_toplevel_set_title(native.toplevel, options.title);
    c.xdg_toplevel_set_app_id(native.toplevel, "telar");
    c.xdg_toplevel_set_min_size(native.toplevel, minimum_width, minimum_height);
    if (!display_rate.attach(&native.rate, &native.outputs, native.drawing_surface.?.handle)) {
        return error.DisplayListenerFailed;
    }

    if (!c.telar_decoration_attach(&native.decoration, native.toplevel)) {
        return error.DecorationCreationFailed;
    }
    native.background.compositor = native.compositor;
    native.background.surface = native.drawing_surface.?.handle;
    c.wl_surface_commit(native.drawing_surface.?.handle);

    return self;
}

/// Borrows the window's surface without allocating or transferring ownership.
/// Finish using it and release renderer resources before deinit; the borrower
/// must not destroy the surface or disconnect its Wayland display.
pub fn surface(self: *LinuxWindow) *LinuxSurface {
    return &self.native.drawing_surface.?;
}

/// Pumps native services on the owning thread and returns semantic input,
/// geometry, screen cadence, close and wake events. Input payloads remain valid
/// until the next call. Geometry and wake notifications coalesce.
/// A disconnected display or wake pipe returns an error instead of spinning.
pub fn getNextEvent(self: *LinuxWindow) !Event {
    const native = self.native;
    native.host.inputs.retire();
    if (native.closed) {
        return .close;
    }

    while (true) {
        if (try native.host.next()) |pending| {
            return pending;
        }

        native.input.?.poll(LinuxInput.now());
        native.input.?.text_input.publish();
        native.accessibility.?.receive();
        native.accessibility.?.publish();
        c.telar_cursor_apply(native.input.?.pointer.cursor, native.host.pointer);
        if (native.input.?.fullscreen_requested) {
            native.input.?.fullscreen_requested = false;
            self.toggleFullscreen();
        }
        if (c.wl_display_dispatch_pending(native.display) < 0) {
            return error.DisplayConnectionFailed;
        }

        if (native.closed) {
            return .close;
        }

        if (display_rate.take(&native.rate)) |interval| {
            native.host.displayInterval(interval);
        }

        if (try native.host.next()) |pending| {
            return pending;
        }

        const runtime_ready = try wake_pipe.take(self.wake_fd);
        // SAFETY: eventfd_read receives signal as output storage; only its return code is used.
        var signal: c.eventfd_t = undefined;
        const completed = c.eventfd_read(self.surface().completion_fd, &signal);
        if (completed < 0 and c.__errno_location().* != c.EAGAIN and c.__errno_location().* != c.EINTR) {
            return error.CompletionReadFailed;
        }

        var images: c.pollfd = .{ .fd = self.surface().imagesFd(), .events = c.POLLIN, .revents = 0 };
        const images_ready = c.poll(&images, 1, 0) > 0;
        if (runtime_ready or completed == 0 or images_ready or native.wake_pending) {
            native.wake_pending = false;
            return .wake;
        }

        try self.waitForActivity();
    }
}

/// Follow libwayland's prepare/read-or-cancel protocol because the Vulkan worker
/// also uses this connection. Every successful prepare has exactly one read or
/// cancellation, including errors and wake-only polls. Flush backpressure adds
/// POLLOUT to the wait; the next iteration retries without blocking other fds.
fn waitForActivity(self: *LinuxWindow) !void {
    const display = self.native.display;
    if (c.wl_display_prepare_read(display) != 0) {
        if (c.__errno_location().* != c.EAGAIN) {
            return error.DisplayConnectionFailed;
        }

        return;
    }

    var prepared = true;
    defer if (prepared) c.wl_display_cancel_read(display);
    var write_blocked = false;
    while (c.wl_display_flush(display) < 0) {
        switch (c.__errno_location().*) {
            c.EINTR => continue,
            c.EAGAIN => write_blocked = true,
            else => return error.DisplayConnectionFailed,
        }

        break;
    }

    var descriptors = [_]c.pollfd{
        .{ .fd = c.wl_display_get_fd(display), .events = @intCast(c.POLLIN | @as(c_int, if (write_blocked) c.POLLOUT else 0)), .revents = 0 },
        .{ .fd = self.wake_fd, .events = c.POLLIN, .revents = 0 },
        .{ .fd = self.surface().completion_fd, .events = c.POLLIN, .revents = 0 },
        .{ .fd = self.surface().imagesFd(), .events = c.POLLIN, .revents = 0 },
        .{ .fd = self.native.input.?.reader.fd, .events = c.POLLIN, .revents = 0 },
        .{ .fd = self.native.accessibility.?.actions_wake[0], .events = c.POLLIN, .revents = 0 },
    };

    const client_timeout = try self.native.host.timeout();
    const input_timeout = self.native.input.?.timeout(LinuxInput.now());
    const timeout = if (client_timeout < 0) input_timeout else if (input_timeout < 0) client_timeout else @min(client_timeout, input_timeout);
    if (c.poll(&descriptors, descriptors.len, timeout) < 0) {
        if (c.__errno_location().* == c.EINTR) {
            return;
        }

        return error.EventWaitFailed;
    }

    if (descriptors[0].revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL) != 0) {
        return error.DisplayConnectionFailed;
    }

    if (descriptors[2].revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL) != 0) {
        return error.CompletionReadFailed;
    }

    if (descriptors[0].revents & c.POLLIN != 0) {
        prepared = false;
        if (c.wl_display_read_events(display) < 0) {
            return error.DisplayConnectionFailed;
        }
    }
}

/// Schedules one wake after a monotonic delay; zero cancels the pending deadline.
pub fn setTitle(self: *LinuxWindow, title: []const u8) !void {
    const terminated = try std.heap.c_allocator.dupeZ(u8, title);
    defer std.heap.c_allocator.free(terminated);
    c.xdg_toplevel_set_title(self.native.toplevel, terminated);
}

pub fn wakeAfter(self: *LinuxWindow, delay_ms: u32) !void {
    try self.native.host.wakeAfter(delay_ms);
}

/// Negotiates a PNG transfer on the window thread. Only its owned pipe goes
/// to the worker; all Wayland proxy calls stay on this thread.
pub fn clipboardSource(self: *LinuxWindow) !ClipboardSource {
    return .{ .fd = try self.native.input.?.imageSource(self.native.display) };
}

/// Requests native decorations and compositor blur before the next buffer commit.
/// A compositor without the optional blur protocol keeps transparency only.
pub fn setAppearance(self: *LinuxWindow, value: Appearance) !void {
    const native = self.native;
    c.telar_decoration_apply(&native.decoration, @intFromBool(value.titlebar));
    if (!c.telar_background_effect_apply(&native.background, .{
        .width = @intCast(@max(1, native.width)),
        .height = @intCast(@max(1, native.height)),
        .scale = 1,
        .controls = 0,
    }, value.opacity, value.blur)) {
        return error.BackgroundEffectFailed;
    }
}

/// Copies the editing snapshot used by Wayland text-input-v3. Native services
/// keep their provisional mirror while earlier input awaits GUI consumption.
pub fn setTextContext(self: *LinuxWindow, value: TextContext) !void {
    try self.native.host.setTextContext(value);
}

/// Copies one clipboard request for native services; its result returns as
/// input.clipboard. A full pending slot returns HostRequestsFull for caller retry.
pub fn requestHost(self: *LinuxWindow, value: HostRequest) !void {
    try self.native.host.requestHost(value);
}

/// Copies the semantic tree used by native accessibility queries. Actions from
/// assistive clients return through getNextEvent with the snapshot identity.
pub fn setAccessibility(self: *LinuxWindow, value: AccessibilityTree) !void {
    try self.native.host.setAccessibility(value);
}

pub fn setPointerShape(self: *LinuxWindow, shape: u32) !void {
    if (shape > 33) {
        return error.InvalidPointerShape;
    }

    self.native.host.pointer = shape;
}

/// The existing keyboard translator recognizes the fullscreen shortcut. The
/// request stays native; its configured geometry returns through getNextEvent.
fn toggleFullscreen(self: *LinuxWindow) void {
    const native = self.native;
    const toplevel = native.toplevel orelse return;
    native.fullscreen = !native.fullscreen;
    if (native.fullscreen) {
        c.xdg_toplevel_set_fullscreen(toplevel, null);
    } else {
        c.xdg_toplevel_unset_fullscreen(toplevel);
    }
}

pub fn deinit(self: *LinuxWindow) void {
    const native = self.native;
    if (native.drawing_surface) |*value| {
        value.stop();
    }

    if (native.accessibility) |accessibility| {
        accessibility.deinit();
    }
    if (native.input) |*service| {
        service.deinit();
    }
    display_rate.deinit(&native.rate);
    c.telar_outputs_deinit(&native.outputs);

    c.telar_background_effect_deinit(&native.background);
    c.telar_decoration_deinit(&native.decoration);
    if (native.toplevel) |value| {
        c.xdg_toplevel_destroy(value);
    }

    if (native.xdg_surface) |value| {
        c.xdg_surface_destroy(value);
    }

    if (native.drawing_surface) |*value| {
        value.deinit();
    }

    if (native.shell) |value| {
        c.xdg_wm_base_destroy(value);
    }

    if (native.compositor) |value| {
        c.wl_compositor_destroy(value);
    }

    if (native.registry) |value| {
        c.wl_registry_destroy(value);
    }

    c.wl_display_disconnect(native.display);
    std.heap.c_allocator.destroy(native);
    self.* = undefined;
}

/// Receives wl_registry.global through registry_listener, installed by init's
/// wl_registry_add_listener. The compositor announces each available interface
/// after registry creation, and may announce more while the connection lives.
/// init's wl_display_roundtrip dispatches the initial announcements; later
/// dispatches must happen on the window owner thread. libwayland invokes this
/// function through the C listener, so it has no direct Zig call sites.
///
/// name identifies this advertised global, interface names its protocol, and
/// version is the highest version the compositor offers. Binding creates our
/// client-side proxy: wl_compositor creates wl_surfaces; xdg_wm_base gives them
/// desktop window roles. We bind the compositor at at most version 4 and the
/// shell at version 1, keeping only the first proxy for each interface.
///
/// data is the stable heap-allocated Native passed when registering the listener.
/// interface is borrowed for this callback and is not retained. Register the
/// shell's ping listener immediately; failure destroys that proxy and leaves it
/// null so init can reject the missing capability after the roundtrip.
fn global(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
    const native: *Native = @ptrCast(@alignCast(data.?));
    native.background.registry = registry;
    c.telar_background_effect_global(&native.background, name, interface);

    const advertised: c.telar_registry_global = .{ .registry = registry, .name = name, .version = version, .interface = interface };
    c.telar_decoration_global(&native.decoration, &advertised);
    c.telar_outputs_global(&native.outputs, &advertised);
    native.input.?.global(&advertised);
    if (std.mem.eql(u8, std.mem.span(interface), "wl_compositor") and native.compositor == null) {
        native.compositor = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_compositor_interface, @min(version, @intFromEnum(ProtocolVersion.compositor))));
    } else if (std.mem.eql(u8, std.mem.span(interface), "xdg_wm_base") and native.shell == null) {
        native.shell = @ptrCast(c.wl_registry_bind(registry, name, &c.xdg_wm_base_interface, @intFromEnum(ProtocolVersion.initial)));

        if (native.shell) |shell| {
            if (c.xdg_wm_base_add_listener(shell, &shell_listener, native) != 0) {
                c.xdg_wm_base_destroy(shell);
                native.shell = null;
            }
        }
    }
}

/// Receives wl_registry.global_remove through registry_listener during event
/// dispatch. name is the numeric global identifier previously given to global;
/// removal means that interface is no longer advertised by the compositor.
/// An existing bound proxy remains valid to avoid races, but requests to the
/// removed global are ignored; the client should release that proxy.
///
/// Input and output services release their removed globals here. Compositor and
/// shell disappearance still has no recovery path; window teardown releases
/// those proxies through deinit.
fn globalRemove(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32) callconv(.c) void {
    _ = registry;
    const native: *Native = @ptrCast(@alignCast(data.?));
    c.telar_decoration_remove(&native.decoration, name);
    c.telar_background_effect_remove(&native.background, name);
    native.input.?.remove(name);
    c.telar_outputs_remove(&native.outputs, name);
}

/// Receives xdg_wm_base.ping through shell_listener, installed by global when it
/// binds the shell. Runs when libwayland dispatches that message on the window
/// thread. The compositor uses it to check that the client is responsive.
/// Reply on the same shell with the exact serial supplied by the compositor;
/// leaving it unanswered can make the compositor treat the client as hung.
/// The reply is queued on the Wayland connection for its next flush. No model
/// update or redraw is needed, and the listener's Native pointer is unused.
fn ping(data: ?*anyopaque, shell: ?*c.xdg_wm_base, serial: u32) callconv(.c) void {
    _ = data;
    c.xdg_wm_base_pong(shell, serial);
}

/// Receives xdg_surface.configure through surface_listener, installed in init.
/// The compositor sends it after the initial bufferless surface commit and at
/// the end of subsequent configuration sequences. Preceding xdg_toplevel.configure
/// messages reach resize and store the proposed geometry in the same Native.
///
/// This event closes that sequence. Acknowledge its serial and mark the initial
/// configuration as received; the first buffer must not be committed before
/// the initial configuration is acknowledged. This acknowledgement accepts a
/// window configuration, not a rendered frame or an application-state update.
/// Pass its geometry to the canvas so subsequent batches may acquire buffers.
///
/// Runs during Wayland event dispatch; data is init's stable Native pointer.
/// getNextEvent coalesces completed configurations into a typed resize event;
/// configured records that drawing may begin.
fn configure(data: ?*anyopaque, xdg_surface: ?*c.xdg_surface, serial: u32) callconv(.c) void {
    const native: *Native = @ptrCast(@alignCast(data.?));
    c.xdg_surface_ack_configure(xdg_surface, serial);
    native.configured = c.telar_decoration_acknowledge(&native.decoration);
    if (!native.configured) {
        return;
    }
    native.wake_pending = true;
    native.drawing_surface.?.configure(@intCast(native.width), @intCast(native.height));
    native.host.resize(.{ .width = @intCast(native.width), .height = @intCast(native.height), .scale = 1, .controls = 0 });
}

/// Receives xdg_toplevel.configure through toplevel_listener, installed in init.
/// Despite this function's name, the message can describe initial geometry or
/// a state change as well as a user resize. libwayland dispatches it before the
/// xdg_surface.configure callback that completes the configuration sequence.
///
/// width and height describe window geometry in surface-local coordinates, not
/// necessarily framebuffer pixels. Zero lets the client choose that dimension;
/// we keep the previous value. Positive dimensions replace the stored proposal.
/// These writes only collect native geometry: the GUI and renderer must not
/// consume it as a completed configuration until configure closes the sequence.
///
/// data points to the stable Native. states is a borrowed array of uint32
/// protocol values, such as maximized, fullscreen, resizing and activated.
/// We currently ignore it; translating those states remains pending. The unused
/// toplevel parameter identifies the sender. configure_bounds and wm_capabilities
/// listener entries are null because our shell version 1 predates those events.
fn resize(data: ?*anyopaque, toplevel: ?*c.xdg_toplevel, width: i32, height: i32, states: [*c]c.wl_array) callconv(.c) void {
    _ = toplevel;
    _ = states;
    const native: *Native = @ptrCast(@alignCast(data.?));
    if (width > 0) {
        native.width = width;
    }

    if (height > 0) {
        native.height = height;
    }
}

/// Receives xdg_toplevel.close through toplevel_listener during event dispatch,
/// for example when the user asks the compositor to close this window.
/// Wayland expresses a request: it does not destroy the client-side window.
///
/// Record the request in the stable Native supplied as listener data. Event
/// retrieval returns .close so the GUI loop decides to exit. Destruction belongs
/// to deinit after the
/// caller has finished using the window's resources, not to this callback.
/// toplevel identifies the sender but no protocol response is required here.
fn close(data: ?*anyopaque, toplevel: ?*c.xdg_toplevel) callconv(.c) void {
    _ = toplevel;
    const native: *Native = @ptrCast(@alignCast(data.?));
    native.closed = true;
}
