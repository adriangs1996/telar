//! One native window: its host resources, the clients of the machines it
//! shows and its view state (`WindowModel`).

const pacing = @import("pacing");
const gui_event = @import("gui_event.zig");
const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const host_ports = @import("host_ports.zig");
const data = @import("model");
const native = @import("native/native.zig");
const pane_images = @import("image/pane_images.zig");
const animate = @import("animate");
const window_machines = @import("window_machines.zig");
const clipboard_image = @import("clipboard_image.zig");
const window_input = @import("window_input.zig");
const window_presentation = @import("window_presentation.zig");
const window_effects = @import("window_effects.zig");
const limit_reached = @import("limit_reached.zig");
const input_limits = @import("input/event.zig");

const ConfigurationReload = @import("ConfigurationReload.zig");
const Renderer = @import("render/Renderer.zig");
const Frame = @import("render/Frame.zig");
const Window = @import("telar-window");
const HostServices = @import("host/Services.zig");
const DiagramService = @import("diagrams/Service.zig");
const FontDiscovery = @import("text/FontDiscovery.zig");
const FramePacer = @import("FramePacer.zig");
const PaneImages = @import("image/PaneImages.zig");
const FrameClock = animate.FrameClock;
const PresentationResult = @import("PresentationResult.zig");
const WindowLimit = @import("WindowLimit.zig").WindowLimit;
const LimitedFrame = @import("LimitedFrame.zig");
const CollectedReaches = @import("CollectedReaches.zig");
const ImagePreviews = @import("ImagePreviews.zig");
const WindowModel = @import("WindowModel.zig");
const InputQueue = @import("InputQueue.zig");
const GpuImages = @import("image/GpuImages.zig");
const TabDragStep = @import("TabDragStep.zig").TabDragStep;
const InputLimit = @import("InputLimit.zig").InputLimit;
const workers = @import("workers.zig");
const chrome_port = @import("ports/chrome.zig");
const host_context = @import("widgets/interaction/host_context.zig");
const Registry = @import("widgets/interaction/Registry.zig");
const Scene = @import("render/Scene.zig");
const BandHitMap = @import("widgets/BandHitMap.zig");
const HitMap = @import("widgets/HitMap.zig");
const frame_widget = @import("widgets/frame_widget.zig");
const State = @import("widgets/interaction/State.zig");
const AccessibilityTree = @import("native/AccessibilityTree.zig");
const CellMesh = @import("render/CellMesh.zig");
const ClipboardOwner = @import("host/Owner.zig");
const GlyphAtlas = @import("text/GlyphAtlas.zig");
const keyinput = @import("keyinput");
const hover_target = @import("input/hover_target.zig");
const cellgrid = @import("cellgrid");
const Id = @import("widgets/interaction/Id.zig");
const PasteBuffer = @import("widgets/interaction/PasteBuffer.zig");
const textfield = @import("textfield");
const favicon_worker = @import("image/favicon_worker.zig");
const widget_routing = @import("widgets/interaction/routing.zig");
const tab_drag = @import("widgets/interaction/tab_drag.zig");
const Target = @import("widgets/interaction/Target.zig");
const FieldView = @import("widgets/interaction/FieldView.zig");
const mailbox = @import("mailbox");
const PointerSample = @import("input/PointerSample.zig");
const PointerCapture = @import("input/PointerCapture.zig");
const ScrollSample = @import("input/ScrollSample.zig");
const PasteChunk = @import("PasteChunk.zig");
const TextCommit = @import("input/TextCommit.zig");

const GuiAdapter = @This();

/// Clients one window can hold: the local machine and every saved one.
pub const machine_slots = core.MachineProfiles.capacity + 1;
/// The window's title when no template is configured.
pub const default_title = "Telar";
/// The largest display scale a report names; a larger one reports this.
const max_reported_scale: f32 = 1024;

const PipeEnd = enum(usize) { read, write };

/// Every client this window holds, one per machine, reserved once so no
/// address moves under a job.
clients: *[machine_slots]client.Client,
/// The client of the machine this window presents.
app: *client.Client,
/// The machines this window holds, one row per client slot.
machines: client.Machines = .{},
/// A machine chosen while a frame was in flight, shown when it completes.
pending_machine: ?u8 = null,
pending_activity: ?client.Intent = null,
// SAFETY: projection fills each live-machine source before returning the bounded activity_sources slice.
activity_sources: [client.Machines.capacity]client.MachineActivity = undefined,
/// Where `machines.json` lives, empty when it cannot be resolved, and the
/// fingerprint the window last applied.
// SAFETY: window_machines resolves the profile path into this buffer before setting profiles_path_len; readers skip a zero length.
profiles_path: [std.fs.max_path_bytes]u8 = undefined,
profiles_path_len: usize = 0,
profiles_seen: u64 = 0,
wake_fds: [2]c_int,
inbox: gui_event.Inbox,
configuration: ConfigurationReload,
frame_pacer: FramePacer = .{},
renderer: Renderer,
/// Stable storage for widget borrows between composition and synchronous draw.
frame: Frame = .{},
/// The frame that stopped at a limit; it is not drawn again.
limited: ?LimitedFrame = null,
/// Window-thread delivery awaits update; focus awaits inbox capacity.
unposted: Unposted = .{},
/// The window's own limits it is at now; each reports when entered.
reached: std.EnumSet(WindowLimit) = .{},
/// Limit reaches waiting for update to report them.
collected: CollectedReaches = .{},
exit_status: ?u8 = null,
started: bool = false,
needs_draw: bool = false,
viewport: ?Window.Viewport = null,
frame_wait_ms: u32 = 0,
pending_host_request: ?native.HostRequest = null,
window_title: client.WindowTitleState = .{},
binding_timeout: pacing.DeadlineScheduler = .{},
stopped: bool = false,
host: HostServices = .{},
/// The images each machine's runtime sent, one store per client slot:
/// every runtime numbers its panes from the same start.
graphics_stores: [machine_slots]client.retained_graphics.Store,
/// The textures and resolved placements of the presented machine's images.
images: PaneImages,
diagrams: DiagramService,
/// Installed-font lookups for graphemes the renderer's faces lack.
font_discovery: FontDiscovery,
/// The window client's clipboard image previews, bound as its attachment shelf.
previews: ImagePreviews,
/// The preview revision the chrome was last prepared at.
previews_prepared: u64 = 0,
/// The window's view state.
model: WindowModel,
window: Window,

/// Adopts options on success and binds all ports before receiving messages.
/// Example: `const gui = try GuiAdapter.init(params);`
pub fn init(params: client.ClientInit) !*GuiAdapter {
    const gui = try params.gpa.create(GuiAdapter);
    errdefer params.gpa.destroy(gui);

    gui.clients = try params.gpa.create([machine_slots]client.Client);
    errdefer params.gpa.destroy(gui.clients);
    gui.app = &gui.clients[client.Machines.local_slot];
    gui.machines = .{};
    gui.pending_machine = null;
    gui.pending_activity = null;
    gui.profiles_path_len = 0;
    gui.profiles_seen = 0;

    if (native.telar_gui_pipe(&gui.wake_fds) != 0) {
        return error.WakePipeFailed;
    }
    errdefer native.telar_gui_close_pipe(&gui.wake_fds);

    gui.window = try Window.init(
        .{
            .title = default_title,
            .wake_fd = gui.wake_fds[@intFromEnum(PipeEnd.read)],
        },
    );

    gui.inbox = .init(
        params.io,
        .{
            .context = @intCast(gui.wake_fds[@intFromEnum(PipeEnd.write)]),
            .notify_fn = notifyWake,
        },
    );

    errdefer gui.inbox.deinit();
    gui.configuration = .{ .io = params.io, .inbox = &gui.inbox };
    errdefer gui.configuration.deinit();
    gui.frame_pacer = .{};
    // The renderer starts from the configuration and theme the window
    // launched with; a reload replaces them later.
    gui.renderer = try Renderer.configured(
        params.gpa,
        params.io,
        .{
            .config = params.options.gui,
            .theme = params.options.theme.terminal,
        },
    );
    errdefer gui.renderer.deinit();
    gui.exit_status = null;
    gui.started = false;
    gui.needs_draw = false;
    gui.viewport = null;
    gui.frame_wait_ms = 0;
    gui.pending_host_request = null;
    gui.window_title = .{};
    try gui.model.init(params.gpa, params.options);
    errdefer gui.model.deinit(params.gpa);
    try client.Client.init(gui.app, params);
    gui.machines.live[client.Machines.local_slot] = true;
    gui.previews = .init(params.gpa);
    gui.previews_prepared = 0;
    gui.app.model.host.clipboard_capture = true;

    gui.binding_timeout = .{};
    gui.stopped = false;
    try gui.host.init(params.gpa);
    errdefer gui.host.deinit(params.gpa);
    gui.limited = null;
    gui.unposted = .{};
    gui.reached = .{};
    gui.collected = .{};

    for (&gui.graphics_stores) |*store| {
        store.* = .init(params.gpa);
    }

    gui.images = .{};

    gui.diagrams = .init(params.gpa);
    gui.font_discovery = .init(params.gpa);

    gui.app.machines = &gui.machines;
    gui.app.graphics = gui.graphicsRetention(client.Machines.local_slot);
    gui.app.chrome = gui.chromePort();
    gui.app.attachments = gui.previews.port();

    return gui;
}

pub fn deinit(self: *GuiAdapter) void {
    const gpa = self.app.gpa;
    self.model.deinit(gpa);
    self.host.deinit(gpa);
    self.inbox.close();
    self.configuration.deinit();
    self.inbox.deinit();
    native.telar_gui_close_pipe(&self.wake_fds);
    self.renderer.deinit();

    if (self.app.presentation.active) |flight| {
        _ = self.app.presentation.complete(flight.token, .cancelled);
    }

    pane_images.abandon(&self.images, &self.graphics_stores);
    for (&self.graphics_stores) |*store| {
        store.deinit();
    }

    self.diagrams.deinit();
    self.font_discovery.deinit();
    self.previews.deinit();
    for (self.machines.live, 0..) |live, slot| {
        if (live and slot != client.Machines.local_slot) {
            self.clients[slot].deinit();
        }
    }

    self.window.deinit();
    self.localClient().deinit();
    gpa.destroy(self.clients);
    gpa.destroy(self);
}

pub fn loop(self: *GuiAdapter) !u8 {
    const surface = self.window.surface();

    while (self.exit_status == null) {
        const event = try self.window.getNextEvent();
        switch (event) {
            .close => break,
            .input => |input_event| {
                core.mark(self.app.io, .client_input);

                if (input_event == .focus) {
                    if (self.unposted.focus != null) {
                        self.unposted.focus = input_event.focus;
                    } else {
                        self.inbox.post(.{ .focus = input_event.focus }) catch |err| {
                            if (err != error.InboxFull) {
                                return err;
                            }
                        };

                        self.unposted.focus = input_event.focus;
                        self.inbox.wakeup.notify();
                    }
                } else {
                    const admission = self.model.input_queue.accept(input_event, .{
                        .geometry_revision = self.model.pointer.revision,
                        .gesture_revision = self.model.pointer.gesture_revision,
                    }) catch |err| {
                        const large = switch (input_event) {
                            .text => |text| text.target_id == 0,
                            .paste, .clipboard => true,
                            else => false,
                        };

                        const limit = switch (err) {
                            error.NativeInputFull => InputQueue.queue_limit,
                            error.InputPoolFull => if (large) InputQueue.large_slots_limit else InputQueue.small_slots_limit,
                            error.InputTooLarge => if (large) input_limits.clipboard_limit else InputQueue.small_limit,
                            else => null,
                        };

                        self.collectLimitReachedAndNotify(try classifyWindowInputError(err, limit));
                        return err;
                    };

                    if (admission == .recovery) {
                        self.model.pointer.invalidateGestures();
                    }

                    self.inbox.notify(.input_ready) catch |err| {
                        if (err != error.InboxFull) {
                            return err;
                        }
                    };
                }
            },
            .resize => |size| {
                // A NaN scale is not past the bound; measuring refuses it.
                if (!(size.scale > Renderer.max_display_scale)) {
                    self.reached.remove(.display_scale);
                    self.viewport = size;
                } else {
                    if (!self.reached.contains(.display_scale)) {
                        self.reached.insert(.display_scale);
                        self.collectLimitReachedAndNotify(.{
                            .limit = Renderer.display_scale_limit,
                            .requested = @intFromFloat(@ceil(@min(size.scale, max_reported_scale))),
                        });
                    }

                    var bounded = size;
                    bounded.scale = Renderer.max_display_scale;
                    self.viewport = bounded;
                }
            },
            .display_interval => |interval| {
                self.frame_pacer.display_interval_ns = interval;
            },
            .wake => {},
        }

        if (try self.renderer.takeCompletion(surface)) |result| {
            self.unposted.presented = result;
        }

        while (surface.takeImageCompletion()) |result| {
            const elapsed = ret: {
                const row = GpuImages.rowOf(result.handle) orelse break :ret null;
                if (self.images.gpu.residency[row] != .uploading) {
                    break :ret null;
                }

                const store = &self.graphics_stores[self.images.gpu.machine[row]];
                const lease = self.images.gpu.lease[row];

                if (store.images.getPtr(lease.identity)) |image| {
                    std.debug.assert(image.delivery.leases != 0);
                    image.delivery.leases -= 1;
                    store.collectRetired(lease.identity.pane_id, lease.identity.image_id);
                }

                const now_ns = pacing.clock.monotonic(self.app.io);
                self.images.gpu.uploading -= 1;
                self.images.revision +%= 1;
                if (result.success) {
                    self.images.gpu.residency[row] = .ready;
                    self.images.gpu.used_ns[row] = now_ns;
                    break :ret now_ns -| self.images.gpu.started_ns[row];
                }

                self.images.gpu.residency[row] = .failed;
                self.images.gpu.resident_bytes -= self.images.gpu.bytes[row];
                self.images.gpu.bytes[row] = 0;
                break :ret null;
            };

            if (comptime core.enabled) {
                if (elapsed) |value| {
                    self.app.telemetry.metrics.graphics_textures += 1;
                    self.app.telemetry.metrics.graphics_upload.observe(value);
                }
            }
        }

        core.profiling.add(.gui_update, 1);
        if (self.unposted.presented) |result| {
            self.unposted.presented = null;
            blk: {
                core.profiling.add(.gui_complete, 1);
                const active = if (self.app.presentation.active) |*flight| flight else break :blk;
                if (result.token == 0 or result.token != @intFromEnum(active.token)) {
                    break :blk;
                }

                self.model.chrome.present(result.delivered);
                self.model.overlays.present(result.delivered);
                self.model.widgets.present(result.delivered);
                self.model.pointer.hover.present(result.delivered);

                const delivery = self.app.presentation.complete(@enumFromInt(result.token), if (result.delivered) .delivered else .failed) orelse break :blk;

                if (result.delivered) {
                    self.app.telemetry.metrics.presentations += 1;
                }

                try client.presentation_delivery.apply(&self.app.model, delivery.commit);
                try self.settleActivity();

                if (self.pending_machine) |slot| {
                    self.pending_machine = null;
                    try self.select(slot);
                }
            }
        }

        if (self.unposted.capture) |completion| {
            self.unposted.capture = null;
            client.clipboard_capture.completeClipboardCapture(&self.clients[client.Machines.local_slot], completion) catch |err| try self.absorbUpdate(err);
        }

        blk: {
            if (self.unposted.focus) |focused| {
                self.inbox.post(.{
                    .focus = focused,
                }) catch break :blk;

                self.unposted.focus = null;
            }
        }

        update: {
            if (self.viewport) |viewport| {
                if (!self.started and self.app.presentation.active == null) {
                    self.resizeViewport(viewport) catch |err| switch (err) {
                        error.InvalidTerminalSize => break :update,
                        else => return err,
                    };

                    try self.start(.{
                        .foreground = self.renderer.theme.foreground,
                        .background = self.renderer.theme.background,
                        .palette = self.renderer.theme.palette,
                    });
                }
            }

            const status: ?u8 = turn: {
                var batch = try self.inbox.begin();
                defer self.inbox.end();

                while (try self.inbox.next(&batch)) |message| {
                    const path = core.enter(pathFor(message));
                    defer path.restore();

                    const exit_status = self.dispatch(message) catch |err| skipped: {
                        try self.absorbUpdate(err);
                        break :skipped null;
                    };

                    self.deliverHostEffects() catch |err| try self.absorbUpdate(err);
                    if (exit_status) |value| {
                        break :turn value;
                    }
                }

                if (batch.processed != 0) {
                    client.client_layout.synchronizeClientLayout(&self.app.model) catch |err| try self.absorbUpdate(err);
                }

                self.configuration.poll(&self.clients[client.Machines.local_slot]) catch |err| try self.absorbUpdate(err);
                self.paceFrames() catch |err| try self.absorbUpdate(err);
                self.deliverHostEffects() catch |err| try self.absorbUpdate(err);

                break :turn null;
            };

            try self.resumeInput();
            self.refreshPointer();
            self.exit_status = status;

            const now_ns = pacing.clock.monotonic(self.app.io);
            if (self.model.observed_input_revision != self.model.input_revision) {
                self.model.observed_input_revision = self.model.input_revision;
                self.model.cursor_clock.focused = self.model.focused;
                self.model.cursor_clock.reset(now_ns);
            }

            self.model.cursor_clock.observe(window_presentation.cursorTarget(self.app), now_ns);
            _ = self.app.presentation.observe(self.observation());
            self.needs_draw = false;

            if (self.app.presentation.active == null) {
                const animation_due = self.model.chrome.animation.requestPreparation(now_ns);
                self.needs_draw = (self.app.presentation.needsPreparation() and !self.holds()) or animation_due or
                    self.configuration.pending or
                    self.renderer.cursor_on != self.model.cursor_clock.shown(now_ns) or
                    self.renderer.focused != self.model.cursor_clock.focused or
                    self.renderer.atlasSettleDue(now_ns) or
                    (if (self.viewport) |size| self.viewportPending(size) else false) or
                    pane_images.trimDue(&self.images, now_ns);
            }

            if (status) |value| {
                return value;
            }

            if (self.needs_draw) {
                settle: {
                    if (self.app.presentation.active != null) {
                        break :settle;
                    }

                    const viewport = self.viewport orelse break :settle;
                    self.configuration.observe(self.renderer.config, viewport);

                    if (try self.configuration.apply(self, &self.renderer)) {
                        self.model.cursor_clock.config = self.renderer.config.cursor;
                        self.model.cursor_clock.reset(pacing.clock.monotonic(self.app.io));
                        self.limited = null;
                        try self.paceFrames();
                    }

                    if (self.limited) |limited| {
                        if (std.meta.eql(limited.viewport, viewport) and self.holds()) {
                            break :settle;
                        }
                    }

                    self.resizeViewport(viewport) catch |err| switch (err) {
                        error.InvalidTerminalSize => break :settle,
                        else => return err,
                    };

                    const page = if (self.renderer.sprites) |*sprites| sprites else break :settle;
                    const favicons = &self.model.chrome.favicons;
                    const workspaces = &self.app.model.workspace_list_snapshot;
                    if (favicons.refresh(self.app.gpa, page, workspaces)) |reach| {
                        client.limit_reached.report(self.app, reach);
                    }

                    const want = favicons.next(page, workspaces) orelse break :settle;
                    const job = client.favicons.request(
                        &self.app.model,
                        .{
                            .workspace = want.workspace,
                            .cwd = want.cwd,
                            .cells = page.cells,
                        },
                    ) orelse break :settle;

                    self.inbox.start(.favicon, .{ favicon_worker.execute, .{ self.app.io, self.app.gpa, job } }) catch |err| {
                        client.favicons.cancel(&self.app.model);
                        return err;
                    };
                    favicons.started(want.workspace);
                }

                try self.deliverHostEffects();
            }
        }

        if (try self.prepareNextFrame()) |frame| {
            try self.window.setAppearance(.{
                .opacity = frame.background[3],
                .blur = @intCast(frame.background_blur),
                .titlebar = frame.titlebar != 0,
                .navigation = frame.navigation,
            });

            if (self.renderer.draw(surface, frame)) |accepted| {
                if (accepted) {
                    self.drawn(frame);
                    self.images.upload_count = 0;
                    self.images.release_count = 0;
                } else {
                    self.unposted.presented = .{
                        .token = frame.token,
                        .delivered = false,
                    };
                    self.inbox.wakeup.notify();
                }
            } else |err| {
                self.unposted.presented = .{
                    .token = frame.token,
                    .delivered = false,
                };
                self.inbox.wakeup.notify();

                if (!core.limit_reached.isLimitError(err)) {
                    return err;
                }

                if (!self.absorb(.window_draw, err)) {
                    return err;
                }

                const name = if (limit_reached.limitOf(err)) |limit| limit.name else @errorName(err);
                self.limited = LimitedFrame.init(
                    self.observation(),
                    self.viewport.?,
                    name,
                );
            }
        }

        self.poll(&self.window);
        try self.publishWindow(&self.window);
        try self.window.wakeAfter(FrameClock.earliest(self.wakeupAfter(), self.frame_wait_ms));
    }
    return self.exit_status orelse 0;
}

fn absorbUpdate(self: *GuiAdapter, err: anyerror) !void {
    if (!self.absorb(.window_update, err)) {
        return err;
    }
}

fn start(self: *GuiAdapter, colors: core.TerminalColors) !void {
    var capabilities = self.app.model.host.host_capabilities;

    capabilities.terminal_colors = colors;
    capabilities.images = .supported;
    capabilities.pointer_pixels = .supported;
    capabilities.frame_interval_ns = self.frame_pacer.pace(self.renderer.config.max_fps, &self.model.chrome.animation);

    _ = try client.host_resize.applyHostUpdate(
        self.app,
        .{
            .size = self.app.model.host.host_size,
            .capabilities = capabilities,
        },
    );

    self.app.model.startup.phase = .opening;
    self.app.bootstrap = .{
        .graphics_shared = client.supportsSharedMemory(),
        .client_identity = self.app.client_identity,
        .terminal_colors = colors,
    };

    if (self.app.runtime_transport.connection == null) {
        try client.runtime_link.start(self.app);
    } else {
        try self.app.model.to_runtime.pushBootstrap(self.app.bootstrap.?, self.app.model.host.host_capabilities.frame_interval_ns);
        try client.runtime_io.startRuntimeIo(self.app);
    }

    try client.config_adoption.scheduleConfigReload(self.app);
    try client.bar_updates.synchronizeBars(self.app);
    try self.open();
    self.started = true;
}

fn dispatch(self: *GuiAdapter, message: gui_event.Message) !?u8 {
    core.profiling.add(.gui_dispatch, 1);
    switch (message) {
        .machine => |machine_event| {
            if (try self.dispatchMachine(machine_event.slot, machine_event.message)) |status| {
                return status;
            }
        },
        .profiles_changed => |fingerprint| try self.profilesChanged(fingerprint),
        .input_ready => try self.inputReady(),
        .focus => |focused| try self.focus(focused),

        .configuration_ready => try self.configuration.accept(self.localClient()),
        .binding_timeout => |result| try self.expireBinding(result),
        .favicon => |result| landFavicon(&self.model, self.app, result),
        .diagram_ready => {
            self.diagrams.notify();
            self.model.chrome.invalidate();
        },
        .font_discovered => self.fontDiscovered(),

        .clipboard_image => |completion| try self.finish(completion),
    }

    return if (self.stopped) @as(u8, 0) else null;
}

fn dispatchMachine(self: *GuiAdapter, slot: u8, message: client.Message) !?u8 {
    if (try self.handle(slot, message)) |status| {
        return status;
    }

    if (slot == self.machines.active and message == .server) {
        try self.resumeAfterRuntime();
    }

    return null;
}

fn pathFor(message: gui_event.Message) core.Path {
    return switch (message) {
        .machine => |event_value| event_value.message.path(),
        .configuration_ready,
        .profiles_changed,
        .favicon,
        .diagram_ready,
        .font_discovered,
        => .observation,
        else => .interactive,
    };
}

fn resumeAfterRuntime(self: *GuiAdapter) !void {
    client.client_startup.finish(&self.app.model);
    try self.resumeInput();
    self.refreshPointer();
}

fn landFavicon(model: *WindowModel, app: *client.Client, completion: client.FaviconCompletion) void {
    const image: ?*client.FaviconImage = switch (client.favicons.complete(app, completion)) {
        .stale => return,
        .missing => null,
        .image => |owned| owned,
    };

    model.chrome.favicons.land(
        app.gpa,
        .{
            .workspace = completion.workspace,
            .image = image,
        },
    );
    model.chrome.invalidate();
}

fn deliverHostEffects(self: *GuiAdapter) !void {
    const collected = &self.collected;
    for (collected.reach[0..collected.count], collected.hits[0..collected.count]) |reach, hits| {
        client.limit_reached.reportCollected(self.app, reach, hits);
    }

    if (collected.dropped != 0) {
        std.log.scoped(.limits).warn("{d} more window limit reaches were not reported", .{collected.dropped});
    }

    collected.clear();

    if (self.limited) |*frame| {
        if (!frame.noticed) {
            frame.observation = self.observation();
            frame.noticed = true;
        }
    }

    const own = &self.clients[client.Machines.local_slot];
    while (true) {
        const effects = &self.app.model.to_host;
        _ = effects.takePlacementInvalidation();
        if (effects.rebind_input) {
            effects.rebind_input = false;

            var replacement = client.key_router.build(self.app.routerConfig()) catch unreachable;
            replacement.inheritPhysicalLeases(&self.model.router);
            self.model.router = replacement;
            self.model.binding_revision +%= 1;
            _ = self.binding_timeout.update(self.app.io, null);
        }

        if (effects.resume_input) {
            effects.resume_input = false;

            const holds_startup_input = self.app.model.runtime_link.phase == .connected and self.app.model.startup.holdsInput();
            if (self.model.input_queue.len != 0 and !holds_startup_input and self.app.model.to_runtime.availableCapacity() >= @intFromEnum(InputLimit.minimum_outbox_slots)) {
                self.inbox.notify(.input_ready) catch |err| {
                    if (err != error.InboxFull) {
                        return err;
                    }
                };
            }
        }

        if (effects.pane_input) |pane_input| {
            effects.pane_input = null;

            const model = &self.app.model;
            if (model.tabs.activeSlot()) |tab| {
                if (model.panes.findInConst(model.tabs.location[tab].tab_id, pane_input.pane_id)) |pane| {
                    self.frame_pacer.noteInput(.{
                        .pane_id = pane.id,
                        .attachment_generation = pane.attachment_generation,
                        .frame_id = pane.applied_frame_id,
                        .attached = pane.attached,
                    }, pane_input.at_ns);
                }
            }
        }

        while (effects.pop()) |effect| {
            switch (effect) {
                .clipboard => {
                    const bytes = effects.clipboard.items;
                    const superseded = self.host.superseded;
                    if (self.host.write(bytes)) |_| {
                        // A copy that replaced an older one waiting in a full
                        // queue is reported; the clipboard keeps the newest.
                        if (self.host.superseded != superseded) {
                            client.limit_reached.report(
                                self.app,
                                .{
                                    .limit = HostServices.limit,
                                    .requested = HostServices.capacity + 1,
                                },
                            );
                        }

                        self.inbox.wakeup.notify();
                    } else |err| {
                        switch (err) {
                            // The old clipboard stays and nothing is cut.
                            error.ClipboardTooLarge => {
                                client.limit_reached.report(
                                    self.app,
                                    .{
                                        .limit = input_limits.clipboard_limit,
                                        .requested = bytes.len,
                                    },
                                );
                                std.log.warn("native clipboard update was not admitted: {s}", .{@errorName(err)});
                            },
                            error.HostRequestsFull => {
                                client.limit_reached.report(
                                    self.app,
                                    .{
                                        .limit = HostServices.limit,
                                        .requested = HostServices.capacity + 1,
                                    },
                                );
                                std.log.warn("native clipboard update was not admitted: {s}", .{@errorName(err)});
                            },
                            error.InvalidUtf8 => std.log.warn("native clipboard update was not admitted: {s}", .{@errorName(err)}),
                            else => return err,
                        }
                    }
                },
                .capture => |request| capture: {
                    if (self.app != own) {
                        try client.clipboard_capture.completeClipboardCapture(
                            self.app,
                            .{
                                .execution_id = @enumFromInt(request.sequence),
                                .result = error.NativeServiceUnavailable,
                            },
                        );
                        break :capture;
                    }

                    const replaced = self.previews.queued;
                    self.previews.queued = request;
                    if (replaced) |value| {
                        client.clipboard_capture.completeClipboardCapture(
                            own,
                            .{
                                .execution_id = @enumFromInt(value.sequence),
                                .result = error.Canceled,
                            },
                        ) catch |err| {
                            try client.clipboard_capture.completeClipboardCapture(
                                self.app,
                                .{
                                    .execution_id = @enumFromInt(request.sequence),
                                    .result = err,
                                },
                            );
                            break :capture;
                        };
                    }

                    self.inbox.wakeup.notify();
                },
                .machine => |request| {
                    self.pending_activity = null;
                    self.pending_machine = null;
                    switch (request) {
                        .slot => |slot| {
                            // Choosing an unreachable machine also tries it again now.
                            if (self.machines.live[slot]) {
                                try client.runtime_link.retryNow(&self.clients[slot]);
                            }

                            try self.select(slot);
                        },
                        .offset => |offset| {
                            var slot = self.machines.active;
                            for (0..client.Machines.capacity) |_| {
                                slot = @intCast(@mod(@as(i16, slot) + offset, client.Machines.capacity));
                                if (self.machines.shown(slot) and self.machines.live[slot]) {
                                    try self.select(slot);
                                    break;
                                }
                            }
                        },
                        .unpin => |slot| self.machines.pinned[slot] = false,
                        .setup => |slot| setup: {
                            if (slot == client.Machines.local_slot or !self.machines.used[slot]) {
                                break :setup;
                            }

                            var executable_buffer: [std.fs.max_path_bytes]u8 = undefined;
                            const executable = executable_buffer[0..try std.process.executablePath(own.io, &executable_buffer)];
                            var title_buffer: [core.max_tab_label_bytes]u8 = undefined;
                            const title = std.fmt.bufPrint(&title_buffer, "Set up {s}", .{self.machines.label(slot)}) catch "Set up telar";

                            const name = if (self.machines.id[slot] == .invalid) self.machines.destination(slot) else self.machines.label(slot);
                            try self.select(client.Machines.local_slot);
                            _ = try client.tab_creation.requestTabCreation(
                                own,
                                .{
                                    .label = title,
                                    .arguments = &.{ executable, "machine", "setup", name, "--confirm" },
                                },
                            );
                        },
                    }
                },
            }
        }

        for (self.machines.live, 0..) |live, index| {
            if (!live) {
                continue;
            }

            const slot: u8 = @intCast(index);
            const app = &self.clients[slot];
            try app.flush();
            while (true) {
                if (app.to_workers.pop()) |job| {
                    self.inbox.start(.machine, .{ workers.run, .{ app.io, slot, job } }) catch |err| {
                        try app.failJob(job, err);
                        try app.flush();
                    };
                } else if (app.to_background.pop()) |job| {
                    const started: anyerror!void = started: {
                        if (slot == client.Machines.local_slot and job == .config_watch) {
                            break :started self.configuration.schedule(job.config_watch);
                        }

                        break :started self.inbox.start(.machine, .{ workers.runBackground, .{ app.io, app.gpa, slot, job } });
                    };
                    started catch |err| {
                        try app.failBackgroundJob(job, err);
                        try app.flush();
                    };
                } else {
                    break;
                }
            }
        }

        if (self.app.model.to_host.count == 0) {
            return;
        }
    }
}

/// Runs after queue admission, before the existing terminal fallback.
/// Targeted stale events are consumed, never retargeted to another editor.
/// Example: `if (try routing.apply(gui, event)) return;`
fn apply(self: *GuiAdapter, event: Window.Input) !bool {
    const state = &self.model.widgets;

    if (try self.continueFallback(event)) {
        return true;
    }

    if (event.isScrollOrPointerBegin() and !window_input.pointerGeometryMatches(self.app)) {
        if (event.isPointerPress()) {
            state.dispatcher.discardPointer(event.pointer.button);
        }

        return true;
    }

    if (event.isFocusNotFocused()) {
        state.cancelComposition();
    }

    if (event.isWriteClipboardContent()) {
        const result = event.clipboard;
        cut: {
            const id: Id = .{ .target_id = result.target_id, .generation = result.generation };
            for (&self.model.widgets.pending_cuts) |*slot| {
                const cut = slot.* orelse continue;
                if (cut.request_id != result.request_id or !cut.owner.eql(id)) {
                    continue;
                }

                slot.* = null;
                const focused = self.model.widgets.dispatcher.focused orelse break :cut;
                if (!focused.eql(id)) {
                    break :cut;
                }

                const target = self.model.widgets.dispatcher.maps.presented().find(id) orelse break :cut;
                if (result.status != .success or cut.revision != FieldView.revision(self.app)) {
                    break :cut;
                }
                if (widget_routing.field(self.app, target) == null or !widget_routing.eligible(self.app, target)) {
                    break :cut;
                }

                try widget_routing.focus(&self.model, self.app, target);
                try widget_routing.command(&self.model, self.app, .{ .replace_range = .{
                    .range = cut.range,
                    .text = "",
                } });
                break :cut;
            }
        }

        return true;
    }

    if (event.isClipboard()) {
        try self.finishWidgetPaste(event.clipboard);
        return true;
    }

    if (event.isAccessibility()) {
        try self.accessibility(event.accessibility);
        return true;
    }

    const leased = event == .key or (event == .text and event.text.physical != null);
    const ownership = if (leased) state.dispatcher.route(event) else null;
    const result = ownership orelse state.dispatcher.route(event);

    if (widget_routing.explicitTarget(event)) |id| {
        if (ownership) |decision| {
            if (!decision.consumed) {
                return false;
            }

            if (decision.target == null or !decision.target.?.id.eql(id)) {
                return true;
            }
        }

        const target = state.dispatcher.maps.presented().find(id) orelse return true;
        const focused = state.dispatcher.focused orelse return true;
        if (!focused.eql(id) or widget_routing.field(self.app, target) == null) {
            return true;
        }

        try self.editor(target, event);
        return true;
    }

    if (event == .pointer and result.consumed) {
        const capture = state.dispatcher.captures[0];
        const captured = if (capture) |id| state.dispatcher.maps.presented().find(id) else null;
        self.model.chrome.widgetPointer(event.pointer, captured != null and captured.?.action == .resize_sidebar);
        self.model.pointer.hover.observe(event.pointer);
        self.model.pointer.hover.refresh(self);
    }
    if (result.focus_changed) {
        state.cancelComposition();
        if (state.dispatcher.focusedTarget()) |target| {
            try widget_routing.focus(&self.model, self.app, target);
        }
    }

    if (event == .scroll or (event == .pointer and (event.pointer.kind == .scroll_up or event.pointer.kind == .scroll_down))) {
        if (try widget_routing.scroll(&self.model, self.app, event)) {
            return true;
        }
    }

    if (try tab_drag.apply(&self.model, self.app, event, result.target)) {
        return true;
    }

    const target = result.target orelse return result.consumed;
    if (!widget_routing.eligible(self.app, target)) {
        return true;
    }

    switch (target.action) {
        .text_field => try self.editor(target, event),
        .intent => |intent| {
            if (widget_routing.activated(event)) {
                var value = intent;
                if (event == .pointer and event.pointer.button != .left) {
                    value = if (event.pointer.button == .right) client.secondaryIntent(intent) else .none;
                }

                try self.dispatchIntent(value);
            }
        },
        .complete_path => {
            if (target.enabled) {
                try widget_routing.scrollDirectory(&self.model, self.app, target, event);
                if (widget_routing.buttonActivated(event, target)) {
                    try self.activateControl(target);
                }
            }
        },
        .prompt, .history => {
            if (target.enabled and widget_routing.buttonActivated(event, target)) {
                try self.activateControl(target);
            }
        },
        .resize_sidebar => {
            if (event == .pointer and event.pointer.button == .left and (event.pointer.kind == .drag or event.pointer.kind == .release)) {
                window_presentation.adoptSidebarWidth(&self.model, @intFromFloat(@max(1, @min(65535, @floor(event.pointer.x) + 1))));
            }
        },
        .preview => |action| {
            if (widget_routing.buttonActivated(event, target)) {
                self.showPreview(action);
            }
        },
        .custom => {},
    }

    return result.consumed;
}

fn activateControl(self: *GuiAdapter, target: Target) !void {
    self.model.widgets.cancelComposition();
    switch (target.action) {
        .prompt => |action| try widget_routing.command(&self.model, self.app, if (action == .submit) .submit else .cancel),
        .complete_path => |choice| try client.name_prompt.chooseDirectory(self.app, choice.index, choice.revision),
        .history => |action| {
            const prompt = self.app.model.name_prompt.currentConst() orelse return;
            if (prompt.target() != .history) {
                return;
            }

            switch (action) {
                .select => |choice| try client.history_palette.selectHistoryRow(self.app, choice.index, choice.revision),
                .submit, .submit_alternate => |choice| {
                    const history = &self.app.model.history_palette;
                    if (history.phase == .ready and history.version() == choice.revision and prompt.selection() == choice.index) {
                        try widget_routing.command(&self.model, self.app, if (action == .submit) .submit else .submit_alternate);
                    }
                },
                .cycle_scope => try widget_routing.command(&self.model, self.app, .tab),
                .select_scope => |scope| try widget_routing.command(&self.model, self.app, .{ .select_scope = scope }),
                .select_author => |author| try widget_routing.command(&self.model, self.app, .{ .select_author = author }),
                .toggle_failed => try widget_routing.command(&self.model, self.app, .toggle_failed),
                .toggle_inspection => try widget_routing.command(&self.model, self.app, .toggle_inspection),
                .page_older => try widget_routing.command(&self.model, self.app, .page_up),
                .copy => try widget_routing.command(&self.model, self.app, .copy_entry),
                .remove => try widget_routing.command(&self.model, self.app, .remove_entry),
                .visit_pane => try widget_routing.command(&self.model, self.app, .visit_pane),
            }
        },
        .intent => |intent| try self.dispatchIntent(intent),
        .preview => |action| self.showPreview(action),
        else => {},
    }
}

fn dispatchIntent(self: *GuiAdapter, intent: client.Intent) !void {
    try self.applyViewInteraction(.{
        .intent = intent,
        .consumed = true,
    });
    _ = self.model.widgets.dispatcher.focus(null);
}

fn accessibility(self: *GuiAdapter, value: widget_routing.AccessibilityAction) !void {
    const target = self.model.widgets.dispatcher.maps.presented().find(.{ .target_id = value.target_id, .generation = value.generation }) orelse return;
    if (!target.enabled or target.layer < self.model.widgets.dispatcher.maps.presented().modal_layer or !widget_routing.eligible(self.app, target)) {
        return;
    }

    if (value.revision != 0 and value.revision != FieldView.revision(self.app)) {
        return;
    }

    switch (value.action) {
        .focus => {
            _ = self.model.widgets.dispatcher.focus(target.id);
            try widget_routing.focus(&self.model, self.app, target);
        },
        .press => if (target.activatable()) {
            try self.activateControl(target);
        },
        .set_value, .set_selection => {
            const current = widget_routing.field(self.app, target) orelse return;
            _ = self.model.widgets.dispatcher.focus(target.id);
            try widget_routing.focus(&self.model, self.app, target);
            if (value.action == .set_value) {
                try widget_routing.command(&self.model, self.app, .{ .replace_range = .{ .range = .{ 0, @intCast(current.text.len) }, .text = value.text } });
            } else {
                try widget_routing.command(&self.model, self.app, .{ .select_range = .{ value.selection_start, value.selection_end } });
            }
        },
        .replace_range => {
            const current = widget_routing.field(self.app, target) orelse return;
            const range: [2]u32 = .{ value.replacement_start, value.replacement_end };
            if (value.revision != FieldView.revision(self.app) or range[0] > range[1] or !current.validRange(range)) {
                return;
            }

            _ = self.model.widgets.dispatcher.focus(target.id);
            try widget_routing.focus(&self.model, self.app, target);
            try widget_routing.command(&self.model, self.app, .{ .replace_range = .{ .range = range, .text = value.text } });
        },
        .increment, .decrement => {},
        .copy, .cut, .paste => {
            const current = widget_routing.field(self.app, target) orelse return;
            if (value.selection_start > value.selection_end or !current.validRange(.{ value.selection_start, value.selection_end })) {
                return;
            }

            _ = self.model.widgets.dispatcher.focus(target.id);
            try widget_routing.focus(&self.model, self.app, target);

            if (value.action == .paste) {
                try widget_routing.command(&self.model, self.app, .{ .select_range = .{ value.selection_start, value.selection_end } });
                self.requestClipboardRead(target.id.target_id, target.id.generation) catch return;
            } else if (value.action == .cut) {
                try self.beginCut(target, .{ value.selection_start, value.selection_end });
            } else {
                self.requestClipboardWrite(current.text[value.selection_start..value.selection_end]) catch return;
            }
        },
    }
}

/// Consumes bounded native input and schedules another turn if it can advance.
fn inputReady(self: *GuiAdapter) !void {
    if (self.model.input_queue.len != 0) {
        self.model.input_revision +%= 1;
        try self.drainInput();
        try self.resumeInput();
    }
}

/// Stops before the shared outbox fills, resuming on transport completion.
fn drainInput(self: *GuiAdapter) !void {
    core.profiling.add(.gui_input_drain, 1);
    const app = self.app;
    const pending_input = &self.model.input_queue;

    if (window_input.holdsStartupInput(self.app)) {
        return;
    }

    var budget = mailbox.DrainBudget.begin(app.io, pending_input.len + pending_input.recovery.len);
    const pending = self.model.router.prefixPending();

    while (!self.stopped and pending_input.len != 0 and app.model.to_runtime.availableCapacity() >= @intFromEnum(InputLimit.minimum_outbox_slots) and budget.take(app.io)) {
        const overflows = self.model.router.leaseOverflowCount();

        switch (pending_input.front().?.*) {
            .key => |key| try self.dispatchKey(key),
            .text => |*text| try self.dispatchText(text),
            .text_block => |*held| {
                const text = pending_input.large_events.view(held.slot).text;
                const bytes = text.bytes;
                const len = std.unicode.utf8ByteSequenceLength(bytes[held.offset]) catch 1;
                // A held text has many scalars, so no physical key: each
                // keeps the text's phase.
                var scalar: TextCommit = .{
                    .bytes = @splat(0),
                    .len = len,
                    .phase = text.phase,
                };
                @memcpy(scalar.bytes[0..len], bytes[held.offset..][0..len]);
                held.offset += len;
                try self.dispatchText(&scalar);
                if (held.offset < bytes.len) {
                    continue;
                }
            },
            .paste_start => try window_input.startPaste(&self.model, self.app),
            .paste_text => |*chunk| try window_input.pasteContent(&self.model, self.app, chunk.bytes[0..chunk.len]),
            .paste_finish => try self.finishPaste(),
            .paste_block => |*held| {
                const bytes = pending_input.large_events.view(held.slot).paste;
                if (!held.started) {
                    held.started = true;
                    try window_input.startPaste(&self.model, self.app);
                    continue;
                }

                if (held.offset < bytes.len) {
                    const count = PasteChunk.nextSize(bytes[held.offset..]);
                    const chunk = bytes[held.offset..][0..count];
                    held.offset += @intCast(count);
                    try window_input.pasteContent(&self.model, self.app, chunk);
                    continue;
                }

                try self.finishPaste();
            },
            .release_recovery => {
                if (!self.model.recovery_interactions_finished) {
                    try window_input.releasePointer(&self.model, self.app);
                    self.model.chrome.cancelPointer();
                    self.model.overlays.cancelPointer();
                    _ = try self.apply(
                        .{
                            .focus = false,
                        },
                    );
                    _ = try self.apply(
                        .{
                            .focus = self.model.focused,
                        },
                    );
                    self.model.pointer.scroll_remainder = 0;
                    self.model.recovery_interactions_finished = true;

                    if (pending_input.recovery.len != 0) {
                        continue;
                    }
                }

                if (pending_input.recovery.next()) |key| {
                    try self.dispatchKey(key);
                    pending_input.recovery.finish(key);

                    if (pending_input.recovery.len != 0) {
                        continue;
                    }
                }

                self.model.recovery_interactions_finished = false;
            },
            .pointer => |event| {
                if (event.event.interruptsKeys()) {
                    window_input.cancelBinding(&self.model);
                }

                if (event.event.retained() or (event.geometry_revision == self.model.pointer.revision and event.gesture_revision == self.model.pointer.gesture_revision)) {
                    if (try self.apply(
                        .{
                            .pointer = event.event,
                        },
                    )) {
                        pending_input.consume();
                        continue;
                    }
                }

                try self.dispatchPointer(event);
            },
            .scroll => |*sample| {
                if (!try self.dispatchScroll(sample)) {
                    continue;
                }
            },
            .owned_small => |index| {
                _ = try self.apply(pending_input.small_events.view(index));
            },
            .composition_cancel => |value| _ = try self.apply(
                .{
                    .composition = value,
                },
            ),
            .owned_large => |index| {
                if (!try self.dispatchClipboard(pending_input.large_events.view(index).clipboard)) {
                    continue;
                }
            },
        }

        app.telemetry.metrics.key_lease_overflows +%= self.model.router.leaseOverflowCount() -% overflows;
        pending_input.consume();
    }

    try self.finishInput(pending);
    try self.settleActivity();
}

/// Delivers one committed scalar to the focused widget or, failing that, to
/// the shared key router.
fn dispatchText(self: *GuiAdapter, text: *const TextCommit) !void {
    if (!try self.apply(
        .{
            .text = text.text(),
        },
    )) {
        _ = try self.routeKey(
            .{
                .key = text.key(),
                .now_ns = pacing.clock.monotonic(self.app.io),
            },
        );
    }
}

fn dispatchKey(self: *GuiAdapter, key: window_input.KeyInput) !void {
    if (try self.apply(
        .{
            .key = key,
        },
    )) {
        return;
    }

    if (key.code == .char and key.code.char.len == 1 and std.ascii.toLower(key.code.char.bytes[0]) == 'v' and (key.mods.super or (key.mods.ctrl and key.mods.shift))) {
        if (key.phase == .press and key.target_id == 0) {
            self.readTerminalClipboard() catch |err| switch (err) {
                error.HostRequestsFull => {},
                else => return err,
            };
        }

        return;
    }

    if (key.target_id != 0) {
        return;
    }

    _ = try self.routeKey(
        .{
            .key = key.terminalKey(),
            .now_ns = pacing.clock.monotonic(self.app.io),
        },
    );
}

fn dispatchClipboard(self: *GuiAdapter, result: window_input.ClipboardResult) !bool {
    if (result.status == .too_large) {
        // The host refused a paste larger than the window carries; it is
        // dropped whole, never cut, and the notice names the limit.
        client.limit_reached.report(
            self.app,
            .{
                .limit = input_limits.clipboard_limit,
            },
        );
    }

    if (self.model.terminal_clipboard.offset == null) {
        const kind = self.host.complete(result) orelse return true;

        if (kind == .write) {
            if (self.model.widgets.copy_feedback.complete(result, pacing.clock.monotonic(self.app.io))) {
                self.model.widgets.dispatcher.revision +%= 1;
            }

            if (result.target_id != 0) {
                var completion = result;
                completion.operation = .write;
                _ = try self.apply(
                    .{
                        .clipboard = completion,
                    },
                );
            }

            return true;
        }

        if (result.target_id != 0) {
            _ = try self.apply(
                .{
                    .clipboard = result,
                },
            );

            return true;
        }

        if (!window_input.takeTerminalClipboard(&self.model, self.app, result)) {
            return true;
        }

        _ = try window_input.applyInputDecision(&self.model, self.app, self.model.router.interrupt());
        _ = try client.pane_input.startPanePaste(self.app);
        self.model.terminal_clipboard.offset = 0;

        return false;
    }

    const offset = self.model.terminal_clipboard.offset.?;

    if (offset < result.text.len) {
        const count = PasteChunk.nextSize(result.text[offset..]);
        _ = try client.pane_input.appendPanePaste(self.app, result.text[offset..][0..count]);
        self.model.terminal_clipboard.offset = offset + count;

        return false;
    }

    _ = try client.pane_input.finishPanePaste(self.app);
    self.model.terminal_clipboard.offset = null;

    return true;
}

/// New gestures require current physical geometry; child drags keep their
/// original pane while copy-mode and chrome retain their own owners.
fn dispatchPointer(self: *GuiAdapter, value: PointerSample) !void {
    const app = self.app;
    const pointer = &self.model.pointer;

    const event = value.event;

    if (event.kind == .leave) {
        pointer.hover.clear();
        pointer.link_gesture.cancel();
        self.model.chrome.leavePointer();

        return;
    }

    const retained = event.kind == .release or event.kind == .drag;
    const button: usize = @intFromEnum(event.button);

    if (event.kind == .press and pointer.owners[button] == .shared) {
        pointer.owners[button] = .discarded;
    }

    if (!retained and value.geometry_revision != pointer.revision) {
        return;
    }

    pointer.hover.observe(event);

    if (event.kind != .move) {
        pointer.hover.dirty = true;
    }

    pointer.hover.refresh(self);

    if (event.kind == .move and pointer.owners[@intFromEnum(window_input.PointerEvent.Button.left)] == .link) {
        pointer.link_gesture.validate(pointer.hover.link, app.model.version());

        return;
    }

    const begins = event.kind == .press or event.kind == .scroll_up or event.kind == .scroll_down;

    if (begins and (value.gesture_revision != pointer.gesture_revision or !window_input.pointerGeometryMatches(self.app))) {
        return;
    }

    // Chrome bands lie outside the cell grid: a sample the grid does not
    // resolve goes to the delivered band targets, and a band gesture keeps
    // its drag and release even over cells.
    const resolved = if (self.model.chrome.band_gesture != null) null else pointer.geometry.resolve(event);
    const mouse = resolved orelse {
        try self.dispatchBandPointer(event);

        return;
    };

    if (event.kind == .press or event.retained()) {
        pointer.last[button] = mouse;
    }

    if (retained) {
        switch (pointer.owners[button]) {
            .child => |*capture| {
                try capture.deliver(app, mouse);

                if (event.kind == .release) {
                    pointer.owners[button] = .shared;
                }

                return;
            },
            .link => {
                if (event.kind == .drag) {
                    pointer.link_gesture.cancel();
                }

                if (event.kind == .release) {
                    pointer.owners[button] = .shared;
                    try self.openArmedLink();
                }

                return;
            },
            .discarded => {
                if (event.kind == .release) {
                    pointer.owners[button] = .shared;
                }

                return;
            },
            .shared => {},
        }
    }

    // A plain press leaves its link gesture with the pane: a drag becomes a
    // selection and only a release without motion opens the link.
    if (event.kind == .drag) {
        pointer.link_gesture.cancel();
    }

    const outcome = try self.routePointer(mouse);

    if (event.interruptsKeys()) {
        pointer.hover.dirty = true;
    }

    if (event.kind == .press) {
        pointer.owners[button] = switch (outcome) {
            .view, .copy_mode => .shared,
            .link => if (event.button == .right) .discarded else .link,
            .unavailable => .discarded,
            .pane => pane: {
                if (data.copy_mode.pointerSelection(&app.model)) |pointer_selection| {
                    if (pointer_selection.dragging) {
                        break :pane .shared;
                    }
                }

                const capture = PointerCapture.begin(app, mouse) orelse break :pane .discarded;

                break :pane .{
                    .child = capture,
                };
            },
        };

        if (event.button == .left and (pointer.owners[button] == .child or pointer.owners[button] == .discarded)) {
            pointer.link_gesture.cancel();
        }
    }

    if (event.kind == .release and event.button == .left) {
        try self.openArmedLink();
    }
}

fn dispatchBandPointer(self: *GuiAdapter, event: window_input.PointerEvent) !void {
    const app = self.app;
    const command = self.model.chrome.bandPointer(event) orelse {
        if (event.kind == .move) {
            self.model.chrome.leavePointer();
        }

        return;
    };

    const covered = app.model.name_prompt.active() or self.model.overlays.presented().modal != null;

    if (covered) {
        return;
    }

    if (command.sidebar_width) |width| {
        window_presentation.adoptSidebarWidth(&self.model, width);

        return;
    }

    try self.applyViewInteraction(command.interaction);
}

/// Routes delivered widget and band actions through the same owning client.
/// Example: `try applyViewInteraction(gui, .{ .intent = intent, .consumed = true });`
fn applyViewInteraction(self: *GuiAdapter, interaction: client.ViewInteractionCommand) !void {
    switch (interaction.intent) {
        .focus_machine_agent, .peek_machine_agent, .open_machine_worktree => {
            try self.openActivity(interaction.intent);
            return;
        },
        else => {},
    }

    _ = try client.view_interactions.apply(
        self.app,
        self.app.model.tabs.activeSlot(),
        interaction,
    );
}

fn dispatchScroll(self: *GuiAdapter, sample: *ScrollSample) !bool {
    if (sample.geometry_revision != self.model.pointer.revision or sample.gesture_revision != self.model.pointer.gesture_revision) {
        self.model.pointer.scroll_remainder = 0;

        return true;
    }

    const event = sample.event;

    if (!sample.started) {
        if (try self.apply(
            .{
                .scroll = event,
            },
        )) {
            self.model.pointer.scroll_remainder = 0;

            return true;
        }

        if (event.phase == .begin or event.phase == .cancel) {
            self.model.pointer.scroll_remainder = 0;
        }

        if (event.phase == .cancel) {
            return true;
        }

        const unit: f64 = if (event.precise) @floatFromInt(@max(1, self.model.pointer.geometry.size.cell_height_px)) else 1;
        const line_limit: f64 = @intFromEnum(InputLimit.scroll_lines_per_event);

        self.model.pointer.scroll_remainder += std.math.clamp(
            event.delta_y / unit,
            -line_limit,
            line_limit,
        );
        sample.lines = @intFromFloat(std.math.clamp(
            @trunc(self.model.pointer.scroll_remainder),
            -line_limit,
            line_limit,
        ));
        self.model.pointer.scroll_remainder -= @floatFromInt(sample.lines);
        sample.started = true;
    }

    if (sample.lines == 0) {
        return true;
    }

    const pointer: window_input.PointerEvent = .{
        .kind = if (sample.lines < 0) .scroll_up else .scroll_down,
        .mods = event.mods,
        .x = event.x,
        .y = event.y,
    };

    window_input.cancelBinding(&self.model);
    try self.dispatchPointer(self.model.pointer.sample(pointer));
    sample.lines += if (sample.lines < 0) @as(i8, 1) else -1;

    return sample.lines == 0;
}

/// Reserves one control slot to finish gestures even when ordinary input is
/// saturated. Example: `try cancelPointer(gui);`
fn cancelPointer(self: *GuiAdapter) !void {
    const pending_input = &self.model.input_queue;

    self.model.pointer.invalidateGestures();
    pending_input.requestRecovery();
    try self.drainInput();
    try self.resumeInput();
}

fn focus(self: *GuiAdapter, focused: bool) !void {
    self.model.focused = focused;

    if (!focused) {
        self.model.widgets.tab_drag.cancel();
    }

    self.model.input_revision +%= 1;
    _ = self.model.widgets.dispatcher.route(
        .{
            .focus = focused,
        },
    );

    if (!focused) {
        self.model.widgets.preedit.clear();
    }

    if (!focused) {
        self.model.pointer.hover.clear();
        self.model.pointer.link_gesture.cancel();
        self.model.chrome.cancelPointer();
        self.model.overlays.cancelPointer();
        try self.cancelPointer();
    }
}

fn forgetMachineView(self: *GuiAdapter) void {
    self.model.pointer.hover.clear();
    self.model.pointer.link_gesture.cancel();
    self.model.chrome.cancelPointer();
    self.model.overlays.cancelPointer();
    self.cancelPointer() catch {};
    self.model.widgets.tab_drag.cancel();
    self.model.chrome.invalidate();
}

fn open(self: *GuiAdapter) !void {
    const machines = &self.machines;
    const own = self.localClient();
    const path = client.profile_file.path(own.options.environ, &self.profiles_path) catch "";
    self.profiles_path_len = path.len;
    self.profiles_seen = client.profile_file.fingerprint(own.io, path);

    var profiles = self.readProfiles() catch core.MachineProfiles{};

    var hostname_buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const local_label = client.profile_file.localLabel(&profiles, &hostname_buffer);
    _ = try machines.add(.{ .label = local_label }, client.Machines.local_slot);

    for (profiles.slice()) |*profile| {
        _ = machines.find(profile.id) orelse try machines.add(.{
            .id = profile.id,
            .label = profile.label(),
            .destination = profile.destination(),
            .color = profile.color(),
            .enabled = profile.enabled,
            .telar_path = profile.telarPath(),
        }, null);
    }

    var requested: ?u8 = null;
    var requested_arguments: []const []const u8 = &.{};
    if (own.options.open_machine) |remote| {
        const slot = window_machines.machineFor(machines, remote.destination) orelse try machines.add(.{
            .label = remote.destination,
            .destination = remote.destination,
        }, null);
        machines.pinned[slot] = machines.id[slot] == .invalid or !machines.enabled[slot];
        machines.enabled[slot] = true;
        requested = slot;
        requested_arguments = remote.arguments;
    }

    for (machines.used, machines.enabled, 0..) |used, enabled, index| {
        const slot: u8 = @intCast(index);
        if (!used or !enabled or slot == client.Machines.local_slot or machines.live[slot]) {
            continue;
        }

        try self.openClient(slot, if (requested == slot) requested_arguments else &.{});
    }

    if (requested) |slot| {
        try self.select(slot);
    }

    try self.watchProfiles();
}

fn profilesChanged(self: *GuiAdapter, fingerprint: u64) !void {
    self.profiles_seen = fingerprint;
    self.reconcile() catch |err| {
        std.log.scoped(.machines).warn("machines.json not applied: {s}", .{@errorName(err)});
        try client.notifications.publishNotificationNow(self.app, .{
            .level = .failure,
            .title = "machines.json not applied",
            .message = client.machine_profiles.describe(err),
        });
    };

    try self.watchProfiles();
}

fn reconcile(self: *GuiAdapter) !void {
    const machines = &self.machines;
    var profiles = try self.readProfiles();

    var hostname_buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const local_label = client.profile_file.localLabel(&profiles, &hostname_buffer);
    if (!std.mem.eql(u8, machines.label(client.Machines.local_slot), local_label)) {
        machines.update(client.Machines.local_slot, .{ .label = local_label });
    }

    for (0..client.Machines.capacity) |index| {
        const slot: u8 = @intCast(index);
        const id = machines.id[slot];
        if (!machines.used[slot] or id == .invalid or window_machines.profileFor(&profiles, id) != null) {
            continue;
        }

        try self.retire(slot, .removed);
        machines.remove(slot);
    }

    for (profiles.slice()) |*profile| {
        var row: client.MachineRow = .{
            .id = profile.id,
            .label = profile.label(),
            .destination = profile.destination(),
            .color = profile.color(),
            .enabled = profile.enabled,
            .telar_path = profile.telarPath(),
        };

        const slot = machines.find(profile.id) orelse window_machines.temporaryFor(machines, profile.destination()) orelse {
            const added = try machines.add(row, null);
            if (profile.enabled) {
                try self.admit(added);
            }

            continue;
        };

        if (profile.enabled) {
            machines.pinned[slot] = false;
        }

        row.enabled = profile.enabled or machines.pinned[slot];
        const was_enabled = machines.enabled[slot];
        const moved = !std.mem.eql(u8, machines.destination(slot), profile.destination()) or
            !std.mem.eql(u8, machines.telarPath(slot) orelse "", profile.telarPath() orelse "");
        machines.update(slot, row);
        if (!row.enabled) {
            if (was_enabled) {
                try self.retire(slot, .disabled);
            }

            continue;
        }

        if (!was_enabled or moved) {
            try self.admit(slot);
        }
    }

    for (machines.live, 0..) |live, index| {
        if (live) {
            _ = machines.summarize(@intCast(index), &self.clients[index].model, self.clients[index].io);
        }
    }
}

fn handle(self: *GuiAdapter, slot: u8, message: client.Message) !?u8 {
    const app = &self.clients[slot];
    const status = try app.update(message);
    _ = self.machines.summarize(slot, &app.model, app.io);
    try client.machine_presentation.settle(app);
    try self.settleActivity();

    if (slot != self.machines.active) {
        window_machines.dropHostEffects(app);
        return null;
    }

    if (status) |value| {
        if (slot == client.Machines.local_slot) {
            return value;
        }

        try self.select(client.Machines.local_slot);
        return null;
    }

    return null;
}

fn retire(self: *GuiAdapter, slot: u8, reason: window_machines.Retirement) !void {
    const machines = &self.machines;
    if (slot == machines.active) {
        try self.select(client.Machines.local_slot);

        var buffer: [2 * client.Machines.max_label_bytes + 64]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "{s} was {s}; the window shows {s}", .{
            machines.label(slot),
            @tagName(reason),
            machines.label(client.Machines.local_slot),
        }) catch "the window shows this machine";
        try client.notifications.publishNotificationNow(self.localClient(), .{
            .title = "Machine left the window",
            .message = message,
        });
    }

    if (self.pending_machine == slot) {
        self.pending_machine = null;
    }

    if (self.machines.live[slot]) {
        try client.runtime_link.stop(&self.clients[slot]);
    }
}

fn openActivity(self: *GuiAdapter, intent: client.Intent) !void {
    self.pending_activity = intent;
    try self.settleActivity();
}

/// Measures `viewport` with the shared sidebar visibility, negotiates the PTY
/// with every live client and places the pointer on the new grid.
fn resizeViewport(self: *GuiAdapter, viewport: Window.Viewport) !void {
    const viewport_changed = !std.meta.eql(
        self.renderer.viewport,
        [2]u32{
            viewport.width,
            viewport.height,
        },
    ) or self.renderer.scale != viewport.scale;

    self.renderer.sidebar_request = self.model.sidebar.request(self.app.model.sidebar_visible);
    const size = try self.renderer.measure(viewport);
    self.reportEntering(
        .grid_cells,
        if (self.renderer.cut_from) |wanted| .{
            .limit = limit_reached.cell_count_limit,
            .requested = wanted,
        } else null,
    );

    if (viewport_changed or !std.meta.eql(size, self.app.model.host.host_size) or self.model.widgets.tab_drag_step != self.renderer.chrome.px(@intFromEnum(TabDragStep.logical_pixels))) {
        self.model.widgets.tab_drag.cancel();
    }

    self.model.sidebar.observe(self.renderer.sidebar);

    var capabilities = self.app.model.host.host_capabilities;
    capabilities.window_width_px = @as(u32, size.cols) * size.cell_width_px;
    capabilities.window_height_px = @as(u32, size.rows) * size.cell_height_px;
    capabilities.cell_width_px = size.cell_width_px;
    capabilities.cell_height_px = size.cell_height_px;
    capabilities.images = .supported;
    capabilities.pointer_pixels = .supported;
    capabilities.terminal_colors = .{
        .foreground = self.renderer.theme.foreground,
        .background = self.renderer.theme.background,
        .palette = self.renderer.theme.palette,
    };

    _ = try client.host_resize.applyHostUpdate(
        &self.clients[client.Machines.local_slot],
        .{
            .size = size,
            .capabilities = capabilities,
        },
    );
    try self.shareHost();
    self.model.pointer.configure(self.renderer.origin, size);
}

/// Gives every other live client the host facts the window's own client just
/// adopted, so a machine shows at the right size when it is chosen.
fn shareHost(self: *GuiAdapter) !void {
    const own = &self.clients[client.Machines.local_slot];
    for (self.machines.live, 0..) |live, index| {
        if (!live or index == client.Machines.local_slot) {
            continue;
        }

        _ = try client.host_resize.applyHostUpdate(
            &self.clients[index],
            .{
                .size = own.model.host.host_size,
                .capabilities = own.model.host.host_capabilities,
            },
        );
    }
}

/// Publishes the frame interval the pacer settles on to every live client.
fn paceFrames(self: *GuiAdapter) !void {
    const interval = self.frame_pacer.pace(self.renderer.config.max_fps, &self.model.chrome.animation);
    const own = &self.clients[client.Machines.local_slot];
    if (!self.started or interval == own.model.host.host_capabilities.frame_interval_ns) {
        return;
    }

    var capabilities = own.model.host.host_capabilities;
    capabilities.frame_interval_ns = interval;
    _ = try client.host_resize.applyHostUpdate(
        own,
        .{
            .size = own.model.host.host_size,
            .capabilities = capabilities,
        },
    );
    try self.shareHost();
}

/// Acquires one native source on the window thread, then transfers it to the
/// existing joined worker. A refused source or worker slot leaves its failed
/// completion for update, which wakes for it; a full completion queue never
/// repeats the native read.
fn poll(self: *GuiAdapter, window: *Window) void {
    if (self.previews.capturing or self.unposted.capture != null) {
        return;
    }

    const request = self.previews.queued orelse return;
    self.previews.queued = null;
    self.launch(window, request) catch |err| {
        self.unposted.capture = .{
            .execution_id = @enumFromInt(request.sequence),
            .result = err,
        };
        self.inbox.wakeup.notify();
    };
}

fn launch(self: *GuiAdapter, window: *Window, request: data.CaptureRequest) !void {
    try request.target.validate();
    var source = try window.clipboardSource();
    errdefer source.deinit();
    const app = self.localClient();
    try self.inbox.start(.clipboard_image, .{ clipboard_image.capture, .{ app.gpa, request, source, &app.model.clipboard.orphan, &self.previews.landing } });
    self.previews.capturing = true;
}

fn finish(self: *GuiAdapter, completion: data.Completion) !void {
    const previews = &self.previews;
    const app = self.localClient();
    previews.capturing = false;
    const completed = client.clipboard_capture.completeClipboardCapture(app, completion);
    previews.dropLanding();

    if (previews.queued != null) {
        self.inbox.wakeup.notify();
    }

    return completed;
}

fn absorb(self: *GuiAdapter, route: limit_reached.Route, err: anyerror) bool {
    const reach = switch (route) {
        inline else => |known| client.limit_reached.classify(@tagName(known), err, limit_reached.limitOf(err)) catch return false,
    };

    self.collect(reach);
    return true;
}

fn collect(self: *GuiAdapter, reach: core.LimitReach) void {
    const waiting = self.collected.count != 0;
    self.collected.add(reach);
    if (!waiting) {
        self.inbox.wakeup.notify();
    }
}

fn reportFrame(self: *GuiAdapter, scene: *const Scene) void {
    const chrome = self.model.chrome.prepared();
    self.reportDropped(.frame_widgets, frame_widget.limit, frame_widget.capacity, scene.dropped_widgets);
    self.reportDropped(.band_hits, BandHitMap.limit, chrome.band_hits.len, chrome.band_hits.dropped);
    self.reportDropped(.cell_hits, HitMap.limit, chrome.hits.len, chrome.hits.dropped);

    const targets = self.model.widgets.dispatcher.maps.prepared();
    self.reportDropped(.widget_targets, Registry.limit, targets.len, targets.dropped);

    const editors = self.model.widgets.editors.prepared();
    self.reportDropped(.editors, State.editors_limit, editors.len, editors.dropped);

    const quads = &self.renderer.quads;
    self.reportDropped(.frame_quads, core.Limit.declare("render.frame_quad_budget", "quads", quads.limit orelse 0), quads.items().len, quads.dropped);

    const cell_quads = &self.renderer.cell_quads;
    self.reportDropped(.cell_quads, CellMesh.limit, CellMesh.capacity, cell_quads.dropped);

    self.reportDropped(.image_placements, PaneImages.limit, self.images.placement_count, self.images.dropped);
}

fn reportAccessibility(self: *GuiAdapter) void {
    self.reportDropped(.accessible_nodes, AccessibilityTree.limit, AccessibilityTree.capacity, self.model.widgets.accessibility_dropped);
}

fn reportEntering(self: *GuiAdapter, which: WindowLimit, reach: ?core.LimitReach) void {
    const value = reach orelse {
        self.reached.remove(which);
        return;
    };

    if (self.reached.contains(which)) {
        return;
    }

    self.reached.insert(which);
    self.collect(value);
}

fn reportDropped(self: *GuiAdapter, which: WindowLimit, limit: core.Limit, kept: usize, dropped: usize) void {
    self.reportEntering(
        which,
        if (dropped == 0) null else .{
            .limit = limit,
            .requested = kept + dropped,
        },
    );
}

fn holds(self: *const GuiAdapter) bool {
    const limited = self.limited orelse return false;
    return std.meta.eql(limited.observation, self.observation());
}

fn holdsFrame(self: *const GuiAdapter, viewport: Window.Viewport) bool {
    const limited = self.limited orelse return false;
    return std.meta.eql(limited.viewport, viewport) and self.holds();
}

fn publishWindow(self: *GuiAdapter, window: *Window) !void {
    var text: native.TextContext = .{};
    _ = host_context.text(&self.model, self.app, &text);
    try window.setTextContext(@bitCast(text));
    var tree: native.AccessibilityTree = .{};
    _ = self.accessibilitySnapshot(&tree);
    try window.setAccessibility(@bitCast(tree));
    try window.setPointerShape(@intFromEnum(self.model.pointer.hover.shape));
    var title: native.WindowTitle = .{};
    if (try self.windowTitle(&title)) {
        try window.setTitle(title.bytes[0..title.len]);
    }
    while (true) {
        if (self.pending_host_request == null) {
            var request: native.HostRequest = .{};
            if (!self.host.next(&request)) {
                break;
            }
            self.pending_host_request = request;
        }
        window.requestHost(@bitCast(self.pending_host_request.?)) catch |err| {
            if (err == error.HostRequestsFull) {
                break;
            }
            return err;
        };
        self.pending_host_request = null;
    }
}

fn windowTitle(self: *GuiAdapter, out: *native.WindowTitle) !bool {
    out.* = .{};
    const model = &self.app.model;
    const tab_label = if (model.tabs.activeSlot()) |tab| data.tab_label.text(model, tab) else "";
    var suffix_buffer: [limit_reached.title_suffix_bytes]u8 = undefined;
    return self.window_title.sync(
        .{
            .context = out,
            .set = window_effects.copyWindowTitle,
        },
        .{
            // Without a template the window still names a held limit.
            .template = if (data.config_reload.windowTitleTemplate(model).len != 0) data.config_reload.windowTitleTemplate(model) else GuiAdapter.default_title,
            .tokens = .{
                .workspace = model.workspaceName(),
                .tab = tab_label,
                .pane_title = data.pane_title.focusedTitle(model),
                .hostname = if (self.machines.count() != 0) self.machines.label(self.machines.active) else "",
            },
            .suffix = if (self.limited) |limited| std.fmt.bufPrint(&suffix_buffer, " \u{2014} limit reached: {s}", .{limited.limitName()}) catch "" else "",
        },
    );
}

fn requestClipboardRead(self: *GuiAdapter, target_id: u64, generation: u64) !void {
    try self.beginClipboardRead(
        .{
            .target_id = target_id,
            .generation = generation,
        },
    );
}

fn requestClipboardWrite(self: *GuiAdapter, bytes: []const u8) !void {
    const superseded = self.host.superseded;
    _ = self.host.write(bytes) catch |err| return window_effects.refuseHostRequest(self.app, err, bytes.len);
    self.reportSuperseded(superseded);
    self.inbox.wakeup.notify();
}

fn reportSuperseded(self: *GuiAdapter, before: u64) void {
    if (self.host.superseded == before) {
        return;
    }

    client.limit_reached.report(
        self.app,
        .{
            .limit = HostServices.limit,
            .requested = HostServices.capacity + 1,
        },
    );
}

fn copyLink(self: *GuiAdapter, bytes: []const u8) !void {
    self.model.widgets.copy_feedback.pending = try self.requestClipboardWriteOwned(
        .{},
        bytes,
    );
}

fn requestClipboardWriteOwned(self: *GuiAdapter, owner: ClipboardOwner, bytes: []const u8) !u64 {
    const superseded = self.host.superseded;
    const request = self.host.writeOwned(owner, bytes) catch |err| return window_effects.refuseHostRequest(self.app, err, bytes.len);
    self.reportSuperseded(superseded);
    self.inbox.wakeup.notify();

    return request;
}

fn viewportPending(self: *const GuiAdapter, viewport: Window.Viewport) bool {
    const renderer = &self.renderer;
    return viewport.width != renderer.viewport[0] or viewport.height != renderer.viewport[1] or
        viewport.scale != renderer.scale or viewport.controls != renderer.controls;
}

fn prepareNextFrame(self: *GuiAdapter) !?*const Frame {
    self.frame_wait_ms = 0;

    if (self.exit_status != null or self.app.presentation.active != null or !self.needs_draw) {
        return null;
    }

    const viewport = self.viewport orelse return null;
    if (self.viewportPending(viewport) or self.holdsFrame(viewport)) {
        return null;
    }

    // How long the visible panes' frame pacing wants this frame to wait.
    const delay = delay: {
        var visible: [core.max_panes_per_tab]FramePacer.Pane = undefined;
        var count: usize = 0;
        const model = &self.app.model;
        if (model.tabs.activeSlot()) |tab| {
            const layout = data.tab_layout.snapshot(model, tab, data.workbench.region(model).area);
            for (layout.views()) |view| {
                if (view.content.w == 0 or view.content.h == 0) {
                    continue;
                }

                const pane = model.panes.findInConst(model.tabs.location[tab].tab_id, view.pane_id) orelse continue;
                visible[count] = .{
                    .pane_id = pane.id,
                    .attachment_generation = pane.attachment_generation,
                    .frame_id = pane.applied_frame_id,
                    .attached = pane.attached,
                };
                count += 1;
            }
        }

        const now_ns = pacing.clock.monotonic(self.app.io);
        const deadline = self.frame_pacer.waitUntil(visible[0..count], now_ns) orelse break :delay 0;
        break :delay deadline -| now_ns;
    };
    if (delay != 0) {
        self.frame_wait_ms = @intCast(@min(std.math.maxInt(u32), @max(1, std.math.divCeil(u64, delay, std.time.ns_per_ms) catch unreachable)));
        return null;
    }

    core.profiling.add(.gui_draw, 1);
    const profile_started = core.profiling.start(self.app.io);
    defer core.profiling.finish(self.app.io, .gui_draw, profile_started);

    const now_ns = pacing.clock.monotonic(self.app.io);
    self.model.cursor_clock.observe(window_presentation.cursorTarget(self.app), now_ns);
    self.renderer.cursor_on = self.model.cursor_clock.shown(now_ns);
    self.renderer.focused = self.model.cursor_clock.focused;
    const token = self.prepare(&self.renderer) catch |err| {
        if (!self.absorb(.window_draw, err)) {
            return err;
        }

        const name = if (limit_reached.limitOf(err)) |limit| limit.name else @errorName(err);
        self.limited = LimitedFrame.init(self.observation(), viewport, name);

        self.inbox.wakeup.notify();
        return null;
    };

    if (self.limited != null) {
        self.limited = null;
        self.inbox.wakeup.notify();
    }

    if (token == 0) {
        return null;
    }

    self.frame_pacer.record(self.app.presentation.active.?.delivery.commit.slice(), now_ns);
    self.frame.token = token;
    self.frame.image_uploads = self.images.uploads[0..self.images.upload_count];
    self.frame.image_releases = self.images.releases[0..self.images.release_count];
    return &self.frame;
}

fn wakeupAfter(self: *const GuiAdapter) u32 {
    const now_ns = pacing.clock.monotonic(self.app.io);
    const widgets = if (self.app.presentation.active == null) self.model.chrome.animation.wakeupAfter(now_ns) else 0;
    const images = pane_images.wakeupAfter(&self.images, now_ns);
    const glyphs = self.renderer.atlasWakeupAfter(now_ns);
    return animate.FrameClock.earliest(animate.FrameClock.earliest(animate.FrameClock.earliest(self.model.cursor_clock.wakeupAfter(now_ns), widgets), images), glyphs);
}

fn prepare(self: *GuiAdapter, renderer: *Renderer) !u64 {
    self.model.widgets.tab_drag.validate(&self.app.model);

    if (!self.app.model.request_lifecycle.tracker.has(.tab_operation)) {
        self.model.widgets.tab_drop_pending = null;
    }

    if (self.app.presentation.active != null) {
        return error.PresentationBusy;
    }

    self.model.chrome.now_ns = pacing.clock.monotonic(self.app.io);
    self.diagrams.beginFrame();
    self.previews.beginFrame();

    self.refreshPointer();
    const projected = self.projection();
    const observed = self.observation();
    _ = self.app.presentation.observe(observed);
    pane_images.place(
        &self.images,
        &self.graphics_stores,
        .{
            .machine = self.machines.active,
            .cell_width = renderer.metrics.cell_width,
            .cell_height = renderer.metrics.cell_height,
        },
        pacing.clock.monotonic(self.app.io),
    );
    pane_images.start(&self.images, &self.graphics_stores, self.machines.active, pacing.clock.monotonic(self.app.io));
    var scene: Scene = .{
        .renderer = renderer,
        .chrome = &self.model.chrome,
        .overlays = &self.model.overlays,
        .theme = self.app.model.theme,
        .link = if (self.model.pointer.hover.link) |*hit| hit else null,
        .widgets = &self.model.widgets,
        .diagrams = &self.diagrams.store,
        .previews = if (self.showsPreviews()) &self.previews else null,
    };

    if (self.previews.revision != self.previews_prepared) {
        self.previews_prepared = self.previews.revision;
        self.model.chrome.invalidate();
    }

    switch (try renderer.settleAtlas(pacing.clock.monotonic(self.app.io))) {
        .exhausted => self.reportEntering(
            .glyph_page,
            .{
                .limit = GlyphAtlas.side_limit,
            },
        ),
        .outgrown, .shrunk => self.reportEntering(.glyph_page, null),
        .kept, .emptied => {},
    }

    const commit = try scene.compose(&self.frame, projected);
    self.frame.images = self.images.resolved();
    self.frame.diagrams[ImagePreviews.sheet_slot..][0..2].* = self.previews.textures(self.showsPreviews());
    const background = renderer.theme.background;
    self.frame.background = .{
        @as(f32, @floatFromInt(background[0])) / 255,
        @as(f32, @floatFromInt(background[1])) / 255,
        @as(f32, @floatFromInt(background[2])) / 255,
        renderer.config.window.background_opacity,
    };
    self.frame.background_blur = renderer.config.window.background_blur;
    self.frame.titlebar = @intFromBool(renderer.config.window.titlebar);
    self.frame.navigation = renderer.chrome.top_bar;

    const token = try self.app.presentation.begin(
        .{
            .observation = observed,
            .commit = commit,
            .geometry = client.Geometry.capture(projected),
        },
    );
    self.model.pointer.hover.prepare(window_presentation.tooltipCover(&self.model, renderer));

    return @intFromEnum(token);
}

fn drawn(self: *GuiAdapter, frame: *const Frame) void {
    var scene: Scene = .{
        .renderer = &self.renderer,
        .chrome = &self.model.chrome,
        .overlays = &self.model.overlays,
        .theme = frame.theme,
        .widgets = &self.model.widgets,
        .dropped_widgets = frame.widgets.dropped,
    };
    scene.seal();
    self.reportFrame(&scene);
    pane_images.noteDrawn(&self.images, self.renderer.imageDraws());
    if (comptime core.enabled) {
        self.app.telemetry.metrics.graphics_presented = self.images.presented;
        self.app.telemetry.metrics.graphics_gpu_bytes = self.images.gpu.resident_bytes;
    }

    const revision = self.diagrams.store.revision;
    self.diagrams.start(&self.inbox);
    if (self.diagrams.store.revision != revision) {
        self.model.chrome.invalidate();
    }

    self.startFontDiscovery();
}

/// Adopts a finished installed-font lookup and starts the next. A face that
/// joined repaints every retained cell, since cells drawn while it was being
/// looked up show the replacement glyph.
fn fontDiscovered(self: *GuiAdapter) void {
    const fonts = if (self.renderer.atlas) |*atlas| &atlas.fonts else null;
    if (self.font_discovery.finish(fonts)) {
        self.renderer.retained.invalidate();
        self.model.chrome.invalidate();
    }

    self.startFontDiscovery();
}

fn startFontDiscovery(self: *GuiAdapter) void {
    const atlas = if (self.renderer.atlas) |*value| value else return;
    self.font_discovery.start(&self.inbox, &atlas.fonts, self.app.io);
}

fn showsPreviews(self: *const GuiAdapter) bool {
    return self.app == &self.clients[client.Machines.local_slot];
}

pub fn projection(self: *GuiAdapter) client.Projection {
    var projected = client.capture(
        &self.app.model,
        .{
            .geometry = data.workbench.region(&self.app.model),
            .status_mode = window_presentation.statusMode(&self.model, self.app),
            .presentation_ingress = window_presentation.ingress(&self.model),
        },
    );
    projected.bar_state = &self.localClient().model.bars;
    projected.machines = &self.machines;
    var count: usize = 0;
    for (self.machines.used, self.machines.live, 0..) |used, live, index| {
        if (!used or !live) {
            continue;
        }

        const slot: u8 = @intCast(index);
        self.activity_sources[count] = .{
            .slot = slot,
            .label = self.machines.label(slot),
            .model = &self.clients[slot].model,
            .connected = self.machines.enabled[slot] and self.clients[slot].model.runtime_link.phase == .connected,
        };
        count += 1;
    }

    projected.activity_sources = self.activity_sources[0..count];
    return projected;
}

fn observation(self: *const GuiAdapter) client.Observation {
    var version = self.app.model.version();
    const own = &self.clients[client.Machines.local_slot];
    if (self.app != own) {
        version.bars = self.app.model.bars_revision +% own.model.bars_revision;
    }

    version.link +%= self.machines.revision;
    return .{
        .model = version,
        .graphics_ingress = self.graphics_stores[self.machines.active].ingressVersion() +% self.images.revision,
        .attachment_ingress = self.previews.revision,
        .geometry_revision = data.workbench.region(&self.app.model).revision,
        .presentation_ingress = window_presentation.ingress(&self.model),
    };
}

fn finishPaste(self: *GuiAdapter) !void {
    if (self.model.paste_route == .widget) {
        try self.endPaste();
    } else {
        _ = try client.paste_routing.finish(self.app);
    }

    self.model.paste_route = .shared;
}

fn routeKey(self: *GuiAdapter, event: client.key_router.Type.KeyInput) !keyinput.Control {
    errdefer self.model.router.eventFailed(event.key);

    const decision = self.model.router.routeEvent(
        event,
        .{
            .captures_keys = data.key_routing.captures(client.key_routing.keyRoutingAuthority(self.app)),
            .repeat_policy = if (self.model.router.repeatAction()) |held| client.repeatPolicy(held, client.actions.repeatPane(self.app)) else null,
        },
    );

    const control = try window_input.applyInputDecision(&self.model, self.app, decision);
    self.stopped = control == .stop;

    return control;
}

fn readTerminalClipboard(self: *GuiAdapter) !void {
    const clipboard = &self.model.terminal_clipboard;

    if (clipboard.request_id != 0 or self.app.model.name_prompt.active() or data.copy_mode.isActive(&self.app.model)) {
        return;
    }

    const tab = self.app.model.tabs.activeSlot() orelse return;
    const pane = data.tab_layout.focusedPaneConst(&self.app.model, tab) orelse return;
    clipboard.request_id = self.host.read(
        .{
            .generation = pane.attachment_generation,
        },
    ) catch |err| return window_effects.refuseHostRequest(self.app, err, 0);
    clipboard.pane_id = pane.id;
    clipboard.generation = pane.attachment_generation;
    self.inbox.wakeup.notify();
}

fn routePointer(self: *GuiAdapter, mouse: keyinput.Mouse) !client.pointer_routing.Outcome {
    const app = self.app;
    const route = switch (try client.pointer_routing.admit(app, mouse)) {
        .settled => |outcome| return outcome,
        .routed => |value| value,
    };

    if (try client.pointer_routing.interact(app, route, window_input.chromePointer(&self.model, self.app, route.command.event))) {
        return .view;
    }

    return client.pointer_routing.deliver(app, route, self.linkPointer(route.command.event));
}

fn linkPointer(self: *GuiAdapter, event: keyinput.Mouse) bool {
    if (event.kind != .press or event.button & 3 == 1) {
        return false;
    }

    const routing = &self.model.pointer;
    const model = &self.app.model;
    if (event.button & 3 == 2) {
        const hit = hover_target.resolve(&self.model, self.app, event, hover_target.link_modifier | 1).link orelse return false;
        const pane = model.panes.findInConst(model.tabs.location[model.tabs.active].tab_id, hit.pane_id).?;
        if (pane.pending_frame_id == 0) {
            self.copyLink(hit.match.target.uri()) catch {};
        }

        return true;
    }

    routing.hover.dirty = true;
    routing.hover.refresh(self);
    const hit = routing.hover.link orelse {
        routing.link_gesture.cancel();
        return false;
    };

    const mods: u32 = if (routing.hover.event) |hover_event| hover_event.mods else 0;
    const pane = model.panes.findInConst(model.tabs.location[model.tabs.active].tab_id, hit.pane_id).?;
    if (pane.mouse.tracking != .none and mods & 1 == 0) {
        routing.link_gesture.cancel();
        return false;
    }

    if (routing.hover.openable()) {
        routing.link_gesture.begin(hit, model.version());
    } else {
        routing.link_gesture.cancel();
    }

    return mods & hover_target.link_modifier != 0;
}

fn openArmedLink(self: *GuiAdapter) !void {
    const pointer = &self.model.pointer;
    pointer.hover.dirty = true;
    pointer.hover.refresh(self);
    const opened = if (window_input.pointerGeometryMatches(self.app) and pointer.hover.openable()) pointer.link_gesture.finish(pointer.hover.link, self.app.model.version()) else null;
    pointer.link_gesture.cancel();

    if (opened) |hit| {
        _ = try client.link_opening.openLink(self.app, hit.match.target, hit.pane_id);
    }
}

fn finishInput(self: *GuiAdapter, pending: bool) !void {
    const app = self.app;

    if (pending != self.model.router.prefixPending()) {
        self.model.binding_revision +%= 1;
    }

    if (self.binding_timeout.update(app.io, self.model.router.bindingDeadline()) == .schedule) {
        self.inbox.start(.binding_timeout, .{ pacing.deadline_timer.wait, .{ app.io, &self.binding_timeout } }) catch |err| {
            self.binding_timeout.schedulingFailed();

            return err;
        };
    }
}

fn expireBinding(self: *GuiAdapter, result: anyerror!void) !void {
    const app = self.app;

    try self.binding_timeout.complete(result);
    const pending = self.model.router.prefixPending();
    self.stopped = try window_input.applyInputDecision(&self.model, self.app, self.model.router.expireBinding(pacing.clock.monotonic(app.io))) == .stop;
    try self.finishInput(pending);
}

fn resumeInput(self: *GuiAdapter) !void {
    if (self.model.input_queue.len != 0 and !window_input.holdsStartupInput(self.app) and self.app.model.to_runtime.availableCapacity() >= @intFromEnum(InputLimit.minimum_outbox_slots)) {
        self.inbox.notify(.input_ready) catch |err| {
            if (err != error.InboxFull) {
                return err;
            }
        };
    }
}

fn refreshPointer(self: *GuiAdapter) void {
    self.model.pointer.hover.refresh(self);
    self.model.pointer.link_gesture.validate(self.model.pointer.hover.link, self.app.model.version());
}

fn graphicsRetention(self: *GuiAdapter, slot: u8) client.GraphicsRetention {
    return .{
        .context = &self.graphics_stores[slot],
        .apply_fn = host_ports.applyGraphics,
        .clear_pane_fn = host_ports.clearPaneGraphics,
        .set_pane_visible_fn = host_ports.setPaneGraphicsVisible,
        .pane_visible_fn = host_ports.paneGraphicsVisible,
        .has_pane_graphics_fn = host_ports.hasPaneGraphics,
        .ingress_version_fn = host_ports.graphicsIngressVersion,
        .peek_credit_fn = host_ports.peekGraphicsCredit,
        .consume_credit_fn = host_ports.consumeGraphicsCredit,
    };
}

pub fn localClient(self: *GuiAdapter) *client.Client {
    return &self.clients[client.Machines.local_slot];
}

pub fn shareConfiguration(self: *GuiAdapter) !void {
    const own = self.localClient();
    for (self.machines.live, 0..) |live, index| {
        if (!live or index == client.Machines.local_slot) {
            continue;
        }

        try client.config_adoption.followConfiguration(&self.clients[index], own);
    }
}

fn openClient(self: *GuiAdapter, slot: u8, arguments: []const []const u8) !void {
    const own = self.localClient();
    const machines = &self.machines;
    const destination = machines.destination(slot);
    const identity = window_machines.machineIdentity(own.client_identity, destination);

    var options = own.options;
    options.machine = .{ .remote = .{
        .destination = destination,
        .telar_path = machines.telarPath(slot),
        .arguments = arguments,
    } };
    options.open_machine = null;
    options.cwd = "";
    options.arguments = &.{};
    options.lua_generation = null;
    options.plugin_registry = null;
    options.trust_store = null;

    const app = &self.clients[slot];
    const host = own.model.host;
    try client.Client.init(app, .{
        .gpa = own.gpa,
        .io = own.io,
        .host_size = host.host_size,
        .window_width_px = host.host_capabilities.window_width_px,
        .window_height_px = host.host_capabilities.window_height_px,
        .client_identity = identity,
        .options = options,
    });
    machines.live[slot] = true;

    app.owns_configuration = false;
    app.graphics = self.graphicsRetention(slot);
    app.chrome = self.chromePort();
    app.presented = false;
    app.machines = &self.machines;
    try client.config_adoption.followConfiguration(app, own);
    _ = try client.host_resize.applyHostUpdate(app, .{
        .size = host.host_size,
        .capabilities = host.host_capabilities,
    });

    app.model.startup.phase = .opening;
    app.bootstrap = .{
        .graphics_shared = false,
        .client_identity = identity,
        .terminal_colors = host.host_capabilities.terminal_colors,
    };
    try client.runtime_link.start(app);
}

fn admit(self: *GuiAdapter, slot: u8) !void {
    if (!self.machines.live[slot]) {
        return self.openClient(slot, &.{});
    }

    const app = &self.clients[slot];
    if (app.model.runtime_link.phase != .stopped) {
        try client.runtime_link.stop(app);
    }

    const destination = self.machines.destination(slot);
    const identity = window_machines.machineIdentity(self.localClient().client_identity, destination);
    app.options.machine = .{ .remote = .{
        .destination = destination,
        .telar_path = self.machines.telarPath(slot),
        .arguments = &.{},
    } };
    app.client_identity = identity;
    if (app.bootstrap) |*bootstrap| {
        bootstrap.client_identity = identity;
    }

    try client.runtime_link.start(app);
}

fn watchProfiles(self: *GuiAdapter) !void {
    if (self.profiles_path_len == 0) {
        return;
    }

    const own = self.localClient();
    try self.inbox.start(.profiles_changed, .{ client.profile_file.waitForChange, .{
        own.io,
        self.profiles_path[0..self.profiles_path_len],
        self.profiles_seen,
    } });
}

fn readProfiles(self: *GuiAdapter) !core.MachineProfiles {
    if (self.profiles_path_len == 0) {
        return error.NoProfilesPath;
    }

    const own = self.localClient();
    return client.profile_file.load(own.io, own.gpa, self.profiles_path[0..self.profiles_path_len]);
}

fn chromePort(self: *GuiAdapter) client.HostChrome {
    return .{
        .context = self,
        .inspection_scroll_limit_fn = chrome_port.inspectionScrollLimit,
    };
}

fn accessibilitySnapshot(self: *GuiAdapter, output: *native.AccessibilityTree) bool {
    defer self.reportAccessibility();
    const state = &self.model.widgets;
    const registry = state.dispatcher.maps.presented();
    const modal = self.app.model.name_prompt.active();
    var count: usize = 0;
    state.accessibility_dropped = 0;
    for (registry.targets[0..registry.len]) |*target| {
        if (target.layer < registry.modal_layer or (target.layer != 0) != modal) {
            continue;
        }

        const focused = if (state.dispatcher.focused) |id| id.eql(target.id) else false;
        var slot = count;
        if (count == state.native_nodes.len) {
            if (!focused) {
                state.accessibility_dropped += 1;
                continue;
            }

            slot = count - 1;
            state.accessibility_dropped += 1;
        }
        var node: native.AccessibilityNode = .{
            .id = target.id.target_id,
            .generation = target.id.generation,
            .role = target.role,
            .flags = @as(u32, @intFromBool(target.enabled)) | (if (focused) @as(u32, 2) else 0) | (if (target.layer != 0) @as(u32, 32) else 0),
            .actions = (if (target.focusable) @as(u32, 2) else 0) | (if (target.activatable()) @as(u32, 1) else 0),
            .x = target.bounds.x,
            .y = target.bounds.y,
            .width = target.bounds.width,
            .height = target.bounds.height,
            .label = &target.label,
            .label_len = target.label_len,
        };
        if (target.action == .text_field) {
            const current = FieldView.captureClient(self.app, target.*) orelse continue;
            node.flags |= 8;
            node.actions |= 4 | 8 | 64 | 128 | 256 | 512;
            node.text_revision = FieldView.revision(self.app);
            node.value = current.text.ptr;
            node.value_len = current.text.len;
            node.selection_start = current.anchor;
            node.selection_end = current.head;
        }

        state.native_nodes[slot] = node;
        count = slot + 1;
    }

    output.* = .{ .revision = self.model.chrome.revision +% self.app.model.name_prompt.version() +% self.app.model.version().panes +% state.dispatcher.revision, .nodes = &state.native_nodes, .count = @intCast(count) };
    return count != 0;
}

fn endPaste(self: *GuiAdapter) !void {
    defer self.model.widgets.paste_owner = null;
    defer self.model.widgets.paste_consumed = false;
    const owner = self.model.widgets.paste_owner orelse return;
    const target = self.model.widgets.dispatcher.maps.presented().find(owner) orelse return;
    if (widget_routing.field(self.app, target)) |current| {
        if (FieldView.revision(self.app) == self.model.widgets.paste_revision) {
            const bytes = self.fitPaste(current, self.model.widgets.paste_selection, &self.model.widgets.paste_buffer);
            try widget_routing.focus(&self.model, self.app, target);
            try widget_routing.command(&self.model, self.app, .{ .replace_range = .{ .range = self.model.widgets.paste_selection, .text = bytes } });
        }
    }
}

fn continueFallback(self: *GuiAdapter, event: Window.Input) !bool {
    const key: keyinput.Key = switch (event) {
        .key => |value| if (value.phase == .press) return false else value.terminalKey(),
        .text => |value| blk: {
            if (value.phase == .press or value.physical == null or value.bytes.len == 0 or value.bytes.len > 4) {
                return false;
            }

            var result: keyinput.Key = .{
                .code = .{
                    .char = .{
                        .bytes = @splat(0),
                        .len = @intCast(value.bytes.len),
                    },
                },
                .phase = value.phase,
                .physical = value.physical,
            };
            @memcpy(result.code.char.bytes[0..value.bytes.len], value.bytes);
            break :blk result;
        },
        else => return false,
    };
    const physical = key.physical orelse return false;
    const owner = self.model.widgets.dispatcher.keys.owner(physical) orelse return false;
    if (owner != .fallback) {
        return false;
    }

    if (key.phase == .release) {
        _ = self.model.widgets.dispatcher.keys.release(physical);
    }

    _ = try self.routeKey(.{ .key = key, .now_ns = pacing.clock.monotonic(self.app.io) });
    return true;
}

fn editor(self: *GuiAdapter, target: Target, event: Window.Input) !void {
    if (event == .pointer and (event.pointer.button != .left or (event.pointer.kind != .press and event.pointer.kind != .drag))) {
        return;
    }

    if ((event == .key and event.key.phase == .release) or (event == .text and event.text.phase == .release)) {
        return;
    }

    if ((event == .key and event.key.phase == .repeat) or (event == .text and event.text.phase == .repeat)) {
        const focused = self.model.widgets.dispatcher.focused orelse return;
        if (!focused.eql(target.id)) {
            return;
        }
    }

    const current = widget_routing.field(self.app, target) orelse return;
    const state = &self.model.widgets;
    try widget_routing.focus(&self.model, self.app, target);
    switch (event) {
        .key => |key| {
            if (key.phase == .release) {
                return;
            }

            if (try self.shortcut(target, key)) {
                return;
            }

            if (key.mods.super) {
                return;
            }

            if (key.code == .escape and state.preedit.owner != null) {
                state.cancelComposition();
                state.dispatcher.revision +%= 1;
                return;
            }

            const revision = widget_routing.editingRevision(self.app);
            _ = try client.name_prompt.inputPrompt(
                self.app,
                .{
                    .key = key.terminalKey(),
                },
            );
            if (revision != widget_routing.editingRevision(self.app)) {
                state.cancelComposition();
            }
        },
        .text => |value| {
            if (value.phase == .release) {
                return;
            }

            const range = if (value.replacement_start != std.math.maxInt(u32)) [2]u32{ value.replacement_start, value.replacement_end } else if (state.preedit.owner != null and state.preedit.owner.?.eql(target.id)) state.preedit.replacement else current.selection();
            try widget_routing.command(&self.model, self.app, .{ .replace_range = .{ .range = range, .text = value.bytes } });
            state.cancelComposition();
            state.dispatcher.revision +%= 1;
        },
        .paste => |bytes| {
            var buffer: PasteBuffer = .{};
            buffer.append(bytes);
            const text = self.fitPaste(current, current.selection(), &buffer);
            try widget_routing.command(&self.model, self.app, .{ .replace_range = .{
                .range = current.selection(),
                .text = text,
            } });
        },
        .composition => |value| {
            state.preedit.update(target.id, .{ .composition = value, .current = current }) catch return;
            state.dispatcher.revision +%= 1;
        },
        .delete_surrounding => |value| {
            if (value.before > current.head or value.after > current.text.len - current.head) {
                return;
            }

            try widget_routing.command(&self.model, self.app, .{ .replace_range = .{ .range = .{ current.head - value.before, current.head + value.after }, .text = "" } });
            state.cancelComposition();
        },
        .pointer => |pointer| {
            if (pointer.button == .left and (pointer.kind == .press or pointer.kind == .drag)) {
                const geometry = state.editors.presented().find(target.id) orelse return;
                var copy: textfield.GenericField(4096) = .init(current.text);
                _ = copy.selectRange(.{ current.anchor, current.head });
                const visible = copy.view(geometry.columns);
                const column = @max(0, (pointer.x - geometry.bounds.x) / geometry.cell_width);
                var offset: u32 = @intCast(copy.scroll);
                var used: f64 = 0;
                var iterator: cellgrid.GraphemeIterator = .{ .bytes = visible.text };
                while (iterator.next()) |cluster| {
                    const width: f64 = @floatFromInt(cellgrid.text.measure(cluster.bytes));
                    if (column < used + width / 2) {
                        break;
                    }

                    used += width;
                    offset += @intCast(cluster.bytes.len);
                }

                const anchor = if (pointer.kind == .drag or pointer.mods & 1 != 0) current.anchor else offset;
                state.cancelComposition();
                try widget_routing.command(&self.model, self.app, .{ .select_range = .{ anchor, offset } });
            }
        },
        else => {},
    }
}

fn shortcut(self: *GuiAdapter, target: Target, key: widget_routing.Key) !bool {
    if (key.code == .backspace and key.mods.super and (widget_routing.historyPrompt(self.app) or widget_routing.machineList(self.app))) {
        if (key.phase == .press) {
            try widget_routing.command(&self.model, self.app, .remove_entry);
        }

        return true;
    }
    if (key.code != .char or key.code.char.len != 1 or (!key.mods.ctrl and !key.mods.super)) {
        return false;
    }

    const current = widget_routing.field(self.app, target) orelse return true;
    const selected = current.selection();
    const letter = std.ascii.toLower(key.code.char.bytes[0]);
    if (letter != 'a' and letter != 'c' and letter != 'x' and letter != 'v') {
        return false;
    }

    if (key.phase != .press) {
        return true;
    }

    switch (letter) {
        'a' => try widget_routing.command(&self.model, self.app, .select_all),
        'c' => if (selected[0] == selected[1] and widget_routing.historyPrompt(self.app)) try widget_routing.command(&self.model, self.app, .copy_entry) else self.requestClipboardWrite(current.text[selected[0]..selected[1]]) catch return true,
        'x' => {
            try self.beginCut(target, selected);
        },
        'v' => self.requestClipboardRead(target.id.target_id, target.id.generation) catch return true,
        else => unreachable,
    }

    return true;
}

fn showPreview(self: *GuiAdapter, action: Target.PreviewAction) void {
    switch (action) {
        .open => |id| self.previews.openModal(id),
        .close => self.previews.closeModal(),
        .hold => {},
    }
}

fn beginCut(self: *GuiAdapter, target: Target, range: [2]u32) !void {
    const current = widget_routing.field(self.app, target) orelse return;
    for (&self.model.widgets.pending_cuts) |*slot| {
        if (slot.* != null) {
            continue;
        }

        const request_id = self.requestClipboardWriteOwned(.{ .target_id = target.id.target_id, .generation = target.id.generation }, current.text[range[0]..range[1]]) catch return;
        slot.* = .{ .request_id = request_id, .owner = target.id, .range = range, .revision = FieldView.revision(self.app) };
        return;
    }
}

fn beginClipboardRead(self: *GuiAdapter, owner: Id) !void {
    const target = self.model.widgets.dispatcher.maps.presented().find(owner) orelse return;
    const current = widget_routing.field(self.app, target) orelse return;
    for (&self.model.widgets.pending_pastes) |*slot| {
        if (slot.* != null) {
            continue;
        }

        const request_owner: ClipboardOwner = .{ .target_id = owner.target_id, .generation = owner.generation };
        const request_id = try self.host.read(request_owner);
        slot.* = .{ .request_id = request_id, .owner = owner, .range = current.selection(), .revision = FieldView.revision(self.app) };
        self.model.widgets.dispatcher.revision +%= 1;
        native.telar_gui_wake(self.wake_fds[1]);
        return;
    }

    return error.HostRequestsFull;
}

fn finishWidgetPaste(self: *GuiAdapter, result: widget_routing.ClipboardResult) !void {
    const owner: Id = .{ .target_id = result.target_id, .generation = result.generation };
    for (&self.model.widgets.pending_pastes) |*slot| {
        const pending = slot.* orelse continue;
        if (pending.request_id != result.request_id or !pending.owner.eql(owner)) {
            continue;
        }

        slot.* = null;
        self.model.widgets.dispatcher.revision +%= 1;
        if (!self.model.widgets.dispatcher.window_focused) {
            return;
        }

        const focused = self.model.widgets.dispatcher.focused orelse return;
        const target = self.model.widgets.dispatcher.maps.presented().find(owner) orelse return;
        if (!focused.eql(owner) or !widget_routing.eligible(self.app, target) or pending.revision != FieldView.revision(self.app)) {
            return;
        }

        if (result.status != .success) {
            if (result.status == .too_large or result.status == .cancelled) {
                try client.notifications.publishNotificationNow(
                    self.app,
                    .{
                        .level = .warning,
                        .title = "Clipboard could not be pasted",
                        .message = if (result.status == .too_large) "The clipboard image or attachment storage exceeds its size limit." else "The clipboard image could not be read or saved.",
                    },
                );
            }

            return;
        }

        const current = widget_routing.field(self.app, target) orelse return;
        if (!current.validRange(pending.range)) {
            return;
        }

        var buffer: PasteBuffer = .{};
        buffer.append(result.text);
        const text = self.fitPaste(current, pending.range, &buffer);
        try widget_routing.command(&self.model, self.app, .{ .replace_range = .{
            .range = pending.range,
            .text = text,
        } });

        return;
    }
}

fn fitPaste(self: *GuiAdapter, current: FieldView, range: [2]u32, buffer: *const PasteBuffer) []const u8 {
    const pasted = buffer.text();
    const kept = current.fitting(range, pasted);
    if (buffer.overflow) {
        client.limit_reached.report(self.app, .{ .limit = PasteBuffer.limit });
    } else if (kept.len < pasted.len) {
        client.limit_reached.report(
            self.app,
            .{
                .limit = core.Limit.declare("gui.widgets.text_field_bytes", "field bytes", current.capacity),
                .requested = pasted.len - (range[1] -| range[0]) + current.text.len,
            },
        );
    }

    return kept;
}

fn collectLimitReachedAndNotify(self: *GuiAdapter, limit: core.LimitReach) void {
    const inbox_is_free = self.collected.count == 0;
    self.collected.add(limit);

    if (inbox_is_free) {
        self.inbox.wakeup.notify();
    }
}

fn settleActivity(self: *GuiAdapter) !void {
    const intent = self.pending_activity orelse return;
    const slot = switch (intent) {
        .focus_machine_agent, .peek_machine_agent => |target| target.slot,
        .open_machine_worktree => |target| target.slot,
        else => {
            self.clearActivity();
            return;
        },
    };
    if (slot >= client.Machines.capacity or !self.machines.shown(slot) or !self.machines.live[slot]) {
        self.clearActivity();
        return;
    }

    const app = &self.clients[slot];
    if (app.model.runtime_link.phase != .connected) {
        self.clearActivity();
        return;
    }

    switch (intent) {
        .focus_machine_agent, .peek_machine_agent => |target| if (target.resolve(&app.model) == null) {
            self.clearActivity();
            return;
        },
        .open_machine_worktree => |target| {
            if (self.machines.generation[slot] != target.machine_generation) {
                self.clearActivity();
                return;
            }

            const row = app.model.workspace_list_snapshot.worktree(target.worktree) orelse {
                self.clearActivity();
                return;
            };
            if (row.workspace != target.workspace) {
                self.clearActivity();
                return;
            }
        },
        else => unreachable,
    }

    if (self.model.input_queue.len != 0) {
        return;
    }

    if (self.app.presentation.active != null) {
        self.pending_machine = if (slot == self.machines.active) null else slot;
        return;
    }

    self.clearActivity();
    try self.select(slot);

    if (!app.model.request_lifecycle.tracker.isEmpty()) {
        self.pending_activity = intent;
        return;
    }

    switch (intent) {
        .focus_machine_agent => |target| _ = try client.agent_navigation.navigateAgent(app, target.key),
        .peek_machine_agent => |target| _ = try client.agent_peek.open(app, target.key),
        .open_machine_worktree => |target| _ = try client.workspace_handoff.selectWorkspace(app, .{ .workspace = target.workspace }),
        else => unreachable,
    }

    self.clearActivity();
}

fn select(self: *GuiAdapter, slot: u8) !void {
    const machines = &self.machines;
    if (slot == machines.active or !machines.shown(slot) or !machines.live[slot]) {
        return;
    }

    if (self.app.presentation.active != null) {
        self.pending_machine = slot;
        return;
    }

    self.pending_machine = null;
    try client.machine_presentation.hide(self.app);
    self.forgetMachineView();

    machines.active = slot;
    machines.revision +%= 1;
    self.app = &self.clients[slot];
    self.app.presentation.preparation_invalid = true;
    try client.machine_presentation.show(self.app);
    self.app.model.to_host.resume_input = true;
}

fn clearActivity(self: *GuiAdapter) void {
    if (self.pending_activity) |intent| {
        const slot: ?u8 = switch (intent) {
            .focus_machine_agent, .peek_machine_agent => |target| target.slot,
            .open_machine_worktree => |target| target.slot,
            else => null,
        };
        if (slot != null and self.pending_machine == slot) {
            self.pending_machine = null;
        }
    }

    self.pending_activity = null;
}

fn classifyWindowInputError(err: anyerror, limit: ?core.Limit) anyerror!core.LimitReach {
    if (!core.limit_reached.isLimitError(err)) {
        if (core.limit_reached.isSystemError(err)) {
            std.log.scoped(.limits).err("{s} failed on the host: {s}", .{ "window_input", @errorName(err) });
        }

        return err;
    }

    var reach = core.limit_reached.unnamed(err, "window_input");
    if (limit) |named| {
        reach.limit = named;
    }

    return reach;
}

fn notifyWake(fd: usize) void {
    native.telar_gui_wake(@intCast(fd));
}

const Unposted = struct {
    presented: ?PresentationResult = null,
    capture: ?data.Completion = null,
    focus: ?bool = null,
};
