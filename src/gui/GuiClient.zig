//! One native connection's shared model and disposable host resources.
const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const host_ports = @import("host_ports.zig");
const NativeLoop = @import("NativeLoop.zig");
const NativeInput = @import("NativeInput.zig");
const Regions = @import("widgets/Regions.zig");
const Renderer = @import("render/TerminalRenderer.zig");
const native = @import("native/native.zig");
const selection = @import("render/copy_selection.zig");
const State = @import("widgets/interaction/State.zig");
const Chrome = @import("widgets/Chrome.zig");
const SyntaxService = @import("syntax/Service.zig");
const ReviewPanel = @import("change_review/Panel.zig");
const Message = @import("gui_event.zig").Message;
const InputEvent = @import("input/event.zig").Event;
const review_dispatch = @import("change_review/dispatch.zig");

const input_routing = @import("input/router.zig");
const widget_routing = @import("widgets/interaction/routing.zig");
const KeyInput = @import("input/KeyInput.zig");
const ClipboardResult = @import("input/ClipboardResult.zig");
const ScrollSample = @import("input/ScrollSample.zig");
const PointerEvent = @import("input/PointerEvent.zig");
const PasteChunk = @import("PasteChunk.zig");

const GuiClient = @This();

app: client.AttachedClient,
driver: *NativeLoop,
input: NativeInput = .{},
host: @import("host/Services.zig") = .{},
input_revision: u64 = 0,
focused: bool = true,
widgets: State = .{},
region: client.Region,
theme: client.ColorTheme,
chrome: Chrome = .{},

/// The sidebar band width preference; the shared model keeps only visibility.
sidebar: @import("SidebarPreference.zig") = .{},
overlays: @import("widgets/overlays/Overlays.zig") = .{},
lifecycle: client.PresentationLifecycleState = .{},
graphics_store: @import("graphics_delivery.zig").Store,
diagrams: @import("diagrams/Service.zig"),
syntax: SyntaxService,
review: *ReviewPanel,

pub fn of(app: *client.AttachedClient) *GuiClient {
    return @fieldParentPtr("app", app);
}

/// Adopts options on success and binds all ports before receiving messages.
/// Example: `const gui = try GuiClient.init(params, &driver);`
pub fn init(params: client.ClientInit, driver: *NativeLoop) !*GuiClient {
    const input = try NativeInput.init(.{
        .prefix = params.options.prefix,
        .bindings = params.options.bindings,
        .escape_timeout_ns = params.options.input_escape_timeout_ns,
        .sequence_timeout_ns = params.options.input_sequence_timeout_ns,
    });

    const gui = try params.gpa.create(GuiClient);
    errdefer params.gpa.destroy(gui);
    const review = try params.gpa.create(ReviewPanel);
    errdefer params.gpa.destroy(review);
    try client.AttachedClient.init(&gui.app, params);
    // Native chrome uses the shared semantic projection, never TUI Kitty output.
    gui.app.options.sidebar_renderer_locked = true;
    gui.driver = driver;
    driver.configuration.inbox = &driver.inbox;
    gui.input = input;
    gui.host = .{};
    gui.input_revision = 0;
    gui.focused = true;
    gui.widgets = .{};
    gui.theme = params.options.theme;
    gui.region = .{
        .area = .{},
        .revision = 0,
    };
    gui.resizeRegion(params.host_size.cols, params.host_size.rows);
    gui.chrome = .{};
    gui.sidebar = .init(params.options.gui.sidebar.width);

    gui.overlays = .{
        .router = &gui.input.router,
    };

    gui.lifecycle = .{};
    gui.graphics_store = .init(params.gpa);
    gui.diagrams = .init(params.gpa);

    gui.syntax = .{
        .allocator = params.gpa,
    };

    gui.review = review;
    gui.review.* = .{ .allocator = params.gpa };
    gui.review.widget.host_port = &gui.host;
    gui.review.widget.widgets = &gui.widgets;
    gui.app.sound_port = host_ports.sound(&gui.app);
    gui.app.notifier = host_ports.notifier(&gui.app);
    gui.app.link_opener = host_ports.links(&gui.app);
    gui.app.capture_port = host_ports.capture(&gui.app);
    gui.app.host_clipboard = host_ports.clipboard(&gui.app);
    gui.app.host_graphics = host_ports.graphics(&gui.app);
    gui.app.graphics = host_ports.graphicsRetention(&gui.app);
    gui.app.chrome = host_ports.chrome(&gui.app);
    gui.app.attachment_catalog = host_ports.attachmentCatalog(&gui.app);
    gui.app.attachment_shelf = host_ports.attachmentShelf(&gui.app);
    gui.app.presentation = host_ports.presentation(&gui.app);
    gui.app.timers = host_ports.timers(&gui.app);
    gui.app.bar_runner = host_ports.barCommands(&gui.app);
    gui.app.plugin_runner = host_ports.pluginWorkers(&gui.app);
    gui.app.path_completion_runner = host_ports.pathCompletions(&gui.app);
    gui.app.favicon_runner = host_ports.favicons(&gui.app);
    gui.app.clock = host_ports.clock(&gui.app);
    gui.app.host_input_source = host_ports.hostInput(&gui.app);
    gui.app.transport_driver = host_ports.transport(&gui.app);
    gui.app.config_watcher = host_ports.configWatcher(&gui.app);
    return gui;
}

/// Call only after the driver has joined its tasks. Example: `gui.deinit();`
pub fn deinit(gui: *GuiClient) void {
    const gpa = gui.app.gpa;
    if (gui.lifecycle.active) |flight| {
        _ = gui.lifecycle.complete(flight.token, .cancelled);
    }

    gui.graphics_store.deinit();
    gui.diagrams.deinit();
    gui.chrome.favicons.deinit(gpa);
    gui.widgets.deinit();
    gpa.destroy(gui.review);
    gui.app.deinit();
    gpa.destroy(gui);
}

pub fn start(gui: *GuiClient, colors: core.TerminalColors) !void {
    var capabilities = gui.app.model.hostCapabilities();
    capabilities.terminal_colors = colors;
    capabilities.images = .unsupported;
    capabilities.pointer_pixels = .supported;
    capabilities.agent_panes = true;

    _ = try client.operations.host_resources.apply(&gui.app, .{
        .size = gui.app.model.hostSize(),
        .capabilities = capabilities,
    });

    gui.app.startup.phase = .opening;

    try gui.app.runtime_transport.bootstrap(.{
        .graphics_shared = false,
        .client_identity = gui.app.client_identity,
        .terminal_colors = colors,
    });

    try client.runtime_io.scheduleRead(&gui.app);
    try client.runtime_io.pump(&gui.app);
    try client.operations.config_reloads.schedule(&gui.app);
    try client.operations.bar_updates.synchronize(&gui.app);
}

/// Copies borrowed input before the host callback returns. A full input queue
/// rejects admission; inbox failures propagate to the host. Example: `_ = try gui.acceptInput(event);`
pub fn acceptInput(self: *GuiClient, event: InputEvent) !bool {
    if (event == .focus) {
        // Focus transitions must remain ordered even when native input coalesces.
        try self.driver.inbox.post(.{ .focus = event.focus });
        return true;
    }

    self.input.acceptEvent(event) catch return false;
    try self.driver.inbox.notify(.input_ready);
    return true;
}

/// Drains one bounded turn, then folds reconnectable layout state once.
/// Workers only publish owned messages; the window thread owns mutation.
/// Example: `const status = try gui.update();`
pub fn update(self: *GuiClient) !?u8 {
    const loop = self.driver;
    const status: ?u8 = turn: {
        var batch = try loop.inbox.begin();
        defer loop.inbox.end();

        while (try loop.inbox.next(&batch)) |event| {
            const path = core.enter(pathFor(event));
            defer path.restore();

            if (try self.dispatch(event)) |exit_status| {
                break :turn exit_status;
            }
        }

        if (batch.processed != 0) {
            try client.client_layouts.observe(&self.app);
        }

        try loop.configuration.poll(&self.app);
        break :turn null;
    };

    self.refreshPointer();
    return status;
}

fn dispatch(self: *GuiClient, event: Message) !?u8 {
    switch (event) {
        .server => |result| return self.receive(result),
        .sent => |result| try client.runtime_io.handleSent(&self.app, result),
        .input_ready => try self.inputReady(),
        .focus => |focused| try self.focus(focused),
        .presented => |result| try self.complete(result.token, result.delivered),
        .configuration_ready => try self.driver.configuration.accept(&self.app),
        .input_timeout => |result| try result,
        .binding_timeout => |result| try self.expireBinding(result),
        .sidebar_animation_tick => |result| _ = try client.operations.sidebar_animations.handleTick(&self.app, result),
        .notification_tick => |result| _ = try client.operations.notifications.handleTick(&self.app, result),
        .bar_tick => |result| try client.operations.bar_updates.handleTick(&self.app, result),
        .bar_command => |result| try client.operations.bar_updates.completeCommand(&self.app, result),
        .link_opened => |result| try client.operations.link_openings.complete(&self.app, result),
        .path_completion => |result| try client.operations.path_completions.complete(&self.app, result),
        .favicon => |result| self.landFavicon(result),
        .diagram_ready => self.landDiagram(),
        .syntax_ready => self.landSyntax(),
        .change_review_ready => self.landChangeReview(),
        .plugin_result => |result| {
            if (try client.operations.plugin_actions.complete(&self.app, result)) {
                return 0;
            }
        },
    }

    return if (self.input.stopped) @as(u8, 0) else null;
}

fn pathFor(event: Message) core.Path {
    return switch (event) {
        .configuration_ready,
        .notification_tick,
        .bar_tick,
        .bar_command,
        .plugin_result,
        .link_opened,
        .path_completion,
        .favicon,
        .diagram_ready,
        .syntax_ready,
        .change_review_ready,
        => .observation,
        else => .interactive,
    };
}

/// Applies one validated runtime message before releasing its receive borrow.
/// Example: `const status = try gui.receive(result);`
pub fn receive(gui: *GuiClient, result: anyerror!*const client.RuntimeMessage) !?u8 {
    if (try client.runtime_io.handleRead(&gui.app, result)) |status| {
        return status;
    }

    if (gui.app.startup.phase == .opening and gui.app.model.activeTabLocation() != null) {
        gui.app.startup.phase = .active;
    }

    try gui.resumeInput();
    gui.refreshPointer();
    return null;
}

/// Consumes bounded native input and schedules another turn if it can advance.
/// Example: `try gui.inputReady();`
pub fn inputReady(self: *GuiClient) !void {
    if (self.input.len != 0) {
        self.input_revision +%= 1;
        try self.drainInput();
        try self.resumeInput();
    }
}

/// Adopts bindings and retires the deadline of the previous keymap.
/// Example: `gui.adoptBindings(config);`
pub fn adoptBindings(self: *GuiClient, config: client.RouterConfig) void {
    self.input.adopt(config);
    _ = self.input.binding_timeout.update(self.app.io, null);
}

/// Stops before the shared outbox fills, resuming on transport completion.
/// Example: `try gui.drainInput();`
pub fn drainInput(self: *GuiClient) !void {
    const app = &self.app;
    const input = &self.input;

    if (app.startup.holdsInput()) {
        return;
    }

    var budget = client.DrainBudget.begin(app.io, input.len + input.recovery.len);
    const pending = input.router.prefixPending();
    while (!input.stopped and input.len != 0 and client.runtime_io.availableCapacity(app) >= 4 and budget.take(app.io)) {
        app.presentation.noteInput(client.monotonic(app.io));
        const overflows = input.router.leaseOverflowCount();
        switch (input.front().?.*) {
            .key => |key| try self.dispatchKey(key),
            .text => |*text| {
                if (!try self.widgetInput(.{ .text = text.text() })) {
                    _ = try self.routeKey(.{ .key = text.key(), .raw = "", .now_ns = client.monotonic(app.io) });
                }
            },
            .paste_start => {
                _ = try self.applyInputDecision(input.router.interrupt());
                input.widget_paste = try self.beginWidgetPaste();
                if (!input.widget_paste) {
                    _ = try client.operations.paste_routing.start(app);
                }
            },
            .paste_text => |*chunk| {
                if (input.widget_paste) {
                    try self.widgetPaste(chunk.bytes[0..chunk.len]);
                } else {
                    _ = try client.operations.paste_routing.content(app, chunk.bytes[0..chunk.len]);
                }
            },
            .paste_finish => {
                if (input.widget_paste) {
                    try self.endWidgetPaste();
                } else {
                    _ = try client.operations.paste_routing.finish(app);
                }

                input.widget_paste = false;
            },
            .release_recovery => {
                if (!input.recovery.pointer_finished) {
                    try input.pointer.cancel(app);
                    self.chrome.cancelPointer();
                    self.overlays.cancelPointer();
                    _ = try self.widgetInput(.{ .focus = false });
                    _ = try self.widgetInput(.{ .focus = self.focused });
                    input.scroll_remainder = 0;
                    input.recovery.pointer_finished = true;
                    if (input.recovery.len != 0) {
                        continue;
                    }
                }

                if (input.recovery.next()) |key| {
                    try self.dispatchKey(key);
                    input.recovery.finish(key);
                    if (input.recovery.len != 0) {
                        continue;
                    }
                }

                input.recovery.queued = false;
                input.recovery.pointer_finished = false;
            },
            .pointer => |event| {
                if (event.event.interruptsKeys()) {
                    input.cancelBinding();
                }

                if (event.event.retained() or (event.geometry_revision == input.pointer.revision and event.gesture_revision == input.pointer.gesture_revision)) {
                    if (try self.widgetInput(.{ .pointer = event.event })) {
                        input.consume();
                        continue;
                    }
                }

                try input.pointer.apply(app, event);
            },
            .scroll => |*sample| {
                if (!try self.dispatchScroll(sample)) {
                    continue;
                }
            },
            .owned_small => |index| {
                _ = try self.widgetInput(input.small_events.view(index));
            },
            .composition_cancel => |value| _ = try self.widgetInput(.{ .composition = value }),
            .owned_large => |index| {
                if (!try self.dispatchClipboard(input.large_events.view(index).clipboard)) {
                    continue;
                }
            },
        }

        app.telemetry.metrics.key_lease_overflows +%= input.router.leaseOverflowCount() -% overflows;
        input.consume();
    }

    try self.finishInput(pending);
}

/// Resolve and execute one semantic key before accepting the next event.
/// Example: `_ = try gui.routeKey(.{ .key = key, .raw = "", .now_ns = now });`
pub fn routeKey(self: *GuiClient, event: input_routing.Type.KeyInput) !client.Control {
    const input = &self.input;

    errdefer input.router.eventFailed(event.key);
    defer {
        if (input.router.bindingDeadline() == null and !input.router.prefixPending()) {
            input.binding_target = null;
        }
    }
    const decision = input.router.routeEvent(event, .{
        .captures_keys = client.operations.key_routing.captures(&self.app),
        .repeat_policy = if (input.router.repeatAction()) |held| client.operations.action_routing.repeatPolicy(&self.app, held) else null,
    });
    const control = try self.applyInputDecision(decision);
    input.stopped = control == .stop;
    return control;
}

fn applyInputDecision(self: *GuiClient, decision: input_routing.Type.Decision) !client.Control {
    const input = &self.input;

    switch (decision) {
        .forward => |value| {
            _ = try client.operations.key_routing.apply(&self.app, .{ .key = value.key });
        },
        .replay => |value| {
            for (value.held_keys[0..value.held_key_len]) |held| {
                try self.deliverKey(held);
            }
            if (value.current_key) |current| {
                if (client.operations.key_routing.captures(&self.app)) {
                    _ = try client.operations.key_routing.apply(&self.app, .{ .key = current });
                } else {
                    try self.deliverKey(current);
                }
            }
        },
        .action => |request| {
            const control = try self.executeAction(request.value);
            if (control == .continue_routing) {
                input.router.actionCompleted(request, client.operations.action_routing.repeatPolicy(&self.app, request.value));
            }
            return control;
        },
        .pending, .discard => {},
    }
    return .continue_routing;
}

fn deliverKey(self: *GuiClient, value: client.Key) !void {
    const input = &self.input;

    if (input.binding_target) |owner| {
        if (value.phase == .press) {
            try widget_routing.replayBindingKey(self, owner, value);
            return;
        }
    }
    _ = try client.operations.key_routing.apply(&self.app, .{ .key = value });
}

/// Agent scrolling uses delivered transcript geometry. The goto and suggest
/// keys open the native palette already prefixed, and sidebar resize uses
/// this window's pixel preference. Other actions keep the shared routing.
/// Copy mode retires first, as the shared native action policy does.
/// Example: `const control = try gui.executeAction(.new_tab);`
pub fn executeAction(self: *GuiClient, value: client.Action) !client.Control {
    if (value == .scroll_pane) {
        if (try widget_routing.scrollFocusedThread(self, value.scroll_pane)) {
            return .continue_routing;
        }
    }

    const prefix: client.command_palette.Prefix = switch (value) {
        .goto_picker => .goto,
        .suggest_command => .suggest,
        .resize_sidebar => |direction| {
            _ = try client.operations.copy_modes.leave(&self.app);
            if (self.sidebar.step(direction)) {
                self.chrome.invalidate();
            }

            return .continue_routing;
        },
        else => return client.operations.action_routing.apply(&self.app, value),
    };
    if (client.operations.copy_modes.active(&self.app)) {
        _ = try client.operations.copy_modes.leave(&self.app);
    }

    _ = client.operations.name_prompts.beginPalette(&self.app, prefix);
    return .continue_routing;
}

fn dispatchKey(self: *GuiClient, key: KeyInput) !void {
    const input = &self.input;

    if (try self.widgetInput(.{ .key = key })) {
        return;
    }

    if (key.code == .char and key.code.char.len == 1 and std.ascii.toLower(key.code.char.bytes[0]) == 'v' and (key.mods.super or (key.mods.ctrl and key.mods.shift))) {
        if (key.phase == .press and key.target_id == 0) {
            input.terminal_clipboard.read(self) catch |err| switch (err) {
                error.HostRequestsFull => {},
                else => return err,
            };
        }

        return;
    }

    if (key.mods.super or key.target_id != 0) {
        return;
    }

    _ = try self.routeKey(.{ .key = key.terminalKey(), .raw = "", .now_ns = client.monotonic(self.app.io) });
}

fn dispatchClipboard(self: *GuiClient, result: ClipboardResult) !bool {
    const input = &self.input;

    if (input.clipboard_offset == null) {
        const kind = self.host.complete(result) orelse return true;
        if (kind == .write) {
            if (self.widgets.copy_feedback.complete(result, client.monotonic(self.app.io))) {
                self.widgets.dispatcher.revision +%= 1;
            }

            if (result.target_id != 0) {
                var completion = result;
                completion.operation = .write;
                _ = try self.widgetInput(.{ .clipboard = completion });
            }

            return true;
        }

        if (result.target_id != 0) {
            _ = try self.widgetInput(.{ .clipboard = result });
            return true;
        }

        if (!input.terminal_clipboard.take(self, result)) {
            return true;
        }

        _ = try self.applyInputDecision(input.router.interrupt());
        _ = try client.operations.pane_pastes.start(&self.app);
        input.clipboard_offset = 0;
        return false;
    }

    const offset = input.clipboard_offset.?;
    if (offset < result.text.len) {
        const count = PasteChunk.nextSize(result.text[offset..]);
        _ = try client.operations.pane_pastes.content(&self.app, result.text[offset..][0..count]);
        input.clipboard_offset = offset + count;
        return false;
    }

    _ = try client.operations.pane_pastes.finish(&self.app);
    input.clipboard_offset = null;
    return true;
}

fn dispatchScroll(self: *GuiClient, sample: *ScrollSample) !bool {
    const app = &self.app;
    const input = &self.input;

    if (sample.geometry_revision != input.pointer.revision or sample.gesture_revision != input.pointer.gesture_revision) {
        input.scroll_remainder = 0;
        return true;
    }

    const event = sample.event;
    if (!sample.started) {
        if (try self.widgetInput(.{ .scroll = event })) {
            input.scroll_remainder = 0;
            return true;
        }

        if (event.phase == .begin or event.phase == .cancel) {
            input.scroll_remainder = 0;
        }

        if (event.phase == .cancel) {
            return true;
        }

        const unit: f64 = if (event.precise) @floatFromInt(@max(1, input.pointer.geometry.size.cell_height_px)) else 1;
        input.scroll_remainder += std.math.clamp(event.delta_y / unit, -32, 32);
        sample.lines = @intFromFloat(std.math.clamp(@trunc(input.scroll_remainder), -32, 32));
        input.scroll_remainder -= @floatFromInt(sample.lines);
        sample.started = true;
    }

    if (sample.lines == 0) {
        return true;
    }

    const pointer: PointerEvent = .{ .kind = if (sample.lines < 0) .scroll_up else .scroll_down, .mods = event.mods, .x = event.x, .y = event.y };
    input.cancelBinding();
    try input.pointer.apply(app, input.pointer.sample(pointer));
    sample.lines += if (sample.lines < 0) @as(i8, 1) else -1;
    return sample.lines == 0;
}

fn finishInput(self: *GuiClient, pending: bool) !void {
    const app = &self.app;
    const input = &self.input;

    if (input.router.bindingDeadline() == null and !input.router.prefixPending()) {
        input.binding_target = null;
    }

    if (pending != input.router.prefixPending()) {
        input.presentation_revision +%= 1;
    }

    if (input.binding_timeout.update(app.io, input.router.bindingDeadline()) == .schedule) {
        app.timers.arm(.binding, &input.binding_timeout) catch |err| {
            input.binding_timeout.schedulingFailed();
            return err;
        };
    }
}

/// Reserves one control slot to finish gestures even when ordinary input is
/// saturated. Example: `try gui.cancelPointer();`
pub fn cancelPointer(self: *GuiClient) !void {
    const input = &self.input;

    input.requestRecovery();
    try self.drainInput();
    try self.resumeInput();
}

/// Example: `try gui.expireBinding(result);`
pub fn expireBinding(self: *GuiClient, result: anyerror!void) !void {
    const app = &self.app;
    const input = &self.input;

    try input.binding_timeout.complete(result);
    const pending = input.router.prefixPending();
    input.stopped = try self.applyInputDecision(input.router.expireBinding(client.monotonic(app.io))) == .stop;
    try self.finishInput(pending);
}

/// A clipboard response retains the widget that requested it across focus
/// changes. Example: `try gui.requestClipboardRead(id, generation);`
pub fn requestClipboardRead(self: *GuiClient, target_id: u64, generation: u64) !void {
    try @import("widgets/interaction/routing.zig").beginClipboardRead(self, .{ .target_id = target_id, .generation = generation });
}

/// Copies selected UTF-8 before the native host drains the request.
/// Example: `try gui.requestClipboardWrite(selection);`
pub fn requestClipboardWrite(self: *GuiClient, bytes: []const u8) !void {
    _ = try self.host.write(bytes);
    native.telar_gui_wake(self.driver.fds[1]);
}

/// Requests a link copy with a bottom confirmation after host success.
/// Example: `try gui.copyLink(destination);`
pub fn copyLink(self: *GuiClient, bytes: []const u8) !void {
    self.widgets.copy_feedback.pending = try self.requestClipboardWriteOwned(.{}, bytes);
}

/// The editor can commit a cut only after the matching native write succeeds.
/// Example: `const request = try gui.requestClipboardWriteOwned(owner, bytes);`
pub fn requestClipboardWriteOwned(self: *GuiClient, owner: @import("host/Owner.zig"), bytes: []const u8) !u64 {
    const request = try self.host.writeOwned(owner, bytes);
    native.telar_gui_wake(self.driver.fds[1]);
    return request;
}

/// Example: `try gui.focus(true);`
pub fn focus(self: *GuiClient, focused: bool) !void {
    self.focused = focused;
    if (!focused) {
        self.widgets.thread_scroll.clear();
        self.widgets.tab_drag.cancel();
        @import("widgets/interaction/message_links.zig").clear(self);
        @import("widgets/interaction/thread_selection.zig").cancel(self);
    }
    self.input_revision +%= 1;
    _ = self.widgets.dispatcher.route(.{ .focus = focused });
    if (!focused) {
        self.widgets.preedit.clear();
    }
    if (!focused) {
        self.input.pointer.hover.clear();
        self.input.pointer.link_gesture.cancel();
        self.chrome.cancelPointer();
        self.overlays.cancelPointer();
        try self.cancelPointer();
    }
}

/// Queue one readiness notification only when input can make progress.
/// Example: `try gui.resumeInput();`
pub fn resumeInput(self: *GuiClient) !void {
    if (self.input.len != 0 and !self.app.startup.holdsInput() and client.runtime_io.availableCapacity(&self.app) >= 4) {
        try self.driver.inbox.notify(.input_ready);
    }
}

/// Copies the visible cursor identity for the native blink clock.
/// Example: `clock.observe(gui.cursorTarget(), now_ns);`
pub fn cursorTarget(gui: *const GuiClient) @import("CursorTarget.zig") {
    if (gui.app.model.name_prompt.active()) {
        return .{};
    }

    const model = gui.app.model.activeTabModelConst() orelse return .{};
    const pane = model.focusedPaneConst() orelse return .{};
    const copy = gui.app.model.copyModeProjection();
    const copy_view: ?client.CopyModeView = if (copy) |value| if (value.pane_id == pane.id) value.view else null else null;
    const cursor = selection.cursor(pane, copy_view);
    var layout: client.LayoutSnapshot = .{};
    model.layout.snapshot(gui.region.area, &layout);
    for (layout.views()) |view| {
        if (view.pane_id == pane.id and view.surface == .terminal and cursor.x < view.content.w and cursor.y < view.content.h) {
            return .{ .pane_id = pane.id, .generation = pane.attachment_generation, .cursor = cursor };
        }
    }

    return .{};
}

/// The workbench owns the whole measured grid: the sidebar is a pixel band
/// the renderer already took off the window, not a column of this grid.
/// Example: `gui.resizeRegion(size.cols, size.rows);`
pub fn resizeRegion(gui: *GuiClient, cols: u16, rows: u16) void {
    const regions = Regions.calculate(cols, rows);
    if (std.meta.eql(gui.region.area, regions.workbench)) {
        return;
    }

    gui.region = .{ .area = regions.workbench, .revision = gui.region.revision + 1 };
}

/// Measures the window with the shared sidebar visibility and this window's
/// width preference, then retains the band the renderer resolved so the
/// next keyboard step or drag clamps to it. The caller still negotiates the
/// PTY with `resize`.
/// Example: `const size = try gui.measure(&renderer, viewport);`
pub fn measure(gui: *GuiClient, renderer: *Renderer, viewport: native.Viewport) !core.TerminalSize {
    const viewport_changed = !std.meta.eql(renderer.viewport, [2]u32{ viewport.width, viewport.height }) or renderer.scale != viewport.scale;
    renderer.sidebar_request = gui.sidebar.request(gui.app.model.sidebarVisible());
    const size = try renderer.measure(viewport);
    if (viewport_changed or !std.meta.eql(size, gui.app.model.hostSize()) or gui.widgets.tab_drag_step != renderer.chrome.px(4)) {
        gui.widgets.tab_drag.cancel();
    }

    gui.sidebar.observe(renderer.sidebar);
    return size;
}

/// Applies a dragged or stepped sidebar width: the preference changes and
/// the next preparation measures the grid again.
/// Example: `gui.adoptSidebarWidth(command.sidebar_width.?);`
pub fn adoptSidebarWidth(gui: *GuiClient, width: u32) void {
    if (gui.sidebar.drag(width)) {
        gui.chrome.invalidate();
    }
}

/// Publishes exact font metrics and lets shared geometry negotiate the PTY.
/// Example: `try gui.resize(size, renderer.theme);`
pub fn resize(gui: *GuiClient, size: core.TerminalSize, theme: client.TerminalTheme) !void {
    var capabilities = gui.app.model.hostCapabilities();
    capabilities.window_width_px = @as(u32, size.cols) * size.cell_width_px;
    capabilities.window_height_px = @as(u32, size.rows) * size.cell_height_px;
    capabilities.cell_width_px = size.cell_width_px;
    capabilities.cell_height_px = size.cell_height_px;
    capabilities.images = .unsupported;
    capabilities.pointer_pixels = .supported;
    capabilities.agent_panes = true;
    capabilities.terminal_colors = .{ .foreground = theme.foreground, .background = theme.background, .palette = theme.palette };
    _ = try client.operations.host_resources.apply(&gui.app, .{ .size = size, .capabilities = capabilities });
}

/// Retires captured damage after GPU delivery, preserving newer received state.
/// Example: `try gui.complete(token, true);`
pub fn complete(gui: *GuiClient, token: u64, delivered: bool) !void {
    const active = gui.lifecycle.active orelse return;
    if (token == 0 or token != @intFromEnum(active.token)) {
        return;
    }

    gui.chrome.present(delivered);
    gui.overlays.present(delivered);
    @import("widgets/interaction/routing.zig").reconcileFocus(gui);
    gui.widgets.present(delivered);
    if (gui.review.active) {
        gui.review.widget.present(delivered);
    }
    @import("widgets/interaction/routing.zig").reconcileFocus(gui);
    gui.input.pointer.hover.present(delivered);
    const delivery = gui.lifecycle.complete(@enumFromInt(token), if (delivered) .delivered else .failed) orelse return;
    try client.presentation_delivery.apply(&gui.app, delivery.commit);
    if (delivered) {
        try @import("widgets/interaction/thread_items.zig").delivered(gui);
        try @import("widgets/interaction/thread_history.zig").delivered(gui);
        @import("widgets/interaction/thread_scroll.zig").delivered(gui);
        @import("widgets/interaction/thread_selection.zig").delivered(gui);
    }
}

pub fn applyGraphics(gui: *GuiClient, command: client.ApplicationPanesPaneGraphicsCommand) !void {
    return switch (command) {
        .snapshot => |value| gui.graphics_store.applySnapshot(value),
        .image => |value| gui.graphics_store.applyImage(value),
        .shared_image => |value| gui.graphics_store.applySharedImage(value),
        .image_chunk => |value| gui.graphics_store.applyChunk(value),
        .placement => |value| gui.graphics_store.applyPlacement(value),
        .delete_image => |value| gui.graphics_store.deleteImage(value),
        .delete_placement => |value| gui.graphics_store.deletePlacement(value),
    };
}

/// Borrows the projection synchronously and seals only the rendered pane frames.
/// Example: `const token = try gui.prepare(&renderer);`
pub fn prepare(gui: *GuiClient, renderer: *@import("render/TerminalRenderer.zig")) !u64 {
    gui.widgets.tab_drag.validate(&gui.app.model);
    if (!client.request_lifecycle.has(&gui.app, .tab_operation)) {
        gui.widgets.tab_drop_pending = null;
    }
    if (gui.lifecycle.active != null) {
        return error.PresentationBusy;
    }

    gui.chrome.now_ns = client.monotonic(gui.app.io);
    try @import("widgets/interaction/thread_scroll.zig").advance(gui, gui.chrome.now_ns);
    try @import("widgets/interaction/thread_selection.zig").prepare(gui);
    gui.diagrams.beginFrame();
    gui.syntax.beginFrame();
    try gui.review.synchronize(&gui.app);
    gui.review.widget.theme_override = gui.theme;

    gui.refreshPointer();
    try gui.resolveFavicons(renderer);
    const projected = gui.projection();
    const observed = gui.observation();
    _ = gui.lifecycle.observe(observed);
    var scene: @import("render/Scene.zig") = .{ .terminal = renderer, .chrome = &gui.chrome, .overlays = &gui.overlays, .theme = gui.theme, .link = if (gui.input.pointer.hover.link) |*hit| hit else null, .widgets = &gui.widgets, .diagrams = &gui.diagrams.store, .syntax = &gui.syntax.store, .review = if (gui.review.active) &gui.review.widget else null };
    const commit = try scene.prepare(projected);
    const diagram_revision = gui.diagrams.store.revision;
    gui.diagrams.start(&gui.driver.inbox);
    gui.syntax.start(&gui.driver.inbox);
    gui.review.start(.{ .app = &gui.app, .inbox = &gui.driver.inbox });
    renderer.diagrams = gui.diagrams.store.textures();
    if (gui.diagrams.store.revision != diagram_revision) {
        gui.chrome.invalidate();
    }
    const token = try gui.lifecycle.begin(.{ .observation = observed, .commit = commit, .geometry = client.Geometry.capture(projected) });
    gui.input.pointer.hover.prepare();
    return @intFromEnum(token);
}

/// Defers image adoption until the current GPU consumer releases its frame.
/// Example: `gui.landDiagram();`
pub fn landDiagram(gui: *GuiClient) void {
    gui.diagrams.notify();
    gui.chrome.invalidate();
}

/// The inbox synchronizes completed tokens; adoption waits for frame preparation.
/// Example: `gui.landSyntax();`
pub fn landSyntax(self: *GuiClient) void {
    self.syntax.notify();
    self.chrome.invalidate();
}

/// Opens a runtime review for either a terminal pane or a managed agent.
/// Example: `try gui.openChangeReview(pane_id);`
pub fn openChangeReview(self: *GuiClient, pane_id: core.PaneId) !void {
    try self.review.open(&self.app, pane_id);
    try self.input.pointer.cancel(&self.app);
    self.input.pointer.invalidateGestures();
    self.widgets.dispatcher.cancel();
    self.widgets.cancelComposition();
    self.widgets.tab_drag.cancel();
    self.chrome.cancelPointer();
    self.overlays.cancelPointer();
    self.chrome.invalidate();
}

/// Inbox completion releases the worker's immutable patch for the next frame.
/// Example: `gui.landChangeReview();`
pub fn landChangeReview(self: *GuiClient) void {
    self.review.notify();
    self.chrome.invalidate();
}

/// Lands one favicon lookup from the inbox; the next preparation places it.
/// Example: `gui.landFavicon(completion);`
pub fn landFavicon(gui: *GuiClient, completion: client.FaviconCompletion) void {
    const image: ?*client.FaviconImage = switch (client.operations.favicons.complete(&gui.app, completion)) {
        .stale => return,
        .missing => null,
        .image => |owned| owned,
    };
    gui.chrome.favicons.land(gui.app.gpa, .{ .workspace = completion.workspace, .image = image });
    gui.chrome.invalidate();
}

// Places a landed favicon into the page and starts the next lookup the
// list needs. Warm frames find nothing landed and nothing wanted.
fn resolveFavicons(gui: *GuiClient, renderer: *@import("render/TerminalRenderer.zig")) !void {
    const page = if (renderer.sprites) |*sprites| sprites else return;
    const favicons = &gui.chrome.favicons;
    favicons.refresh(gui.app.gpa, page);
    const want = favicons.next(gui.app.model.workspaceListSnapshot()) orelse return;
    if (try client.operations.favicons.request(&gui.app, .{ .workspace = want.workspace, .cwd = want.cwd, .cell = @intCast(page.cell) })) {
        favicons.started(want.workspace);
    }
}

fn refreshPointer(gui: *GuiClient) void {
    gui.input.pointer.hover.refresh(gui);
    gui.input.pointer.link_gesture.validate(gui.input.pointer.hover.link, gui.app.model.version());
    @import("widgets/interaction/message_links.zig").refresh(gui);
}

/// Captures semantic state plus adapter-owned routing and interaction revisions.
/// Example: `const projected = gui.projection();`
pub fn projection(gui: *const GuiClient) client.Projection {
    return client.capture(&gui.app.model, .{ .geometry = gui.region, .status_mode = gui.input.statusMode(client.operations.copy_modes.active(&gui.app)), .presentation_ingress = gui.ingress() });
}

/// Example: `_ = gui.lifecycle.observe(gui.observation());`
pub fn observation(gui: *const GuiClient) client.Observation {
    return .{ .model = gui.app.model.version(), .geometry_revision = gui.region.revision, .presentation_ingress = gui.ingress() };
}

fn ingress(gui: *const GuiClient) client.PresentationIngress {
    return .{ .input_routing = gui.input.presentation_revision, .view_interaction = gui.chrome.revision +% gui.input.pointer.hover.revision +% gui.widgets.dispatcher.revision +% gui.app.change_review.version };
}

/// Routes delivered widget targets before falling back to terminal input.
/// Example: `if (try gui.widgetInput(event)) return;`
pub fn widgetInput(gui: *GuiClient, event: @import("input/event.zig").Event) !bool {
    if (gui.review.active) {
        if (try @import("widgets/interaction/routing.zig").continueFallback(gui, event)) {
            return true;
        }
        defer gui.chrome.invalidate();
        return review_dispatch.apply(&gui.review.widget, event);
    }
    return @import("widgets/interaction/routing.zig").apply(gui, event);
}

/// Example: `const captured = try gui.beginWidgetPaste();`
pub fn beginWidgetPaste(gui: *GuiClient) !bool {
    if (gui.review.active) {
        gui.review.beginPaste();
        return true;
    }
    return @import("widgets/interaction/routing.zig").beginPaste(gui);
}

/// Example: `try gui.widgetPaste(bytes);`
pub fn widgetPaste(gui: *GuiClient, bytes: []const u8) !void {
    if (gui.review.paste_generation != null) {
        gui.review.appendPaste(bytes);
        return;
    }
    try @import("widgets/interaction/routing.zig").paste(gui, bytes);
}

/// Example: `try gui.endWidgetPaste();`
pub fn endWidgetPaste(gui: *GuiClient) !void {
    if (gui.review.paste_generation != null) {
        try gui.review.endPaste();
        gui.chrome.invalidate();
        return;
    }
    try @import("widgets/interaction/routing.zig").endPaste(gui);
}

/// Publishes current editing state with the delivered caret geometry.
/// Example: `if (gui.widgetTextContext(&context)) publish(context);`
pub fn widgetTextContext(gui: *GuiClient, output: *native.TextContext) bool {
    if (gui.review.active) {
        return gui.review.widget.textContext(output);
    }
    return @import("widgets/interaction/host_context.zig").text(gui, output);
}

/// Publishes owned widget semantics using delivered geometry.
/// Example: `if (gui.widgetAccessibility(&tree)) publish(tree);`
pub fn widgetAccessibility(gui: *GuiClient, output: *native.AccessibilityTree) bool {
    if (gui.review.active) {
        return gui.review.widget.accessibility(output);
    }
    return @import("widgets/interaction/host_context.zig").accessibility(gui, output);
}
