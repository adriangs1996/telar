//! Frame pacing and presentation: the draw-request → deadline → compose →
//! cell-flush cycle, plus a lower-priority media pass. Owns the host-terminal
//! back/front buffers. Frame acks come back to the caller as values; the
//! client enqueues them.

const std = @import("std");
const core = @import("telar-core");
const client_clock = @import("clock.zig");
const graphics = @import("../graphics/root.zig");
const attachments = @import("../attachments/root.zig");
const presentation = @import("../presentation/root.zig");
const workspace_capability = @import("../workspace/root.zig");
const client_telemetry = @import("telemetry.zig");
const client_model = @import("model.zig");
const kitty = graphics.kitty;
const modal_graphics = graphics.modal;
const toast_graphics = graphics.toast;
const multiplexer = workspace_capability.multiplexer;
const pace = presentation.pace;
const term = presentation.screen;

const Io = std.Io;
const monotonic = client_clock.monotonic;
const schema = core.schema;
const diagnostics = core.diagnostics;
const icon_graphics = graphics.icons;

const client_mod = @import("client.zig");
const Client = client_mod;
const ClientEvent = client_mod.ClientEvent;
const ClientMetrics = client_telemetry.Metrics;

const Presenter = @This();

pub const Observation = struct {
    model: client_model.Version,
    graphics_ingress: u64,
    attachment_ingress: u64,
};

io: Io,
/// Borrowed from the client, whose heap address is stable.
select: *Io.Select(ClientEvent),
metrics: *ClientMetrics,
screen: term.Screen,
pacer: pace.Pacer = .{},
observed_model_version: client_model.Version = .{},
presented_model_version: client_model.Version = .{},
observed_graphics_ingress: u64 = 0,
presented_graphics_ingress: u64 = 0,
observed_attachment_ingress: u64 = 0,
presented_attachment_ingress: u64 = 0,
presented_copy_mode: ?client_model.CopyModeProjection = null,
draw_pending: bool = false,
draw_due_ns: u64 = 0,
media_tick_pending: bool = false,
pending_updates: usize = 0,
last_presented_ns: ?u64 = null,
/// When the host terminal last delivered input bytes. Zero until the
/// first read, so a fresh session starts on the boosted media budget.
last_input_ns: u64 = 0,

/// Releases the host screen buffers.
///
/// ```zig
/// defer presenter.deinit();
/// ```
pub fn deinit(presenter: *Presenter) void {
    presenter.screen.deinit();
}

/// Resizes the host screen buffers to one validated terminal grid.
///
/// ```zig
/// try presenter.resize(80, 24);
/// ```
pub fn resize(presenter: *Presenter, cols: u16, rows: u16) !void {
    try presenter.screen.resize(cols, rows);
}

/// Records host input activity for media-idle policy.
///
/// ```zig
/// presenter.noteInput(now_ns);
/// ```
pub fn noteInput(presenter: *Presenter, now_ns: u64) void {
    presenter.last_input_ns = now_ns;
}

/// Observes semantic and physical client revisions and schedules one frame.
///
/// ```zig
/// try presenter.observe(observation);
/// ```
pub fn observe(presenter: *Presenter, observation: Observation) !void {
    const newly_observed = !std.meta.eql(presenter.observed_model_version, observation.model) or
        presenter.observed_graphics_ingress != observation.graphics_ingress or
        presenter.observed_attachment_ingress != observation.attachment_ingress;
    if (newly_observed) {
        presenter.observed_model_version = observation.model;
        presenter.observed_graphics_ingress = observation.graphics_ingress;
        presenter.observed_attachment_ingress = observation.attachment_ingress;
        try presenter.requestDraw();
        return;
    }

    const presentation_stale = !std.meta.eql(presenter.presented_model_version, observation.model) or
        presenter.presented_graphics_ingress != observation.graphics_ingress or
        presenter.presented_attachment_ingress != observation.attachment_ingress;
    if (presentation_stale and !presenter.draw_pending) {
        try presenter.requestDraw();
    }
}

/// Registers one pending update and arms the paced draw timer if none is
/// armed. What does not fit the frame budget folds into the next frame.
///
/// ```zig
/// try presenter.requestDraw();
/// ```
pub fn requestDraw(presenter: *Presenter) !void {
    presenter.pending_updates +|= 1;
    if (comptime diagnostics.enabled) {
        presenter.metrics.max_pending_updates = @max(
            presenter.metrics.max_pending_updates,
            presenter.pending_updates,
        );
    }
    if (presenter.draw_pending) {
        return;
    }

    const now_ns = monotonic(presenter.io);
    const deadline_ns = presenter.pacer.waitUntil(now_ns) orelse now_ns;
    if (deadline_ns != now_ns) {
        presenter.pacer.noteThrottled();
    }

    presenter.draw_pending = true;
    presenter.draw_due_ns = deadline_ns;
    presenter.select.concurrent(.draw, waitToDraw, .{ presenter.io, deadline_ns }) catch |err| {
        presenter.draw_pending = false;
        return err;
    };
}

/// Arms one independently paced media pass. Cell work always wins before a
/// pass starts, and each pass emits at most the baseline KGP byte budget.
///
/// ```zig
/// try presenter.requestMedia();
/// ```
pub fn requestMedia(presenter: *Presenter) !void {
    try presenter.requestMediaAt(monotonic(presenter.io) +| pace.default_interval);
}

fn requestMediaAt(presenter: *Presenter, deadline_ns: u64) !void {
    if (presenter.media_tick_pending) {
        return;
    }

    presenter.media_tick_pending = true;
    presenter.select.concurrent(.media_tick, waitToDraw, .{ presenter.io, deadline_ns }) catch |err| {
        presenter.media_tick_pending = false;
        return err;
    };
}

/// Releases the single draw-task token before propagating its result.
///
/// ```zig
/// try presenter.completeDraw(result);
/// ```
pub fn completeDraw(presenter: *Presenter, result: anyerror!void) !void {
    presenter.draw_pending = false;

    try result;
}

/// Releases the single media-task token before propagating its result.
///
/// ```zig
/// try presenter.completeMediaTick(result);
/// ```
pub fn completeMediaTick(presenter: *Presenter, result: anyerror!void) !void {
    presenter.media_tick_pending = false;

    try result;
}

/// The `.draw` event: presents the latest client model, including its
/// explicit empty state during startup and workspace handoff.
///
/// ```zig
/// const delivery = try presenter.presentDue(client) orelse return;
/// ```
pub fn presentDue(presenter: *Presenter, client: *Client) !?Delivery {
    if (comptime diagnostics.enabled) {
        presenter.metrics.draw_lateness.observe(monotonic(presenter.io) -| presenter.draw_due_ns);
    }
    if (presenter.pending_updates == 0) {
        return null;
    }

    const model = client.model.activeTabModel();
    const workspace_changed = presenter.presented_model_version.workspace !=
        presenter.observed_model_version.workspace;
    const configuration_changed = presenter.presented_model_version.configuration !=
        presenter.observed_model_version.configuration;
    const diagnostic_changed = presenter.presented_model_version.diagnostic !=
        presenter.observed_model_version.diagnostic;
    const host_changed = presenter.presented_model_version.host !=
        presenter.observed_model_version.host;
    const workspace_list_changed = presenter.presented_model_version.workspace_list !=
        presenter.observed_model_version.workspace_list;
    const agents_changed = presenter.presented_model_version.agents !=
        presenter.observed_model_version.agents;
    const sidebar_animation_changed = presenter.presented_model_version.sidebar_animation !=
        presenter.observed_model_version.sidebar_animation;
    const proxy_status_changed = presenter.presented_model_version.proxy_status !=
        presenter.observed_model_version.proxy_status;
    const system_metrics_changed = presenter.presented_model_version.system_metrics !=
        presenter.observed_model_version.system_metrics;
    const notifications_changed = presenter.presented_model_version.notifications !=
        presenter.observed_model_version.notifications;
    const tabs_changed = presenter.presented_model_version.tabs !=
        presenter.observed_model_version.tabs;
    const active_tab_changed = presenter.presented_model_version.active_tab !=
        presenter.observed_model_version.active_tab;
    const panes_changed = presenter.presented_model_version.panes !=
        presenter.observed_model_version.panes;
    const pane_metadata_changed = presenter.presented_model_version.pane_metadata !=
        presenter.observed_model_version.pane_metadata;
    const pane_foreground_changed = presenter.presented_model_version.pane_foreground !=
        presenter.observed_model_version.pane_foreground;
    const chrome_changed = presenter.presented_model_version.chrome !=
        presenter.observed_model_version.chrome;
    const prompt_changed = presenter.presented_model_version.prompt !=
        presenter.observed_model_version.prompt;
    const copy_changed = presenter.presented_model_version.copy !=
        presenter.observed_model_version.copy;
    const viewport_changed = presenter.presented_model_version.viewport !=
        presenter.observed_model_version.viewport;
    const copy_projection = client.model.copyModeProjection();
    const copy_status_changed = (presenter.presented_copy_mode == null) !=
        (copy_projection == null);
    if (viewport_changed or pane_foreground_changed) {
        invalidateAllCompositions(&client.model);
    }
    if (copy_changed) {
        projectCopyMode(&client.model, presenter.presented_copy_mode, copy_projection);
    }
    if (chrome_changed) {
        client.view.setSidebarVisible(client.model.sidebarVisible());
        client.view.setWorkspaceListCollapsed(client.model.workspaceListCollapsed());
    }
    if (agents_changed) {
        client.view.resetSidebarScroll();
    }
    if (prompt_changed) {
        client.view.clearHover();
    }
    if (workspace_changed or configuration_changed or diagnostic_changed or host_changed or
        workspace_list_changed or agents_changed or sidebar_animation_changed or
        proxy_status_changed or system_metrics_changed or notifications_changed or tabs_changed or
        active_tab_changed or panes_changed or pane_metadata_changed or chrome_changed or
        prompt_changed or copy_status_changed)
    {
        client.view.invalidate();
    }
    if (active_tab_changed or panes_changed or host_changed) {
        if (model) |active| {
            active.composition_invalidated = true;
        }
    }

    const presented = if (model) |active|
        try presenter.present(client, active)
    else
        try presenter.presentEmpty(client);
    presenter.presented_model_version = presenter.observed_model_version;
    presenter.presented_graphics_ingress = presenter.observed_graphics_ingress;
    presenter.presented_attachment_ingress = presenter.observed_attachment_ingress;
    presenter.presented_copy_mode = copy_projection;
    presenter.observePresentation(presented.presented_ns);
    presenter.pacer.record(presented.presented_ns, presenter.draw_due_ns, presenter.pending_updates);
    presenter.pending_updates = 0;

    return .{
        .frame_acks = presented.acks,
        .media_pending = model != null and presenter.mediaWorkPending(client),
    };
}

fn invalidateAllCompositions(model: *client_model.Model) void {
    var tabs = model.workspace.tabIterator();
    while (tabs.next()) |tab| {
        tab.model.composition_invalidated = true;
    }
}

fn projectCopyMode(model: *client_model.Model, previous: ?client_model.CopyModeProjection, next: ?client_model.CopyModeProjection) void {
    if (previous) |projection| {
        if (next == null or next.?.pane_id != projection.pane_id) {
            if (model.workspace.tabForPane(projection.pane_id)) |tab| {
                tab.model.setPaneCopyView(projection.pane_id, null);
            }
        }
    }

    if (next) |projection| {
        if (model.workspace.tabForPane(projection.pane_id)) |tab| {
            tab.model.setPaneCopyView(projection.pane_id, projection.view);
        }
    }
}

/// The media event never composes cells. A pending or scheduled cell frame
/// defers it, which gives interactive output priority without concurrent
/// writes corrupting the terminal protocol stream.
///
/// ```zig
/// try presenter.presentMedia(client);
/// ```
pub fn presentMedia(presenter: *Presenter, client: *Client) !void {
    if (presenter.pending_updates != 0 or presenter.draw_pending) {
        try presenter.requestMedia();
        return;
    }

    const model = client.model.activeTabModel() orelse return;
    const media_idle = monotonic(presenter.io) -| presenter.last_input_ns >=
        toast_graphics.idle_after_ns;
    const notifications = client.model.notificationSnapshot();
    client.view.kittyAttachments().reapRetired();
    const covered_before = client.view.graphicalToastsCover(notifications);
    const modal_covered_before = client.view.graphicalModalCoversPlan();
    const icon_fallback_changed = try client.view.prepareGraphics(notifications, media_idle);
    if (icon_fallback_changed) {
        try presenter.requestDraw();
    }
    if (!presenter.mediaWorkPending(client)) {
        return;
    }
    if (presenter.onlyWaitingForMediaIdle(client, media_idle)) {
        try presenter.requestMediaAt(presenter.last_input_ns +| toast_graphics.idle_after_ns);
        return;
    }

    const capabilities = client.model.hostCapabilities();
    const host_size = client.model.hostSize();
    const layout_snapshot = model.layoutSnapshot(client.view.workbench());
    client.graphics_store.setHostZlib(capabilities.kitty_zlib == .supported);
    var graphics_writer: CombinedGraphicsWriter = .{
        .panes = .{
            .store = &client.graphics_store,
            .layout_snapshot = layout_snapshot,
            .cell_width = host_size.cell_width_px,
            .cell_height = host_size.cell_height_px,
            .budget = kitty.transmission_budget_per_frame,
        },
        .sidebar = client.view.kittySidebar(),
        .icons = client.view.kittyIcons(),
        .toasts = client.view.kittyToasts(),
        .modal = client.view.kittyModal(),
        .attachments = client.view.kittyAttachments(),
        .allow_toast_transmission = media_idle,
        .metrics = presenter.metrics,
    };
    presenter.screen.graphics = .{
        .context = &graphics_writer,
        .write = CombinedGraphicsWriter.writeOpaque,
    };
    try presenter.flushMedia(client.writer);
    if (comptime diagnostics.enabled) {
        const graphics_stats = graphics_writer.panes.stats;
        presenter.metrics.pane_shared_images += graphics_stats.shared_images;
        presenter.metrics.pane_inline_images += graphics_stats.inline_images;
        presenter.metrics.pane_compressed_images += graphics_stats.compressed_images;
        presenter.metrics.pane_transmission_passes += graphics_stats.transmission_passes;
        presenter.metrics.pane_compress_passes += graphics_stats.compress_passes;
    }

    if (covered_before != client.view.graphicalToastsCover(notifications) or
        modal_covered_before != client.view.graphicalModalCoversPlan())
    {
        client.view.invalidate();
        try presenter.requestDraw();
    }
    if (presenter.mediaWorkPending(client)) {
        if (presenter.onlyWaitingForMediaIdle(client, media_idle)) {
            try presenter.requestMediaAt(presenter.last_input_ns +| toast_graphics.idle_after_ns);
        } else {
            try presenter.requestMedia();
        }
    }
}

fn mediaWorkPending(presenter: *const Presenter, client: *Client) bool {
    _ = presenter;
    return client.view.kittyAttachments().cleanupPending() or
        (client.model.hostCapabilities().kitty_graphics == .supported and
            (client.view.graphicsPreparationPending() or client.graphics_store.damage or
                client.view.kittySidebar().damaged() or client.view.kittyIcons().damaged() or
                client.view.kittyToasts().damaged() or client.view.kittyModal().damaged() or
                client.view.kittyAttachments().damaged()));
}

fn onlyWaitingForMediaIdle(presenter: *const Presenter, client: *Client, media_idle: bool) bool {
    _ = presenter;
    return !media_idle and !client.view.graphicsPreparationPending() and
        !client.graphics_store.damage and !client.view.kittySidebar().damaged() and
        !client.view.kittyIcons().damaged() and !client.view.kittyAttachments().damaged() and
        !client.view.kittyModal().damaged() and
        client.view.kittyToasts().waitingForMediaIdle();
}

fn observePresentation(presenter: *Presenter, presented_ns: u64) void {
    if (comptime diagnostics.enabled) {
        if (presenter.last_presented_ns) |previous| {
            presenter.metrics.paced_interval.observe(presented_ns -| previous);
        }
    }

    presenter.last_presented_ns = presented_ns;
}

pub const FrameAcks = struct {
    items: [multiplexer.max_panes]schema.FrameAck = undefined,
    len: usize = 0,

    /// Returns the frame acknowledgements produced by one host flush.
    ///
    /// ```zig
    /// for (delivery.frame_acks.slice()) |ack| send(ack);
    /// ```
    pub fn slice(acks: *const FrameAcks) []const schema.FrameAck {
        return acks.items[0..acks.len];
    }
};

pub const Delivery = struct {
    frame_acks: FrameAcks,
    media_pending: bool,
};

const Presented = struct {
    presented_ns: u64,
    acks: FrameAcks,
};

fn present(presenter: *Presenter, client: *Client, model: *multiplexer.Model) !Presented {
    const compose_started = diagnostics.now(presenter.io);
    const composed = try model.renderThemed(
        &presenter.screen,
        client.view.workbench(),
        client.view.palette(),
    );
    const chrome = try client.view.render(&presenter.screen, .{
        .tabs = &client.model.workspace,
        .model = model,
        .agents = client.model.agentSnapshot(),
        .sidebar_animation_frame = client.model.sidebarAnimationFrame(),
        .notifications = client.model.notificationSnapshot(),
        .workspaces = client.model.workspaceListSnapshot(),
        .prompt = client.model.name_prompt.current(),
        .proxy_tls_active = client.model.proxyTlsActive(),
        .system_metrics = client.model.systemMetrics(),
        .status_mode = client.host_input.statusMode(client.model.copyModeActive()),
        .force = composed.full,
        .diagnostic = client.model.diagnostic(),
    });
    if (comptime diagnostics.enabled) {
        presenter.metrics.composed_panes += composed.panes;
        presenter.metrics.composed_cells += composed.cells;
        presenter.metrics.composed_damage_cells += composed.damaged_cells;
        presenter.metrics.chrome_scanned_cells += chrome.scanned;
        presenter.metrics.chrome_damaged_cells += chrome.damaged;
        presenter.metrics.full_compositions += @intFromBool(composed.full);
        presenter.metrics.compose.observe(
            diagnostics.elapsed(compose_started, diagnostics.now(presenter.io)),
        );
    }
    // Graphics never enter this flush. The media event applies the fixed plan
    // produced above only after these cells have reached the host terminal.
    presenter.screen.graphics = null;
    try presenter.flushScreen(client.writer);
    var acks: FrameAcks = .{};
    var panes = model.paneIterator();
    while (panes.next()) |pane| {
        if (!pane.attached) {
            continue;
        }

        const frame_id = pane.takePendingFrame();
        if (frame_id == 0) {
            continue;
        }

        acks.items[acks.len] = .{ .pane_id = pane.id, .frame_id = frame_id };
        acks.len += 1;
    }
    return .{ .presented_ns = monotonic(presenter.io), .acks = acks };
}

fn presentEmpty(presenter: *Presenter, client: *Client) !Presented {
    const buffer = presenter.screen.buffer();
    buffer.clear(.{});
    presenter.screen.cursor = null;
    presenter.screen.graphics = null;
    try presenter.flushScreen(client.writer);

    return .{ .presented_ns = monotonic(presenter.io), .acks = .{} };
}

const CombinedGraphicsWriter = struct {
    panes: kitty.KittyGraphicsWriter,
    sidebar: *kitty.KittySidebarRenderer,
    icons: *icon_graphics.Renderer,
    toasts: *toast_graphics.Renderer,
    modal: *modal_graphics.Renderer,
    attachments: *attachments.Store,
    allow_toast_transmission: bool,
    metrics: *ClientMetrics,

    fn writeOpaque(context: *anyopaque, writer: *Io.Writer) Io.Writer.Error!usize {
        const self: *CombinedGraphicsWriter = @ptrCast(@alignCast(context));
        var pane_bytes: usize = 0;
        var toast_bytes: usize = 0;
        var sidebar_bytes: usize = 0;
        var icon_bytes: usize = 0;
        var modal_bytes: usize = 0;
        var attachment_bytes: usize = 0;

        // KGP continuation chunks do not identify their image. Whichever
        // renderer opened a transfer owns the graphics stream until it closes;
        // a pane, toast, or icon atlas can never interleave another transfer.
        if (self.attachments.transferInProgress()) {
            attachment_bytes = try self.attachments.write(writer);
        } else if (self.modal.transferInProgress()) {
            modal_bytes = try self.modal.write(writer);
        } else if (self.toasts.transferInProgress()) {
            toast_bytes = try self.toasts.write(
                writer,
                true,
            );
        } else if (self.icons.transferInProgress()) {
            icon_bytes = try self.icons.write(writer);
        } else {
            pane_bytes = try self.panes.write(writer);
            if (pane_bytes == 0 and self.panes.store.partial == null) {
                modal_bytes = try self.modal.write(writer);
                if (modal_bytes == 0) {
                    attachment_bytes = try self.attachments.write(writer);
                    if (attachment_bytes == 0) {
                        toast_bytes = try self.toasts.write(writer, self.allow_toast_transmission);
                        if (toast_bytes == 0) {
                            sidebar_bytes = try self.sidebar.write(writer);
                            if (sidebar_bytes == 0) {
                                icon_bytes = try self.icons.write(writer);
                            }
                        }
                    }
                }
            }
        }
        if (comptime diagnostics.enabled) {
            self.metrics.pane_graphics_flushed_bytes += pane_bytes;
            self.metrics.toast_graphics_flushed_bytes += toast_bytes;
            self.metrics.sidebar_graphics_flushed_bytes += sidebar_bytes;
            self.metrics.icon_graphics_flushed_bytes += icon_bytes;
            self.metrics.modal_graphics_flushed_bytes += modal_bytes;
            self.metrics.attachment_graphics_flushed_bytes += attachment_bytes;
        }
        return pane_bytes + toast_bytes + sidebar_bytes + icon_bytes + modal_bytes + attachment_bytes;
    }
};

fn flushScreen(presenter: *Presenter, writer: *Io.Writer) !void {
    const started = diagnostics.now(presenter.io);
    const stats = try presenter.screen.flush(writer);
    if (comptime diagnostics.enabled) {
        presenter.metrics.flushes += 1;
        presenter.metrics.scanned_cells += stats.scanned;
        presenter.metrics.flushed_cells += stats.cells;
        presenter.metrics.flushed_bytes += stats.bytes;
        presenter.metrics.graphics_flushed_bytes += stats.graphics_bytes;
        presenter.metrics.flush.observe(diagnostics.elapsed(started, diagnostics.now(presenter.io)));
    }
}

fn flushMedia(presenter: *Presenter, writer: *Io.Writer) !void {
    const started = diagnostics.now(presenter.io);
    const stats = try presenter.screen.flush(writer);
    if (comptime diagnostics.enabled) {
        presenter.metrics.media_flushes += 1;
        presenter.metrics.graphics_flushed_bytes += stats.graphics_bytes;
        presenter.metrics.media_flush.observe(diagnostics.elapsed(started, diagnostics.now(presenter.io)));
    }
}

fn waitToDraw(io: Io, deadline_ns: u64) anyerror!void {
    const deadline = Io.Timestamp.fromNanoseconds(@intCast(deadline_ns)).withClock(.awake);
    try deadline.wait(io);
}
