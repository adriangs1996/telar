//! One native connection's shared model and disposable host resources.
const gui_event = @import("gui_event.zig");
const favicon_worker = @import("image/favicon_worker.zig");
const event_module = @import("input/event.zig");
const graphics_delivery = @import("graphics_delivery.zig");
const shared_model = @import("model");
const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const host_ports = @import("host_ports.zig");
const NativeLoop = @import("NativeLoop.zig");
const InputQueue = @import("InputQueue.zig");
const PointerState = @import("input/PointerState.zig");
const PointerSample = @import("input/PointerSample.zig");
const PointerCapture = @import("input/PointerCapture.zig");
const TerminalClipboard = @import("host/TerminalClipboard.zig");
const WidgetId = @import("widgets/interaction/Id.zig");
const Renderer = @import("render/TerminalRenderer.zig");
const native = @import("native/native.zig");
const selection = @import("render/copy_selection.zig");
const State = @import("widgets/interaction/State.zig");
const Chrome = @import("widgets/Chrome.zig");
const SyntaxService = @import("syntax/Service.zig");
const ReviewPanel = @import("change_review/Panel.zig");
const review_dispatch = @import("change_review/dispatch.zig");

const input_routing = @import("input/router.zig");
const widget_routing = @import("widgets/interaction/routing.zig");
const KeyInput = @import("input/KeyInput.zig");
const ClipboardResult = @import("input/ClipboardResult.zig");
const ScrollSample = @import("input/ScrollSample.zig");
const PointerEvent = @import("input/PointerEvent.zig");
const PasteChunk = @import("PasteChunk.zig");

const HostServices = @import("host/Services.zig");
const SidebarPreference = @import("SidebarPreference.zig");
const Overlays = @import("widgets/overlays/Overlays.zig");
const DiagramService = @import("diagrams/Service.zig");
const ClipboardOwner = @import("host/Owner.zig");
const CursorTarget = @import("CursorTarget.zig");
const Scene = @import("render/Scene.zig");
const message_links = @import("widgets/interaction/message_links.zig");
const thread_selection = @import("widgets/interaction/thread_selection.zig");
const thread_items = @import("widgets/interaction/thread_items.zig");
const thread_history = @import("widgets/interaction/thread_history.zig");
const thread_scroll = @import("widgets/interaction/thread_scroll.zig");
const host_context = @import("widgets/interaction/host_context.zig");

const FramePacer = @import("FramePacer.zig");
const CursorClock = @import("CursorClock.zig");
const FrameClock = @import("animation/FrameClock.zig");
const native_callbacks = @import("native/window_callbacks.zig");
const TestSession = @import("tests/Session.zig");
const input_test_support = @import("tests/input_support.zig");
const GuiClient = @This();

const InputLimit = enum(u8) {
    minimum_outbox_slots = 4,
    scroll_lines_per_event = 32,
};

const PipeEnd = enum(usize) { read, write };

const MouseMask = enum(u8) {
    button_and_modifiers = 0b0001_1111,
};

const TabDragStep = enum(u8) {
    logical_pixels = 4,
};

app: client.AttachedClient,
driver: NativeLoop,
renderer: Renderer,
failure: ?anyerror = null,
exit_status: ?u8 = null,
started: bool = false,
needs_draw: bool = false,
cursor_clock: CursorClock = .{},
observed_input_revision: u64 = 0,
window_title: client.WindowTitleState = .{},
hostname: [std.posix.HOST_NAME_MAX]u8 = undefined,
hostname_len: usize = 0,
input_queue: InputQueue = .{},
router: input_routing.Type,
binding_timeout: client.Scheduler = .{},
/// Replaces the time of noted pane input; pacing tests pin it so scheduler
/// delays cannot expire their grace.
pane_input_time: ?u64 = null,
binding_target: ?WidgetId = null,
binding_revision: u64 = 0,
pointer: PointerState = .{},
terminal_clipboard: TerminalClipboard = .{},
paste_route: enum { shared, widget } = .shared,
recovery_interactions_finished: bool = false,
stopped: bool = false,
host: HostServices = .{},
input_revision: u64 = 0,
focused: bool = true,
widgets: State = .{},
chrome: Chrome = .{},

/// The sidebar band width preference; the shared model keeps only visibility.
sidebar: SidebarPreference = .{},
overlays: Overlays = .{},
graphics_store: graphics_delivery.Store,
diagrams: DiagramService,
syntax: SyntaxService,
review: *ReviewPanel,

/// Recovers the native owner; `app` must be embedded in a live GuiClient.
/// Example: `const gui = GuiClient.of(app);`
pub fn of(app: *client.AttachedClient) *GuiClient {
    return @fieldParentPtr("app", app);
}

/// Adopts options on success and binds all ports before receiving messages.
/// Example: `const gui = try GuiClient.init(params);`
pub fn init(params: client.ClientInit) !*GuiClient {
    const router = try input_routing.build(
        .{
            .prefix = params.options.prefix,
            .bindings = params.options.bindings,
            .escape_timeout_ns = params.options.input_escape_timeout_ns,
            .sequence_timeout_ns = params.options.input_sequence_timeout_ns,
        },
    );

    const gui = try params.gpa.create(GuiClient);
    errdefer params.gpa.destroy(gui);

    const review = try params.gpa.create(ReviewPanel);
    errdefer params.gpa.destroy(review);

    gui.driver = try NativeLoop.init(params.io);
    errdefer gui.driver.deinit();
    gui.renderer = Renderer.init(params.gpa);
    gui.renderer.io = params.io;
    errdefer gui.renderer.deinit();
    gui.failure = null;
    gui.exit_status = null;
    gui.started = false;
    gui.needs_draw = false;
    gui.cursor_clock = .{
        .config = params.options.gui.cursor,
    };
    gui.observed_input_revision = 0;
    gui.window_title = .{};
    gui.hostname_len = 0;
    try client.AttachedClient.init(&gui.app, params);

    // Native chrome uses the shared semantic projection, never TUI Kitty output.
    gui.app.options.sidebar_renderer_locked = true;
    gui.driver.configuration.inbox = &gui.driver.inbox;
    gui.input_queue = .{};
    gui.router = router;
    gui.binding_timeout = .{};
    gui.binding_target = null;
    gui.binding_revision = 0;
    gui.pointer = .{};
    gui.terminal_clipboard = .{};
    gui.paste_route = .shared;
    gui.recovery_interactions_finished = false;
    gui.stopped = false;
    gui.host = .{};
    gui.input_revision = 0;
    gui.focused = true;
    gui.widgets = .{};
    gui.chrome = .{};
    gui.sidebar = .init(params.options.gui.sidebar.width);

    gui.overlays = .{
        .router = &gui.router,
    };

    gui.graphics_store = .init(params.gpa);
    gui.diagrams = .init(params.gpa);

    gui.syntax = .{
        .allocator = params.gpa,
    };

    gui.review = review;
    gui.review.* = .{
        .allocator = params.gpa,
    };

    gui.review.widget.host_port = &gui.host;
    gui.review.widget.widgets = &gui.widgets;

    gui.app.graphics = host_ports.graphicsRetention(&gui.app);
    gui.app.chrome = host_ports.chrome(&gui.app);
    gui.app.attachment_catalog = host_ports.attachmentCatalog(&gui.app);
    gui.app.attachment_shelf = host_ports.attachmentShelf(&gui.app);
    gui.app.workers = host_ports.workers(&gui.app);
    gui.app.host_input_source = host_ports.hostInput(&gui.app);

    return gui;
}

/// Call after native GPU consumers stop; joins workers before releasing resources. Example: `gui.deinit();`
pub fn deinit(self: *GuiClient) void {
    const gpa = self.app.gpa;
    self.driver.deinit();
    self.renderer.deinit();

    if (self.app.presentation.active) |flight| {
        _ = self.app.presentation.complete(flight.token, .cancelled);
    }

    self.graphics_store.deinit();
    self.diagrams.deinit();
    self.chrome.favicons.deinit(gpa);
    self.widgets.deinit();
    gpa.destroy(self.review);
    self.app.deinit();
    gpa.destroy(self);
}

/// Opens the native window after configuring its renderer; returns after GPU consumers stop.
/// Example: `const status = try gui.run("Telar");`
pub fn run(self: *GuiClient, title: [*:0]const u8) !u8 {
    const renderer = try Renderer.configured(
        self.app.gpa,
        self.app.io,
        .{
            .config = self.app.options.gui,
            .theme = self.app.options.theme.terminal,
        },
    );
    self.renderer.deinit();
    self.renderer = renderer;
    self.renderer.sidebar_request = self.sidebar.request(self.app.model.sidebar_visible);
    const hostname = std.posix.gethostname(&self.hostname) catch "";
    self.hostname_len = hostname.len;
    const callbacks = native_callbacks.bind(self);
    const result = native.telar_gui_run(
        title,
        self,
        &callbacks,
    );

    if (self.failure) |err| {
        return err;
    }

    if (result != 0) {
        return error.NativeWindowFailed;
    }

    return self.exit_status orelse 0;
}

/// Starts the runtime only after the native surface supplies usable geometry.
/// Repeated notifications do not repeat bootstrap or mutate an in-flight frame.
/// Example: `try gui.windowReady(viewport);`
pub fn windowReady(self: *GuiClient, viewport: native.Viewport) !void {
    if (self.started or self.failure != null or self.exit_status != null) {
        return;
    }

    _ = self.resizeViewport(viewport) catch |err| switch (err) {
        error.InvalidTerminalSize => return,
        else => return err,
    };
    try self.start(
        .{
            .foreground = self.renderer.theme.foreground,
            .background = self.renderer.theme.background,
            .palette = self.renderer.theme.palette,
        },
    );
}

/// Negotiates the current viewport against the owned renderer and shared model.
/// Example: `const size = try gui.resizeViewport(viewport);`
pub fn resizeViewport(self: *GuiClient, viewport: native.Viewport) !core.TerminalSize {
    if (self.app.presentation.active != null) {
        return error.PresentationBusy;
    }

    const size = try self.measure(&self.renderer, viewport);
    try self.resize(size, self.renderer.theme);
    self.pointer.configure(self.renderer.origin, size);
    return size;
}

/// Prepares one frame without starting the runtime. Native readiness owns startup.
/// Example: `const token = try gui.draw(viewport);`
pub fn draw(self: *GuiClient, viewport: native.Viewport) !u64 {
    core.profiling.add(.gui_draw, 1);
    const profile_started = core.profiling.start(self.app.io);
    defer core.profiling.finish(self.app.io, .gui_draw, profile_started);
    if (self.failure != null or self.exit_status != null) {
        return 0;
    }

    if (self.app.presentation.active != null) {
        return error.PresentationBusy;
    }

    self.driver.configuration.observe(self.renderer.config, viewport);

    if (try self.driver.configuration.apply(self, &self.renderer)) {
        self.cursor_clock.config = self.renderer.config.cursor;
        self.cursor_clock.reset(self.now());
    }

    _ = self.resizeViewport(viewport) catch |err| switch (err) {
        error.InvalidTerminalSize => return 0,
        else => return err,
    };

    const now_ns = self.now();
    self.cursor_clock.observe(self.cursorTarget(), now_ns);
    self.renderer.cursor_on = self.cursor_clock.shown(now_ns);
    self.renderer.focused = self.cursor_clock.focused;
    const token = try self.prepare(&self.renderer);

    if (token != 0) {
        self.driver.frame_pacer.record(self.app.presentation.active.?.delivery.commit.slice(), now_ns);
    }

    return token;
}

/// Admits native input once ready, retaining pre-start focus transitions.
/// Example: `_ = try gui.input(decoded);`
pub fn input(self: *GuiClient, event: event_module.Event) !bool {
    if (!self.started) {
        if (event == .focus) {
            try self.driver.inbox.post(
                .{
                    .focus = event.focus,
                },
            );
            return true;
        }

        return false;
    }

    core.mark(self.app.io, .client_input);
    return self.acceptInput(event);
}

/// Records the first window failure and wakes the native loop to close it.
/// Example: `gui.fail(err);`
pub fn fail(self: *GuiClient, err: anyerror) void {
    if (self.failure == null) {
        std.log.err(
            "native client: {s}",
            .{
                @errorName(err),
            },
        );
        self.failure = err;
    }

    native.telar_gui_wake(self.driver.fds[1]);
}

fn now(self: *const GuiClient) u64 {
    return @intCast(@max(0, std.Io.Clock.awake.now(self.app.io).toNanoseconds()));
}

/// Reports the next cursor or widget animation wake without advancing either.
/// Example: `const delay = gui.wakeupAfter();`
pub fn wakeupAfter(self: *const GuiClient) u32 {
    const now_ns = self.now();
    const widgets = if (self.app.presentation.active == null) self.chrome.animation.wakeupAfter(now_ns) else 0;
    return FrameClock.earliest(self.cursor_clock.wakeupAfter(now_ns), widgets);
}

/// Reports native frame admission delay from visible terminal frame identities.
/// Example: `const delay_ns = gui.frameDelayNs();`
pub fn frameDelayNs(self: *GuiClient) u64 {
    var visible: [core.max_panes_per_tab]FramePacer.Pane = undefined;
    var count: usize = 0;
    const model = &self.app.model;
    if (model.tabs.activeSlot()) |tab| {
        var layout: shared_model.LayoutSnapshot = .{};
        model.tabs.layout[tab].snapshot(shared_model.workbench.region(&self.app.model).area, &layout);
        for (layout.views()) |view| {
            if (view.surface != .terminal or view.content.w == 0 or view.content.h == 0) {
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

    const now_ns = self.now();
    const deadline = self.driver.frame_pacer.waitUntil(visible[0..count], now_ns) orelse return 0;
    return deadline -| now_ns;
}

/// Copies a changed title into native-owned output storage.
/// Example: `const changed = try gui.windowTitle(out);`
pub fn windowTitle(self: *GuiClient, out: *native.WindowTitle) !bool {
    out.* = .{};
    const model = &self.app.model;
    const tab_label = if (model.tabs.activeSlot()) |tab| shared_model.tab_label.text(model, tab) else "";
    return self.window_title.sync(
        .{
            .context = out,
            .set = copyWindowTitle,
        },
        .{
            .template = model.windowTitleTemplate(),
            .tokens = .{
                .workspace = model.workspaceName(),
                .tab = tab_label,
                .pane_title = model.focusedPaneTitle(),
                .hostname = self.hostname[0..self.hostname_len],
            },
        },
    );
}

fn copyWindowTitle(context: *anyopaque, title: []const u8) !void {
    const out: *native.WindowTitle = @ptrCast(@alignCast(context));
    if (title.len >= out.bytes.len) {
        return error.WindowTitleTooLong;
    }

    @memcpy(out.bytes[0..title.len], title);
    out.bytes[title.len] = 0;
    out.len = @intCast(title.len);
}

/// Publishes native capabilities and starts runtime I/O and configuration tasks.
/// Example: `try gui.start(colors);`
fn start(self: *GuiClient, colors: core.TerminalColors) !void {
    var capabilities = self.app.model.host.host_capabilities;

    capabilities.terminal_colors = colors;
    capabilities.images = .unsupported;
    capabilities.pointer_pixels = .supported;
    capabilities.agent_panes = true;

    _ = try self.app.applyHostUpdate(
        .{
            .size = self.app.model.host.host_size,
            .capabilities = capabilities,
        },
    );

    self.app.model.startup.phase = .opening;

    try self.app.runtime_transport.bootstrap(
        .{
            .graphics_shared = false,
            .client_identity = self.app.client_identity,
            .terminal_colors = colors,
        },
    );

    try self.app.startRuntimeIo();
    try self.app.scheduleConfigReload();
    try self.app.synchronizeBars();
    self.started = true;
}

/// Copies borrowed input before the host callback returns. A full input queue
/// rejects admission; inbox failures propagate to the host. Example: `_ = try gui.acceptInput(event);`
pub fn acceptInput(self: *GuiClient, event: event_module.Event) !bool {
    if (event == .focus) {
        // Focus transitions must remain ordered even when native input coalesces.
        try self.driver.inbox.post(
            .{
                .focus = event.focus,
            },
        );

        return true;
    }

    const admission = self.input_queue.accept(
        event,
        .{
            .geometry_revision = self.pointer.revision,
            .gesture_revision = self.pointer.gesture_revision,
        },
    ) catch return false;

    if (admission == .recovery) {
        self.pointer.invalidateGestures();
    }

    try self.driver.inbox.notify(.input_ready);

    return true;
}

/// Drains one bounded turn, then folds reconnectable layout state once.
/// Workers only publish owned messages; the window thread owns mutation.
/// Example: `const status = try gui.update();`
pub fn update(self: *GuiClient) !?u8 {
    core.profiling.add(.gui_update, 1);
    const loop = &self.driver;
    const status: ?u8 = turn: {
        var batch = try loop.inbox.begin();
        defer loop.inbox.end();

        while (try loop.inbox.next(&batch)) |event| {
            const path = core.enter(pathFor(event));
            defer path.restore();

            const exit_status = try self.dispatch(event);
            try self.deliverHostEffects();
            if (exit_status) |value| {
                break :turn value;
            }
        }

        if (batch.processed != 0) {
            try self.app.synchronizeClientLayout();
        }

        try loop.configuration.poll(&self.app);
        try self.deliverHostEffects();

        break :turn null;
    };

    self.refreshPointer();
    self.exit_status = status;
    const now_ns = self.now();
    if (self.observed_input_revision != self.input_revision) {
        self.observed_input_revision = self.input_revision;
        self.cursor_clock.focused = self.focused;
        self.cursor_clock.reset(now_ns);
    }

    self.cursor_clock.observe(self.cursorTarget(), now_ns);
    _ = self.app.presentation.observe(self.observation());
    self.needs_draw = false;
    if (self.app.presentation.active == null) {
        const animation_due = self.chrome.animation.requestPreparation(now_ns);
        self.needs_draw = self.app.presentation.needsPreparation() or animation_due or
            self.driver.configuration.pending or
            self.renderer.cursor_on != self.cursor_clock.shown(now_ns) or
            self.renderer.focused != self.cursor_clock.focused;
    }

    return status;
}

fn dispatch(self: *GuiClient, event: gui_event.Message) !?u8 {
    core.profiling.add(.gui_dispatch, 1);
    switch (event) {
        .client => |message| {
            if (try self.app.update(message)) |status| {
                return status;
            }

            if (message == .server) {
                try self.resumeAfterRuntime();
            }
        },
        .input_ready => try self.inputReady(),
        .focus => |focused| try self.focus(focused),
        .presented => |result| try self.complete(result.token, result.delivered),
        .configuration_ready => try self.driver.configuration.accept(&self.app),
        .binding_timeout => |result| try self.expireBinding(result),
        .favicon => |result| self.landFavicon(result),
        .diagram_ready => self.landDiagram(),
        .syntax_ready => self.landSyntax(),
        .change_review_ready => self.landChangeReview(),
    }

    return if (self.stopped) @as(u8, 0) else null;
}

fn pathFor(event: gui_event.Message) core.Path {
    return switch (event) {
        .client => |message| message.path(),
        .configuration_ready,
        .favicon,
        .diagram_ready,
        .syntax_ready,
        .change_review_ready,
        => .observation,
        else => .interactive,
    };
}

/// Finishes startup and resumes input once a runtime message lands.
fn resumeAfterRuntime(self: *GuiClient) !void {
    if (self.app.model.startup.phase == .opening and self.app.model.activeTabLocation() != null) {
        self.app.model.startup.phase = .active;
    }

    try self.resumeInput();
    self.refreshPointer();
}

/// Consumes bounded native input and schedules another turn if it can advance.
fn inputReady(self: *GuiClient) !void {
    if (self.input_queue.len != 0) {
        self.input_revision +%= 1;
        try self.drainInput();
        try self.resumeInput();
    }
}

/// Adopts bindings and retires the deadline of the previous keymap.
/// Replaces bindings without transferring held keys to their new meanings.
/// Example: `gui.adoptBindings(config);`
pub fn adoptBindings(self: *GuiClient, config: client.RouterConfig) void {
    var replacement = input_routing.build(config) catch unreachable;

    replacement.inheritPhysicalLeases(&self.router);
    self.router = replacement;
    self.binding_target = null;
    self.binding_revision +%= 1;
    _ = self.binding_timeout.update(self.app.io, null);
}

/// Cancels a partial chord and its original widget before input changes owner.
/// Held physical keys retain their leases. Example: `gui.cancelBinding();`
pub fn cancelBinding(self: *GuiClient) void {
    self.router.cancelSequence();
    self.binding_target = null;
}

fn statusMode(self: *const GuiClient) client.Mode {
    if (!self.router.prefixPending()) {
        return if (self.app.copyModeActive()) .copy else .normal;
    }

    var hints: client.Hints = .{};
    const actions = [_]shared_model.actions.Action{
        .{
            .split_pane = .horizontal,
        },
        .{
            .split_pane = .vertical,
        },
        .new_tab,
        .new_workspace,
        .rename_tab,
        .rename_workspace,
        .close_pane,
        .enter_copy_mode,
    };

    const labels = [_][]const u8{
        "split right",
        "split down",
        "new tab",
        "new workspace",
        "rename tab",
        "rename workspace",
        "close pane",
        "copy mode",
    };

    for (actions, labels) |action, label| {
        const key = self.router.prefixedKeyForAction(action) orelse continue;
        hints.append(
            .{
                .key = key,
                .label = label,
            },
        );
    }

    return .{
        .prefix = hints,
    };
}

/// Stops before the shared outbox fills, resuming on transport completion.
fn drainInput(self: *GuiClient) !void {
    core.profiling.add(.gui_input_drain, 1);
    const app = &self.app;
    const pending_input = &self.input_queue;

    if (app.model.startup.holdsInput()) {
        return;
    }

    var budget = client.DrainBudget.begin(app.io, pending_input.len + pending_input.recovery.len);
    const pending = self.router.prefixPending();

    while (!self.stopped and pending_input.len != 0 and app.runtime_transport.outbox.availableCapacity() >= @intFromEnum(InputLimit.minimum_outbox_slots) and budget.take(app.io)) {
        const overflows = self.router.leaseOverflowCount();

        switch (pending_input.front().?.*) {
            .key => |key| try self.dispatchKey(key),
            .text => |*text| {
                if (!try self.widgetInput(
                    .{
                        .text = text.text(),
                    },
                )) {
                    _ = try self.routeKey(
                        .{
                            .key = text.key(),
                            .raw = "",
                            .now_ns = client.monotonic(app.io),
                        },
                    );
                }
            },
            .paste_start => {
                _ = try self.applyInputDecision(self.router.interrupt());
                self.paste_route = if (try self.beginWidgetPaste()) .widget else .shared;

                if (self.paste_route == .shared) {
                    _ = try client.operations.paste_routing.start(app);
                }
            },
            .paste_text => |*chunk| {
                if (self.paste_route == .widget) {
                    try self.widgetPaste(chunk.bytes[0..chunk.len]);
                } else {
                    _ = try client.operations.paste_routing.content(app, chunk.bytes[0..chunk.len]);
                }
            },
            .paste_finish => {
                if (self.paste_route == .widget) {
                    try self.endWidgetPaste();
                } else {
                    _ = try client.operations.paste_routing.finish(app);
                }

                self.paste_route = .shared;
            },
            .release_recovery => {
                if (!self.recovery_interactions_finished) {
                    try self.releasePointer();
                    self.chrome.cancelPointer();
                    self.overlays.cancelPointer();
                    _ = try self.widgetInput(
                        .{
                            .focus = false,
                        },
                    );
                    _ = try self.widgetInput(
                        .{
                            .focus = self.focused,
                        },
                    );
                    self.pointer.scroll_remainder = 0;
                    self.recovery_interactions_finished = true;

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

                self.recovery_interactions_finished = false;
            },
            .pointer => |event| {
                if (event.event.interruptsKeys()) {
                    self.cancelBinding();
                }

                if (event.event.retained() or (event.geometry_revision == self.pointer.revision and event.gesture_revision == self.pointer.gesture_revision)) {
                    if (try self.widgetInput(
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
                _ = try self.widgetInput(pending_input.small_events.view(index));
            },
            .composition_cancel => |value| _ = try self.widgetInput(
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

        app.telemetry.metrics.key_lease_overflows +%= self.router.leaseOverflowCount() -% overflows;
        pending_input.consume();
    }

    try self.finishInput(pending);
}

/// Resolve and execute one semantic key before accepting the next event.
/// Example: `_ = try gui.routeKey(event);`
pub fn routeKey(self: *GuiClient, event: input_routing.Type.KeyInput) !shared_model.keybind.Control {
    errdefer self.router.eventFailed(event.key);

    defer {
        if (self.router.bindingDeadline() == null and !self.router.prefixPending()) {
            self.binding_target = null;
        }
    }

    const decision = self.router.routeEvent(
        event,
        .{
            .captures_keys = shared_model.key_routing.captures(self.app.keyRoutingAuthority()),
            .repeat_policy = if (self.router.repeatAction()) |held| client.repeatPolicy(held, self.app.repeatPane()) else null,
        },
    );

    const control = try self.applyInputDecision(decision);
    self.stopped = control == .stop;

    return control;
}

fn applyInputDecision(self: *GuiClient, decision: input_routing.Type.Decision) !shared_model.keybind.Control {
    switch (decision) {
        .forward => |value| {
            _ = try self.app.routeKeyInput(
                .{
                    .key = value.key,
                },
            );
        },
        .replay => |value| {
            for (value.held_keys[0..value.held_key_len]) |held| {
                try self.deliverKey(held);
            }

            if (value.current_key) |current| {
                if (shared_model.key_routing.captures(self.app.keyRoutingAuthority())) {
                    _ = try self.app.routeKeyInput(
                        .{
                            .key = current,
                        },
                    );
                } else {
                    try self.deliverKey(current);
                }
            }
        },
        .action => |request| {
            const control = try self.executeAction(request.value);

            if (control == .continue_routing) {
                self.router.actionCompleted(request, client.repeatPolicy(request.value, self.app.repeatPane()));
            }

            return control;
        },
        .pending, .discard => {},
    }

    return .continue_routing;
}

fn deliverKey(self: *GuiClient, value: shared_model.Key) !void {
    if (self.binding_target) |owner| {
        if (value.phase == .press) {
            try widget_routing.replayBindingKey(
                self,
                owner,
                value,
            );

            return;
        }
    }

    _ = try self.app.routeKeyInput(
        .{
            .key = value,
        },
    );
}

/// Agent scrolling uses delivered transcript geometry. The goto and suggest
/// keys open the native palette already prefixed, and sidebar resize uses
/// this window's pixel preference. Other actions keep the shared routing.
/// Copy mode retires first, as the shared native action policy does.
fn executeAction(self: *GuiClient, value: shared_model.actions.Action) !shared_model.keybind.Control {
    if (value == .scroll_pane) {
        if (try widget_routing.scrollFocusedThread(self, value.scroll_pane)) {
            return .continue_routing;
        }
    }

    const prefix: shared_model.command_palette.Prefix = switch (value) {
        .goto_picker => .goto,
        .suggest_command => .suggest,
        .resize_sidebar => |direction| {
            _ = try self.app.leaveCopyMode();

            if (self.sidebar.step(direction)) {
                self.chrome.invalidate();
            }

            return .continue_routing;
        },
        else => return self.app.executeAction(value, .binding),
    };

    if (self.app.copyModeActive()) {
        _ = try self.app.leaveCopyMode();
    }

    _ = self.app.beginCommandPalette(prefix);

    return .continue_routing;
}

fn dispatchKey(self: *GuiClient, key: KeyInput) !void {
    if (try self.widgetInput(
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

    if (key.mods.super or key.target_id != 0) {
        return;
    }

    _ = try self.routeKey(
        .{
            .key = key.terminalKey(),
            .raw = "",
            .now_ns = client.monotonic(self.app.io),
        },
    );
}

/// Repeated requests share one outstanding transfer. Example: `try gui.readTerminalClipboard();`
fn readTerminalClipboard(self: *GuiClient) !void {
    const clipboard = &self.terminal_clipboard;

    if (clipboard.request_id != 0 or self.app.model.name_prompt.active() or self.app.model.copyModeActive()) {
        return;
    }

    const tab = self.app.model.tabs.activeSlot() orelse return;
    const pane = shared_model.tab_layout.focusedPaneConst(&self.app.model, tab) orelse return;
    clipboard.request_id = try self.host.read(
        .{
            .generation = pane.attachment_generation,
        },
    );
    clipboard.pane_id = pane.id;
    clipboard.generation = pane.attachment_generation;
    native.telar_gui_wake(self.driver.fds[@intFromEnum(PipeEnd.write)]);
}

/// Completes once, discarding a response whose original attachment is no
/// longer the focused terminal. Example: `if (gui.takeTerminalClipboard(result)) startPaste();`
fn takeTerminalClipboard(self: *GuiClient, result: ClipboardResult) bool {
    const clipboard = &self.terminal_clipboard;

    if (result.request_id != clipboard.request_id) {
        return false;
    }

    defer clipboard.request_id = 0;

    if (result.status != .success or result.target_id != 0 or result.generation != clipboard.generation or self.app.model.name_prompt.active() or self.app.model.copyModeActive() or !self.focused) {
        return false;
    }

    const tab = self.app.model.tabs.activeSlot() orelse return false;
    const pane = shared_model.tab_layout.focusedPaneConst(&self.app.model, tab) orelse return false;

    return pane.id == clipboard.pane_id and pane.attachment_generation == clipboard.generation;
}

fn dispatchClipboard(self: *GuiClient, result: ClipboardResult) !bool {
    if (self.terminal_clipboard.offset == null) {
        const kind = self.host.complete(result) orelse return true;

        if (kind == .write) {
            if (self.widgets.copy_feedback.complete(result, client.monotonic(self.app.io))) {
                self.widgets.dispatcher.revision +%= 1;
            }

            if (result.target_id != 0) {
                var completion = result;
                completion.operation = .write;
                _ = try self.widgetInput(
                    .{
                        .clipboard = completion,
                    },
                );
            }

            return true;
        }

        if (result.target_id != 0) {
            _ = try self.widgetInput(
                .{
                    .clipboard = result,
                },
            );

            return true;
        }

        if (!self.takeTerminalClipboard(result)) {
            return true;
        }

        _ = try self.applyInputDecision(self.router.interrupt());
        _ = try self.app.startPanePaste();
        self.terminal_clipboard.offset = 0;

        return false;
    }

    const offset = self.terminal_clipboard.offset.?;

    if (offset < result.text.len) {
        const count = PasteChunk.nextSize(result.text[offset..]);
        _ = try self.app.appendPanePaste(result.text[offset..][0..count]);
        self.terminal_clipboard.offset = offset + count;

        return false;
    }

    _ = try self.app.finishPanePaste();
    self.terminal_clipboard.offset = null;

    return true;
}

/// New gestures require current physical geometry; child drags keep their
/// original pane while copy-mode and chrome retain their own owners.
fn dispatchPointer(self: *GuiClient, value: PointerSample) !void {
    const app = &self.app;
    const pointer = &self.pointer;

    const event = value.event;

    if (event.kind == .leave) {
        pointer.hover.clear();
        pointer.link_gesture.cancel();
        self.chrome.leavePointer();

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

    if (event.kind == .move and pointer.owners[@intFromEnum(PointerEvent.Button.left)] == .link) {
        pointer.link_gesture.validate(pointer.hover.link, app.model.version());

        return;
    }

    const begins = event.kind == .press or event.kind == .scroll_up or event.kind == .scroll_down;

    if (begins and (value.gesture_revision != pointer.gesture_revision or !self.pointerGeometryMatches())) {
        return;
    }

    // Chrome bands lie outside the cell grid: a sample the grid does not
    // resolve goes to the delivered band targets, and a band gesture keeps
    // its drag and release even over cells.
    const resolved = if (self.chrome.band_gesture != null) null else pointer.geometry.resolve(event);
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
                    pointer.hover.dirty = true;
                    pointer.hover.refresh(self);
                    const target = if (self.pointerGeometryMatches() and pointer.hover.openable()) pointer.link_gesture.finish(pointer.hover.link, app.model.version()) else null;
                    pointer.link_gesture.cancel();

                    if (target) |selected| {
                        _ = try app.openLink(selected);
                    }
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

    const outcome = try client.operations.pointer_routing.apply(app, mouse);

    if (event.interruptsKeys()) {
        pointer.hover.dirty = true;
    }

    if (event.kind == .press) {
        pointer.owners[button] = switch (outcome) {
            .view, .copy_mode => .shared,
            .link => if (event.button == .right) .discarded else .link,
            .unavailable => .discarded,
            .pane => pane: {
                if (app.model.pointerSelection()) |pointer_selection| {
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
    }
}

fn dispatchBandPointer(self: *GuiClient, event: PointerEvent) !void {
    const app = &self.app;
    const command = self.chrome.bandPointer(event) orelse {
        if (event.kind == .move) {
            self.chrome.leavePointer();
        }

        return;
    };

    const covered = app.model.name_prompt.active() or self.overlays.presented().modal != null;

    if (covered) {
        return;
    }

    if (command.sidebar_width) |width| {
        self.adoptSidebarWidth(width);

        return;
    }

    const tab = app.model.tabs.activeSlot() orelse return;
    _ = try client.operations.view_interactions.apply(
        app,
        tab,
        command.interaction,
    );
}

/// Closes existing gestures on focus loss, without assigning their releases
/// to chrome or to a pane that happens to be focused. Example: `try gui.releasePointer();`
fn releasePointer(self: *GuiClient) !void {
    const app = &self.app;
    const pointer = &self.pointer;

    pointer.hover.clear();
    pointer.link_gesture.cancel();
    defer pointer.owners = @splat(.shared);

    for (&pointer.owners, pointer.last) |*owner, last| {
        switch (owner.*) {
            .child => |*capture| {
                var released = last;
                released.kind = .release;
                released.button &= @intFromEnum(MouseMask.button_and_modifiers);
                try capture.deliver(app, released);
            },
            .link => {},
            .shared, .discarded => {},
        }
    }

    if (app.model.pointerSelection()) |pointer_selection| {
        if (pointer_selection.dragging) {
            if (app.model.tabs.activeSlot()) |tab| {
                var released = pointer.last[@intFromEnum(PointerEvent.Button.left)];
                released.kind = .release;
                released.button = @intFromEnum(PointerEvent.Button.left);
                _ = try client.operations.copy_mode_pointer.apply(
                    app,
                    tab,
                    released,
                );
            }
        }
    }
}

/// New widget and terminal gestures share the same delivered geometry guard.
/// Example: `const current = gui.pointerGeometryMatches();`
pub fn pointerGeometryMatches(self: *const GuiClient) bool {
    const app = &self.app;
    const delivered = app.presentation.delivered_geometry orelse return false;
    const snapshot = client.capture(
        &app.model,
        .{
            .geometry = app.geometry(),
        },
    );
    const current = client.Geometry.capture(snapshot);

    return delivered.matches(&current);
}

fn dispatchScroll(self: *GuiClient, sample: *ScrollSample) !bool {
    if (sample.geometry_revision != self.pointer.revision or sample.gesture_revision != self.pointer.gesture_revision) {
        self.pointer.scroll_remainder = 0;

        return true;
    }

    const event = sample.event;

    if (!sample.started) {
        if (try self.widgetInput(
            .{
                .scroll = event,
            },
        )) {
            self.pointer.scroll_remainder = 0;

            return true;
        }

        if (event.phase == .begin or event.phase == .cancel) {
            self.pointer.scroll_remainder = 0;
        }

        if (event.phase == .cancel) {
            return true;
        }

        const unit: f64 = if (event.precise) @floatFromInt(@max(1, self.pointer.geometry.size.cell_height_px)) else 1;
        const line_limit: f64 = @intFromEnum(InputLimit.scroll_lines_per_event);

        self.pointer.scroll_remainder += std.math.clamp(
            event.delta_y / unit,
            -line_limit,
            line_limit,
        );
        sample.lines = @intFromFloat(std.math.clamp(
            @trunc(self.pointer.scroll_remainder),
            -line_limit,
            line_limit,
        ));
        self.pointer.scroll_remainder -= @floatFromInt(sample.lines);
        sample.started = true;
    }

    if (sample.lines == 0) {
        return true;
    }

    const pointer: PointerEvent = .{
        .kind = if (sample.lines < 0) .scroll_up else .scroll_down,
        .mods = event.mods,
        .x = event.x,
        .y = event.y,
    };

    self.cancelBinding();
    try self.dispatchPointer(self.pointer.sample(pointer));
    sample.lines += if (sample.lines < 0) @as(i8, 1) else -1;

    return sample.lines == 0;
}

fn finishInput(self: *GuiClient, pending: bool) !void {
    const app = &self.app;

    if (self.router.bindingDeadline() == null and !self.router.prefixPending()) {
        self.binding_target = null;
    }

    if (pending != self.router.prefixPending()) {
        self.binding_revision +%= 1;
    }

    if (self.binding_timeout.update(app.io, self.router.bindingDeadline()) == .schedule) {
        self.driver.inbox.start(.binding_timeout, .{ client.wait, .{ app.io, &self.binding_timeout } }) catch |err| {
            self.binding_timeout.schedulingFailed();

            return err;
        };
    }
}

/// Reserves one control slot to finish gestures even when ordinary input is
/// saturated. Example: `try gui.cancelPointer();`
fn cancelPointer(self: *GuiClient) !void {
    const pending_input = &self.input_queue;

    self.pointer.invalidateGestures();
    pending_input.requestRecovery();
    try self.drainInput();
    try self.resumeInput();
}

fn expireBinding(self: *GuiClient, result: anyerror!void) !void {
    const app = &self.app;

    try self.binding_timeout.complete(result);
    const pending = self.router.prefixPending();
    self.stopped = try self.applyInputDecision(self.router.expireBinding(client.monotonic(app.io))) == .stop;
    try self.finishInput(pending);
}

/// A clipboard response retains the widget that requested it across focus
/// changes. Example: `try gui.requestClipboardRead(id, generation);`
pub fn requestClipboardRead(self: *GuiClient, target_id: u64, generation: u64) !void {
    try widget_routing.beginClipboardRead(
        self,
        .{
            .target_id = target_id,
            .generation = generation,
        },
    );
}

/// Copies selected UTF-8 before the native host drains the request.
/// Example: `try gui.requestClipboardWrite(selection);`
/// Lets the frame pacer hurry the frame that echoes input to a visible pane.
fn notePaneInput(self: *GuiClient, pane_id: core.PaneId, at_ns: u64) void {
    const model = &self.app.model;
    const tab = model.tabs.activeSlot() orelse return;
    const pane = model.panes.findInConst(model.tabs.location[tab].tab_id, pane_id) orelse return;
    self.driver.frame_pacer.noteInput(.{
        .pane_id = pane.id,
        .attachment_generation = pane.attachment_generation,
        .frame_id = pane.applied_frame_id,
        .attached = pane.attached,
    }, at_ns);
}

/// Delivers the host requests the shared client left in `model.to_host`.
/// The window has no outer terminal and no media capture, and it redraws
/// every image placement each frame.
fn deliverHostEffects(self: *GuiClient) !void {
    const effects = &self.app.model.to_host;
    _ = effects.takePlacementInvalidation();
    if (effects.rebind_input) {
        effects.rebind_input = false;
        self.adoptBindings(self.app.routerConfig());
    }

    if (effects.resume_input) {
        effects.resume_input = false;
        try self.resumeInput();
    }

    if (effects.pane_input) |pane_input| {
        effects.pane_input = null;
        self.notePaneInput(pane_input.pane_id, self.pane_input_time orelse pane_input.at_ns);
    }

    while (effects.pop()) |effect| {
        switch (effect) {
            .clipboard => self.requestClipboardWrite(effects.clipboard.items) catch |err| switch (err) {
                error.HostRequestsFull, error.ClipboardTooLarge, error.InvalidUtf8 => std.log.warn("native clipboard update was not admitted: {s}", .{@errorName(err)}),
                else => return err,
            },
            .terminal_notification => {},
            .capture => |request| try self.app.completeClipboardCapture(.{
                .execution_id = @enumFromInt(request.sequence),
                .result = error.NativeServiceUnavailable,
            }),
        }
    }
}

pub fn requestClipboardWrite(self: *GuiClient, bytes: []const u8) !void {
    _ = try self.host.write(bytes);
    native.telar_gui_wake(self.driver.fds[@intFromEnum(PipeEnd.write)]);
}

/// Requests a link copy with a bottom confirmation after host success.
/// Example: `try gui.copyLink(destination);`
pub fn copyLink(self: *GuiClient, bytes: []const u8) !void {
    self.widgets.copy_feedback.pending = try self.requestClipboardWriteOwned(
        .{},
        bytes,
    );
}

/// The editor can commit a cut only after the matching native write succeeds.
/// Example: `const request = try gui.requestClipboardWriteOwned(owner, bytes);`
pub fn requestClipboardWriteOwned(self: *GuiClient, owner: ClipboardOwner, bytes: []const u8) !u64 {
    const request = try self.host.writeOwned(owner, bytes);
    native.telar_gui_wake(self.driver.fds[@intFromEnum(PipeEnd.write)]);

    return request;
}

fn focus(self: *GuiClient, focused: bool) !void {
    self.focused = focused;

    if (!focused) {
        self.widgets.thread_scroll.clear();
        self.widgets.tab_drag.cancel();
        message_links.clear(self);
        thread_selection.cancel(self);
    }

    self.input_revision +%= 1;
    _ = self.widgets.dispatcher.route(
        .{
            .focus = focused,
        },
    );

    if (!focused) {
        self.widgets.preedit.clear();
    }

    if (!focused) {
        self.pointer.hover.clear();
        self.pointer.link_gesture.cancel();
        self.chrome.cancelPointer();
        self.overlays.cancelPointer();
        try self.cancelPointer();
    }
}

/// Queue one readiness notification only when input can make progress.
/// Example: `try gui.resumeInput();`
pub fn resumeInput(self: *GuiClient) !void {
    if (self.input_queue.len != 0 and !self.app.model.startup.holdsInput() and self.app.runtime_transport.outbox.availableCapacity() >= @intFromEnum(InputLimit.minimum_outbox_slots)) {
        try self.driver.inbox.notify(.input_ready);
    }
}

/// Copies the visible cursor identity for the native blink clock.
/// Example: `clock.observe(gui.cursorTarget(), now_ns);`
fn cursorTarget(self: *const GuiClient) CursorTarget {
    if (self.app.model.name_prompt.active()) {
        return .{};
    }

    const tab = self.app.model.tabs.activeSlot() orelse return .{};
    const pane = shared_model.tab_layout.focusedPaneConst(&self.app.model, tab) orelse return .{};
    const copy = self.app.model.copyModeProjection();
    const copy_view: ?shared_model.CopyModeView = if (copy) |value| if (value.pane_id == pane.id) value.view else null else null;
    const cursor = selection.cursor(pane, copy_view);
    var layout: shared_model.LayoutSnapshot = .{};

    self.app.model.tabs.layout[tab].snapshot(shared_model.workbench.region(&self.app.model).area, &layout);

    for (layout.views()) |view| {
        if (view.pane_id == pane.id and view.surface == .terminal and cursor.x < view.content.w and cursor.y < view.content.h) {
            return .{
                .pane_id = pane.id,
                .generation = pane.attachment_generation,
                .cursor = cursor,
            };
        }
    }

    return .{};
}

/// Measures the window with the shared sidebar visibility and this window's
/// width preference, then retains the band the renderer resolved so the
/// next keyboard step or drag clamps to it. The caller still negotiates the
/// PTY with `resize`.
/// Example: `const size = try gui.measure(&renderer, viewport);`
fn measure(self: *GuiClient, renderer: *Renderer, viewport: native.Viewport) !core.TerminalSize {
    const viewport_changed = !std.meta.eql(
        renderer.viewport,
        [2]u32{
            viewport.width,
            viewport.height,
        },
    ) or renderer.scale != viewport.scale;
    renderer.sidebar_request = self.sidebar.request(self.app.model.sidebar_visible);
    const size = try renderer.measure(viewport);

    if (viewport_changed or !std.meta.eql(size, self.app.model.host.host_size) or self.widgets.tab_drag_step != renderer.chrome.px(@intFromEnum(TabDragStep.logical_pixels))) {
        self.widgets.tab_drag.cancel();
    }

    self.sidebar.observe(renderer.sidebar);

    return size;
}

/// Applies a dragged or stepped sidebar width: the preference changes and
/// the next preparation measures the grid again.
/// Example: `gui.adoptSidebarWidth(command.sidebar_width.?);`
pub fn adoptSidebarWidth(self: *GuiClient, width: u32) void {
    if (self.sidebar.drag(width)) {
        self.chrome.invalidate();
    }
}

/// Publishes exact font metrics and lets shared geometry negotiate the PTY.
/// Example: `try gui.resize(size, renderer.theme);`
pub fn resize(self: *GuiClient, size: core.TerminalSize, theme: shared_model.TerminalTheme) !void {
    var capabilities = self.app.model.host.host_capabilities;

    capabilities.window_width_px = @as(u32, size.cols) * size.cell_width_px;
    capabilities.window_height_px = @as(u32, size.rows) * size.cell_height_px;
    capabilities.cell_width_px = size.cell_width_px;
    capabilities.cell_height_px = size.cell_height_px;
    capabilities.images = .unsupported;
    capabilities.pointer_pixels = .supported;
    capabilities.agent_panes = true;
    capabilities.terminal_colors = .{
        .foreground = theme.foreground,
        .background = theme.background,
        .palette = theme.palette,
    };

    _ = try self.app.applyHostUpdate(
        .{
            .size = size,
            .capabilities = capabilities,
        },
    );
}

/// Retires captured damage after GPU delivery, preserving newer received state.
fn complete(self: *GuiClient, token: u64, delivered: bool) !void {
    core.profiling.add(.gui_complete, 1);
    const active = self.app.presentation.active orelse return;

    if (token == 0 or token != @intFromEnum(active.token)) {
        return;
    }

    self.chrome.present(delivered);
    self.overlays.present(delivered);
    widget_routing.reconcileFocus(self);
    self.widgets.present(delivered);

    if (self.review.active) {
        self.review.widget.present(delivered);
    }

    widget_routing.reconcileFocus(self);
    self.pointer.hover.present(delivered);
    const delivery = self.app.presentation.complete(@enumFromInt(token), if (delivered) .delivered else .failed) orelse return;
    try client.presentation_delivery.apply(&self.app, delivery.commit);

    if (delivered) {
        try thread_items.delivered(self);
        try thread_history.delivered(self);
        thread_scroll.delivered(self);
        thread_selection.delivered(self);
    }
}

/// Applies runtime graphics commands to this connection's retained resources.
/// Example: `try gui.applyGraphics(command);`
pub fn applyGraphics(self: *GuiClient, command: shared_model.application_panes_pane_graphics.Command) !void {
    return switch (command) {
        .snapshot => |value| self.graphics_store.applySnapshot(value),
        .image => |value| self.graphics_store.applyImage(value),
        .shared_image => |value| self.graphics_store.applySharedImage(value),
        .image_chunk => |value| self.graphics_store.applyChunk(value),
        .placement => |value| self.graphics_store.applyPlacement(value),
        .delete_image => |value| self.graphics_store.deleteImage(value),
        .delete_placement => |value| self.graphics_store.deletePlacement(value),
    };
}

/// Borrows the projection synchronously and seals only the rendered pane frames.
/// Example: `const token = try gui.prepare(&renderer);`
fn prepare(self: *GuiClient, renderer: *Renderer) !u64 {
    self.widgets.tab_drag.validate(&self.app.model);

    if (!self.app.model.request_lifecycle.tracker.has(.tab_operation)) {
        self.widgets.tab_drop_pending = null;
    }

    if (self.app.presentation.active != null) {
        return error.PresentationBusy;
    }

    self.chrome.now_ns = client.monotonic(self.app.io);
    try thread_scroll.advance(self, self.chrome.now_ns);
    try thread_selection.prepare(self);
    self.diagrams.beginFrame();
    self.syntax.beginFrame();
    try self.review.synchronize(&self.app);
    self.review.widget.theme_override = self.app.model.theme;

    self.refreshPointer();
    try self.resolveFavicons(renderer);
    const projected = self.projection();
    const observed = self.observation();
    _ = self.app.presentation.observe(observed);
    var scene: Scene = .{
        .terminal = renderer,
        .chrome = &self.chrome,
        .overlays = &self.overlays,
        .theme = self.app.model.theme,
        .link = if (self.pointer.hover.link) |*hit| hit else null,
        .widgets = &self.widgets,
        .diagrams = &self.diagrams.store,
        .syntax = &self.syntax.store,
        .review = if (self.review.active) &self.review.widget else null,
    };

    const commit = try scene.prepare(projected);
    const diagram_revision = self.diagrams.store.revision;
    self.diagrams.start(&self.driver.inbox);
    self.syntax.start(&self.driver.inbox);
    self.review.start(
        .{
            .app = &self.app,
            .inbox = &self.driver.inbox,
        },
    );
    renderer.diagrams = self.diagrams.store.textures();

    if (self.diagrams.store.revision != diagram_revision) {
        self.chrome.invalidate();
    }

    const token = try self.app.presentation.begin(
        .{
            .observation = observed,
            .commit = commit,
            .geometry = client.Geometry.capture(projected),
        },
    );
    self.pointer.hover.prepare();

    return @intFromEnum(token);
}

/// Defers image adoption until the current GPU consumer releases its frame.
fn landDiagram(self: *GuiClient) void {
    self.diagrams.notify();
    self.chrome.invalidate();
}

/// The inbox synchronizes completed tokens; adoption waits for frame preparation.
fn landSyntax(self: *GuiClient) void {
    self.syntax.notify();
    self.chrome.invalidate();
}

/// Opens a runtime review for either a terminal pane or a managed agent.
/// Example: `try gui.openChangeReview(pane_id);`
pub fn openChangeReview(self: *GuiClient, pane_id: core.PaneId) !void {
    try self.review.open(&self.app, pane_id);
    try self.releasePointer();
    self.pointer.invalidateGestures();
    self.widgets.dispatcher.cancel();
    self.widgets.cancelComposition();
    self.widgets.tab_drag.cancel();
    self.chrome.cancelPointer();
    self.overlays.cancelPointer();
    self.chrome.invalidate();
}

/// Inbox completion releases the worker's immutable patch for the next frame.
fn landChangeReview(self: *GuiClient) void {
    self.review.notify();
    self.chrome.invalidate();
}

/// Lands one favicon lookup from the inbox; the next preparation places it.
fn landFavicon(self: *GuiClient, completion: client.FaviconCompletion) void {
    const image: ?*client.FaviconImage = switch (client.operations.favicons.complete(&self.app, completion)) {
        .stale => return,
        .missing => null,
        .image => |owned| owned,
    };

    self.chrome.favicons.land(
        self.app.gpa,
        .{
            .workspace = completion.workspace,
            .image = image,
        },
    );
    self.chrome.invalidate();
}

// Places a landed favicon into the page and starts the next lookup the
// list needs. Warm frames find nothing landed and nothing wanted.
fn resolveFavicons(self: *GuiClient, renderer: *Renderer) !void {
    const page = if (renderer.sprites) |*sprites| sprites else return;
    const favicons = &self.chrome.favicons;
    favicons.refresh(self.app.gpa, page);
    const want = favicons.next(&self.app.model.workspace_list_snapshot) orelse return;

    const job = client.operations.favicons.request(
        &self.app,
        .{
            .workspace = want.workspace,
            .cwd = want.cwd,
            .cell = @intCast(page.cell),
        },
    ) orelse return;
    self.driver.inbox.start(.favicon, .{ favicon_worker.execute, .{ self.app.io, self.app.gpa, job } }) catch |err| {
        client.operations.favicons.cancel(&self.app);
        return err;
    };
    favicons.started(want.workspace);
}

fn refreshPointer(self: *GuiClient) void {
    self.pointer.hover.refresh(self);
    self.pointer.link_gesture.validate(self.pointer.hover.link, self.app.model.version());
    message_links.refresh(self);
}

/// Captures semantic state plus adapter-owned routing and interaction revisions.
/// Example: `const projected = gui.projection();`
pub fn projection(self: *const GuiClient) client.Projection {
    return client.capture(
        &self.app.model,
        .{
            .geometry = shared_model.workbench.region(&self.app.model),
            .status_mode = self.statusMode(),
            .presentation_ingress = self.ingress(),
        },
    );
}

/// Captures the revisions used to decide whether another presentation is needed.
/// Example: `_ = gui.app.presentation.observe(gui.observation());`
pub fn observation(self: *const GuiClient) client.Observation {
    return .{
        .model = self.app.model.version(),
        .geometry_revision = shared_model.workbench.region(&self.app.model).revision,
        .presentation_ingress = self.ingress(),
    };
}

fn ingress(self: *const GuiClient) client.PresentationIngress {
    return .{
        .input_routing = self.binding_revision,
        .view_interaction = self.chrome.revision +% self.pointer.hover.revision +% self.widgets.dispatcher.revision +% self.app.model.change_review.version,
    };
}

/// Routes delivered widget targets before falling back to terminal input.
fn widgetInput(self: *GuiClient, event: event_module.Event) !bool {
    if (self.review.active) {
        if (try widget_routing.continueFallback(self, event)) {
            return true;
        }

        defer self.chrome.invalidate();

        return review_dispatch.apply(&self.review.widget, event);
    }

    return widget_routing.apply(self, event);
}

fn beginWidgetPaste(self: *GuiClient) !bool {
    if (self.review.active) {
        self.review.beginPaste();

        return true;
    }

    return widget_routing.beginPaste(self);
}

fn widgetPaste(self: *GuiClient, bytes: []const u8) !void {
    if (self.review.paste_generation != null) {
        self.review.appendPaste(bytes);

        return;
    }

    try widget_routing.paste(self, bytes);
}

fn endWidgetPaste(self: *GuiClient) !void {
    if (self.review.paste_generation != null) {
        try self.review.endPaste();
        self.chrome.invalidate();

        return;
    }

    try widget_routing.endPaste(self);
}

/// Publishes current editing state with the delivered caret geometry.
/// Example: `const available = gui.widgetTextContext(&context);`
pub fn widgetTextContext(self: *GuiClient, output: *native.TextContext) bool {
    if (self.review.active) {
        return self.review.widget.textContext(output);
    }

    return host_context.text(self, output);
}

/// Publishes owned widget semantics using delivered geometry.
/// Example: `const available = gui.widgetAccessibility(&tree);`
pub fn widgetAccessibility(self: *GuiClient, output: *native.AccessibilityTree) bool {
    if (self.review.active) {
        return self.review.widget.accessibility(output);
    }

    return host_context.accessibility(self, output);
}

test "widget draw failure preserves delivered targets and pending pane damage before retry" {
    const session = try TestSession.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    const gui = session.gui;
    gui.app.model.name_prompt.begin(
        .{
            .rename_tab = .{
                .tab_id = TestSession.location.tab_id,
                .label = "Visible title",
            },
        },
    );
    const delivered = try session.draw();
    try input_test_support.presented(
        gui,
        delivered,
        true,
    );
    const chrome = gui.chrome.presented();
    const overlays = gui.overlays.presented();
    const targets = gui.widgets.dispatcher.maps.presented();
    const editors = gui.widgets.editors.presented();
    try std.testing.expect(editors.len > 0);
    try session.receiveFrame(2);
    _ = gui.app.model.name_prompt.apply(.cancel);
    gui.app.model.name_prompt.begin(
        .{
            .rename_tab = .{
                .tab_id = TestSession.location.tab_id,
                .label = "Pending title",
            },
        },
    );
    const pane = gui.app.model.panes.find(TestSession.pane_id).?;
    const limit = session.gui.renderer.quads.limit;
    session.gui.renderer.quads.limit = 1;
    defer session.gui.renderer.quads.limit = limit;
    // Inject failure after measurement reserves the production frame budget.
    try std.testing.expectError(error.NativeQuadBudgetExceeded, gui.prepare(&gui.renderer));
    try std.testing.expectEqual(@as(usize, 1), session.gui.renderer.quads.items().len);
    try std.testing.expect(gui.app.presentation.active == null);
    try std.testing.expectEqual(@as(u64, 2), pane.pending_frame_id);
    try std.testing.expectEqual(chrome, gui.chrome.presented());
    try std.testing.expectEqual(overlays, gui.overlays.presented());
    try std.testing.expectEqual(targets, gui.widgets.dispatcher.maps.presented());
    try std.testing.expectEqual(editors, gui.widgets.editors.presented());
    try input_test_support.presented(
        gui,
        delivered,
        true,
    );
    try std.testing.expectEqual(targets, gui.widgets.dispatcher.maps.presented());
    try std.testing.expectEqual(@as(u64, 2), pane.pending_frame_id);

    session.gui.renderer.quads.limit = limit;
    const retry = try session.draw();
    try std.testing.expect(retry != delivered);
    try std.testing.expectEqual(targets, gui.widgets.dispatcher.maps.presented());
    try input_test_support.presented(
        gui,
        retry,
        true,
    );
    try std.testing.expect(gui.widgets.dispatcher.maps.presented() != targets);
    try std.testing.expectEqual(@as(usize, 1), gui.widgets.editors.presented().len);
    try std.testing.expectEqual(@as(u64, 0), pane.pending_frame_id);
    try session.settle();
}
