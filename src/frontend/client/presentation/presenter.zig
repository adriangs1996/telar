//! Frame pacing and presentation: the draw-request → deadline → compose →
//! cell-flush cycle, plus a lower-priority media pass. Owns the host-terminal
//! back/front buffers. Frame acks come back to the caller as values; the
//! client enqueues them.

const std = @import("std");
const core = @import("telar-core");
const client_clock = @import("../resources/clock.zig");
const agents = @import("../../agents/root.zig");
const graphics = @import("../../graphics/root.zig");
const attachments = @import("../../attachments/root.zig");
const bars = @import("../../bars/root.zig");
const notifications = @import("../../notifications/root.zig");
const presentation = @import("../../presentation/root.zig");
const workspace_capability = @import("../../workspace/root.zig");
const widgets = @import("../../widgets/root.zig");
const client_telemetry = @import("../resources/telemetry.zig");
const client_model = @import("../model/root.zig");
const client_view = @import("view.zig");
const name_prompt = @import("../model/name_prompt.zig");
const history_palette_state = @import("../model/history_palette.zig");
const suggestion_state = @import("../model/suggestion.zig");
const kitty = graphics.kitty;
const modal_graphics = graphics.modal;
const toast_graphics = graphics.toast;
const multiplexer = workspace_capability.multiplexer;
const tabs = workspace_capability.tabs;
const workspace_list = workspace_capability.workspace_list;
const pace = presentation.pace;
const term = presentation.screen;

const Io = std.Io;
const monotonic = client_clock.monotonic;
const schema = core.schema;
const diagnostics = core.diagnostics;
const icon_graphics = graphics.icons;

const ClientMetrics = client_telemetry.Metrics;

const Presenter = @This();

pub const Observation = struct {
    model: client_model.Version,
    graphics_ingress: u64,
    attachment_ingress: u64,
    presentation_ingress: PresentationIngress,
};

pub const PresentationIngress = struct {
    view_interaction: u64,
    input_routing: u64,
};

pub const Projection = struct {
    version: client_model.Version,
    presentation_ingress: PresentationIngress,
    model: ?*const multiplexer.Model,
    tabs: *const tabs.Model,
    agents: *const agents.Snapshot,
    sidebar_animation_frame: u8,
    notifications: *const notifications.Center,
    workspaces: *const workspace_list.Snapshot,
    prompt: ?name_prompt.Prompt,
    history: *const history_palette_state.State,
    suggestion: *const suggestion_state.State,
    proxy_tls_active: bool,
    system_metrics: ?client_model.SystemMetrics,
    bar_state: *const bars.State,
    status_mode: widgets.status_bar.Mode,
    diagnostic: ?[]const u8,
    copy: ?multiplexer.CopyProjection,
    sidebar_visible: bool,
    sidebar_width: u16,
    workspace_list_collapsed: bool,
    host_capabilities: client_model.HostCapabilities,
    host_size: schema.TerminalSize,
    /// Configured host window title template; empty leaves the host alone.
    window_title_template: []const u8 = "",
};

pub const Resources = struct {
    view: *client_view.State,
    graphics_store: *kitty.Store,
    writer: *Io.Writer,
};

pub const Scheduler = struct {
    context: *anyopaque,
    /// Arms one draw at an absolute deadline; the owner delivers `.draw`.
    draw: *const fn (*anyopaque, u64) anyerror!void,
    /// Presents synchronously, on the caller's thread, before returning. A
    /// frame the pacer lets through does not pay a timer task and a wakeup.
    draw_now: *const fn (*anyopaque) anyerror!void,
    media: *const fn (*anyopaque, u64) anyerror!void,
};

io: Io,
scheduler: Scheduler,
metrics: *ClientMetrics,
screen: term.Screen,
compositor: multiplexer.Compositor,
pacer: pace.Pacer = .{},
observed_model_version: client_model.Version = .{},
presented_model_version: client_model.Version = .{},
observed_graphics_ingress: u64 = 0,
presented_graphics_ingress: u64 = 0,
observed_attachment_ingress: u64 = 0,
presented_attachment_ingress: u64 = 0,
observed_presentation_ingress: PresentationIngress = .{
    .view_interaction = 0,
    .input_routing = 0,
},
presented_presentation_ingress: PresentationIngress = .{
    .view_interaction = 0,
    .input_routing = 0,
},
window_title: presentation.window_title.State = .{},
draw_pending: bool = false,
draw_due_ns: u64 = 0,
/// Whether the presentation being delivered waited for a pacer deadline.
/// Immediate presentations spend burst or input-grace frames instead.
draw_scheduled: bool = false,
media_tick_pending: bool = false,
/// A media tick found a cell frame pending and stepped aside. The frame's
/// completion arms the bulk pass immediately instead of a pacer interval
/// later, so graphics never lose a whole tick to a keystroke echo.
media_after_draw: bool = false,
pending_updates: usize = 0,
last_presented_ns: ?u64 = null,
/// When the last pane image reached the host, for the present interval.
last_pane_present_ns: ?u64 = null,
/// When the host terminal last delivered input bytes. Zero until the
/// first read, so a fresh session starts on the boosted media budget.
last_input_ns: u64 = 0,

/// Releases the host screen buffers.
///
/// ```zig
/// defer presenter.deinit();
/// ```
pub fn deinit(presenter: *Presenter) void {
    presenter.compositor.deinit();
    presenter.screen.deinit();
}

/// Resizes the host screen buffers to one validated terminal grid.
///
/// ```zig
/// try presenter.resize(80, 24);
/// ```
pub fn resize(presenter: *Presenter, cols: u16, rows: u16) !void {
    try presenter.screen.resize(cols, rows);
    presenter.compositor.invalidate();
}

/// Records host input activity for media-idle policy.
///
/// ```zig
/// presenter.noteInput(now_ns);
/// ```
pub fn noteInput(presenter: *Presenter, now_ns: u64) void {
    presenter.last_input_ns = now_ns;
    presenter.pacer.noteInput(now_ns);
}

/// Observes semantic and physical client revisions and schedules one frame.
///
/// ```zig
/// try presenter.observe(observation);
/// ```
pub fn observe(presenter: *Presenter, observation: Observation) !void {
    const newly_observed = !std.meta.eql(presenter.observed_model_version, observation.model) or
        presenter.observed_graphics_ingress != observation.graphics_ingress or
        presenter.observed_attachment_ingress != observation.attachment_ingress or
        !std.meta.eql(presenter.observed_presentation_ingress, observation.presentation_ingress);
    if (newly_observed) {
        presenter.observed_model_version = observation.model;
        presenter.observed_graphics_ingress = observation.graphics_ingress;
        presenter.observed_attachment_ingress = observation.attachment_ingress;
        presenter.observed_presentation_ingress = observation.presentation_ingress;
        try presenter.requestDraw();
        return;
    }

    const presentation_stale = !std.meta.eql(presenter.presented_model_version, observation.model) or
        presenter.presented_graphics_ingress != observation.graphics_ingress or
        presenter.presented_attachment_ingress != observation.attachment_ingress or
        !std.meta.eql(presenter.presented_presentation_ingress, observation.presentation_ingress);
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
    const now_ns = monotonic(presenter.io);
    if (presenter.pacer.waitUntil(now_ns)) |deadline_ns| {
        if (presenter.draw_pending) {
            return;
        }

        presenter.pacer.noteThrottled();
        presenter.draw_pending = true;
        presenter.draw_due_ns = deadline_ns;
        presenter.draw_scheduled = true;
        presenter.scheduler.draw(presenter.scheduler.context, deadline_ns) catch |err| {
            presenter.draw_pending = false;
            return err;
        };
        return;
    }

    // Present now even while a paced draw task is armed: input grace must
    // not wait behind a flood's cadence slot. The armed task keeps its token
    // and finds nothing pending when it fires.
    presenter.draw_due_ns = now_ns;
    presenter.draw_scheduled = false;
    try presenter.scheduler.draw_now(presenter.scheduler.context);
}

/// Arms one independently paced bulk media pass. Cell work always wins before
/// a pass starts, and each pass emits at most the baseline KGP byte budget. A
/// pass that yielded to the frame just presented runs right away.
///
/// ```zig
/// try presenter.requestMedia();
/// ```
pub fn requestMedia(presenter: *Presenter) !void {
    const now_ns = monotonic(presenter.io);
    const deadline_ns = if (presenter.media_after_draw) now_ns else now_ns +| pace.default_interval;
    presenter.media_after_draw = false;
    try presenter.requestMediaAt(deadline_ns);
}

fn requestMediaAt(presenter: *Presenter, deadline_ns: u64) !void {
    if (presenter.media_tick_pending) {
        return;
    }

    presenter.media_tick_pending = true;
    presenter.scheduler.media(presenter.scheduler.context, deadline_ns) catch |err| {
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
/// const delivery = try presenter.presentDue(projection, resources) orelse return;
/// ```
pub fn presentDue(presenter: *Presenter, projection: Projection, resources: Resources) !?Delivery {
    if (comptime diagnostics.enabled) {
        presenter.metrics.draw_lateness.observe(monotonic(presenter.io) -| presenter.draw_due_ns);
    }
    if (presenter.pending_updates == 0) {
        return null;
    }

    std.debug.assert(std.meta.eql(projection.version, presenter.observed_model_version));
    std.debug.assert(std.meta.eql(
        projection.presentation_ingress,
        presenter.observed_presentation_ingress,
    ));
    const workspace_changed = presenter.presented_model_version.workspace !=
        projection.version.workspace;
    const configuration_changed = presenter.presented_model_version.configuration !=
        projection.version.configuration;
    const diagnostic_changed = presenter.presented_model_version.diagnostic !=
        projection.version.diagnostic;
    const host_changed = presenter.presented_model_version.host !=
        projection.version.host;
    const workspace_list_changed = presenter.presented_model_version.workspace_list !=
        projection.version.workspace_list;
    const agents_changed = presenter.presented_model_version.agents !=
        projection.version.agents;
    const sidebar_animation_changed = presenter.presented_model_version.sidebar_animation !=
        projection.version.sidebar_animation;
    const proxy_status_changed = presenter.presented_model_version.proxy_status !=
        projection.version.proxy_status;
    const system_metrics_changed = presenter.presented_model_version.system_metrics !=
        projection.version.system_metrics;
    const bars_changed = presenter.presented_model_version.bars != projection.version.bars;
    const notifications_changed = presenter.presented_model_version.notifications !=
        projection.version.notifications;
    const tabs_changed = presenter.presented_model_version.tabs !=
        projection.version.tabs;
    const active_tab_changed = presenter.presented_model_version.active_tab !=
        projection.version.active_tab;
    const panes_changed = presenter.presented_model_version.panes !=
        projection.version.panes;
    const pane_metadata_changed = presenter.presented_model_version.pane_metadata !=
        projection.version.pane_metadata;
    const pane_foreground_changed = presenter.presented_model_version.pane_foreground !=
        projection.version.pane_foreground;
    const pane_graphics_changed = presenter.presented_model_version.pane_graphics !=
        projection.version.pane_graphics;
    const chrome_changed = presenter.presented_model_version.chrome !=
        projection.version.chrome;
    const prompt_changed = presenter.presented_model_version.prompt !=
        projection.version.prompt;
    const history_changed = presenter.presented_model_version.history !=
        projection.version.history;
    const suggestion_changed = presenter.presented_model_version.suggestion !=
        projection.version.suggestion;
    const viewport_changed = presenter.presented_model_version.viewport !=
        projection.version.viewport;
    const copy_status_changed = (presenter.compositor.copy == null) != (projection.copy == null);
    const view_interaction_changed = presenter.presented_presentation_ingress.view_interaction !=
        projection.presentation_ingress.view_interaction;
    const input_routing_changed = presenter.presented_presentation_ingress.input_routing !=
        projection.presentation_ingress.input_routing;
    if (chrome_changed) {
        resources.view.setSidebarLayout(projection.sidebar_visible, projection.sidebar_width);
        resources.view.setWorkspaceListCollapsed(projection.workspace_list_collapsed);
    }
    if (agents_changed) {
        resources.view.resetSidebarScroll();
    }
    if (prompt_changed) {
        resources.view.clearHover();
    }
    if (workspace_changed or configuration_changed or diagnostic_changed or host_changed or
        workspace_list_changed or agents_changed or sidebar_animation_changed or
        proxy_status_changed or system_metrics_changed or bars_changed or notifications_changed or tabs_changed or
        active_tab_changed or panes_changed or pane_metadata_changed or chrome_changed or
        prompt_changed or history_changed or suggestion_changed or copy_status_changed or
        view_interaction_changed or input_routing_changed)
    {
        resources.view.invalidate();
    }

    const force_composition = workspace_changed or configuration_changed or host_changed or
        active_tab_changed or panes_changed or pane_foreground_changed or pane_graphics_changed or
        viewport_changed;
    try presenter.syncWindowTitle(projection, resources.writer);
    const presented = if (projection.model) |model|
        try presenter.present(.{
            .projection = projection,
            .resources = resources,
            .model = model,
            .force = force_composition,
        })
    else
        try presenter.presentEmpty(resources);
    presenter.presented_model_version = projection.version;
    presenter.presented_graphics_ingress = presenter.observed_graphics_ingress;
    presenter.presented_attachment_ingress = presenter.observed_attachment_ingress;
    presenter.presented_presentation_ingress = projection.presentation_ingress;
    presenter.observePresentation(presented.presented_ns);
    presenter.pacer.record(
        presented.presented_ns,
        if (presenter.draw_scheduled) presenter.draw_due_ns else null,
        presenter.pending_updates,
    );
    presenter.pending_updates = 0;

    return .{
        .frame_acks = presented.acks,
        .commit = presented.commit,
        .media_pending = projection.model != null and mediaWorkPending(projection, resources),
    };
}

/// The bulk media event never composes cells. A pending or scheduled cell
/// frame defers it to that frame's completion, which gives interactive output
/// priority without concurrent writes corrupting the terminal protocol stream.
/// Shared names and placements do not wait here: the cell frame carries them.
///
/// ```zig
/// try presenter.presentMedia(projection, resources);
/// ```
pub fn presentMedia(presenter: *Presenter, projection: Projection, resources: Resources) !void {
    if (presenter.pending_updates != 0 or presenter.draw_pending) {
        if (comptime diagnostics.enabled) {
            presenter.metrics.media_deferrals += 1;
        }
        presenter.media_after_draw = true;
        return;
    }

    _ = projection.model orelse return;
    const media_idle = monotonic(presenter.io) -| presenter.last_input_ns >=
        toast_graphics.idle_after_ns;
    resources.view.kittyAttachments().reapRetired();
    const covered_before = resources.view.graphicalToastsCover(projection.notifications);
    const modal_covered_before = resources.view.graphicalModalCoversPlan();
    const icon_fallback_changed = try resources.view.prepareGraphics(projection.notifications, media_idle);
    if (icon_fallback_changed) {
        try presenter.requestDraw();
    }
    if (!mediaWorkPending(projection, resources)) {
        return;
    }
    if (onlyWaitingForMediaIdle(resources, media_idle)) {
        try presenter.requestMediaAt(presenter.last_input_ns +| toast_graphics.idle_after_ns);
        return;
    }

    resources.graphics_store.setHostZlib(projection.host_capabilities.kitty_zlib == .supported);
    var graphics_writer: CombinedGraphicsWriter = .{
        .panes = .{
            .store = resources.graphics_store,
            .layout_snapshot = presenter.compositor.layoutSnapshot(),
            .cell_width = projection.host_size.cell_width_px,
            .cell_height = projection.host_size.cell_height_px,
            .budget = kitty.transmission_budget_per_frame,
            .now_ns = if (comptime diagnostics.enabled) monotonic(presenter.io) else 0,
        },
        .sidebar = resources.view.kittySidebar(),
        .icons = resources.view.kittyIcons(),
        .toasts = resources.view.kittyToasts(),
        .modal = resources.view.kittyModal(),
        .attachments = resources.view.kittyAttachments(),
        .allow_toast_transmission = media_idle,
        .metrics = presenter.metrics,
    };
    presenter.screen.graphics = .{
        .context = &graphics_writer,
        .write = CombinedGraphicsWriter.writeOpaque,
    };
    try presenter.flushMedia(resources.writer);
    presenter.notePaneGraphics(graphics_writer.panes.stats);

    if (covered_before != resources.view.graphicalToastsCover(projection.notifications) or
        modal_covered_before != resources.view.graphicalModalCoversPlan())
    {
        resources.view.invalidate();
        try presenter.requestDraw();
    }
    if (mediaWorkPending(projection, resources)) {
        if (onlyWaitingForMediaIdle(resources, media_idle)) {
            try presenter.requestMediaAt(presenter.last_input_ns +| toast_graphics.idle_after_ns);
        } else {
            try presenter.requestMedia();
        }
    }
}

fn notePaneGraphics(presenter: *Presenter, graphics_stats: kitty.KittyGraphicsWriter.Stats) void {
    if (comptime !diagnostics.enabled) return;
    presenter.metrics.pane_shared_images += graphics_stats.shared_images;
    presenter.metrics.pane_inline_images += graphics_stats.inline_images;
    presenter.metrics.pane_compressed_images += graphics_stats.compressed_images;
    presenter.metrics.pane_transmission_passes += graphics_stats.transmission_passes;
    presenter.metrics.pane_compress_passes += graphics_stats.compress_passes;
    if (graphics_stats.shared_images + graphics_stats.inline_images != 0) {
        const presented_ns = monotonic(presenter.io);
        if (presenter.last_pane_present_ns) |previous| {
            presenter.metrics.pane_present_interval.observe(presented_ns -| previous);
        }
        presenter.last_pane_present_ns = presented_ns;
    }
}

/// Whether the cell frame may carry pane graphics control escapes. Any open
/// chunked transfer owns the graphics stream, so the frame stays clean until
/// the bulk pass closes it.
fn controlGraphicsReady(projection: Projection, resources: Resources) bool {
    if (projection.host_capabilities.kitty_graphics != .supported) return false;
    if (!resources.graphics_store.damage or resources.graphics_store.partial != null) return false;
    const view = resources.view;
    return !view.kittyAttachments().transferInProgress() and
        !view.kittyModal().transferInProgress() and
        !view.kittyToasts().transferInProgress() and
        !view.kittyIcons().transferInProgress();
}

fn mediaWorkPending(projection: Projection, resources: Resources) bool {
    return resources.view.kittyAttachments().cleanupPending() or
        (projection.host_capabilities.kitty_graphics == .supported and
            (resources.view.graphicsPreparationPending() or resources.graphics_store.damage or
                resources.view.kittySidebar().damaged() or resources.view.kittyIcons().damaged() or
                resources.view.kittyToasts().damaged() or resources.view.kittyModal().damaged() or
                resources.view.kittyAttachments().damaged()));
}

fn onlyWaitingForMediaIdle(resources: Resources, media_idle: bool) bool {
    return !media_idle and !resources.view.graphicsPreparationPending() and
        !resources.graphics_store.damage and !resources.view.kittySidebar().damaged() and
        !resources.view.kittyIcons().damaged() and !resources.view.kittyAttachments().damaged() and
        !resources.view.kittyModal().damaged() and
        resources.view.kittyToasts().waitingForMediaIdle();
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
    commit: multiplexer.PresentationCommit,
    media_pending: bool,
};

const Presented = struct {
    presented_ns: u64,
    acks: FrameAcks,
    commit: multiplexer.PresentationCommit,
};

const CellPresentation = struct {
    projection: Projection,
    resources: Resources,
    model: *const multiplexer.Model,
    force: bool,
};

fn present(presenter: *Presenter, input: CellPresentation) !Presented {
    const compose_started = diagnostics.now(presenter.io);
    const composed = try presenter.compositor.render(.{
        .model = input.model,
        .screen = &presenter.screen,
        .input = .{
            .area = input.resources.view.workbench(),
            .palette = input.resources.view.palette(),
            .copy = input.projection.copy,
            .bottom_reservation = input.resources.view.attachmentReservation(),
            .force = input.force,
        },
    });
    var prompt = input.projection.prompt;
    const chrome = try input.resources.view.render(&presenter.screen, .{
        .tabs = input.projection.tabs,
        .model = input.model,
        .compositor = &presenter.compositor,
        .agents = input.projection.agents,
        .sidebar_animation_frame = input.projection.sidebar_animation_frame,
        .notifications = input.projection.notifications,
        .workspaces = input.projection.workspaces,
        .prompt = if (prompt) |*value| value else null,
        .history = input.projection.history,
        .suggestion = input.projection.suggestion,
        .proxy_tls_active = input.projection.proxy_tls_active,
        .system_metrics = input.projection.system_metrics,
        .copy_mode_active = input.projection.copy != null,
        .bar_state = input.projection.bar_state,
        .status_mode = input.projection.status_mode,
        .force = composed.stats.full,
        .diagnostic = input.projection.diagnostic,
    });
    if (comptime diagnostics.enabled) {
        presenter.metrics.composed_panes += composed.stats.panes;
        presenter.metrics.composed_cells += composed.stats.cells;
        presenter.metrics.composed_damage_cells += composed.stats.damaged_cells;
        presenter.metrics.chrome_scanned_cells += chrome.scanned;
        presenter.metrics.chrome_damaged_cells += chrome.damaged;
        presenter.metrics.full_compositions += @intFromBool(composed.stats.full);
        presenter.metrics.compose.observe(
            diagnostics.elapsed(compose_started, diagnostics.now(presenter.io)),
        );
    }
    // Pane graphics that are only names, placements and deletes ride inside
    // this synchronized update, after the cells and before the cursor. Pixel
    // streams and UI rasters wait for the byte-bounded bulk media pass.
    var control_writer: kitty.KittyGraphicsWriter = .{
        .store = input.resources.graphics_store,
        .layout_snapshot = presenter.compositor.layoutSnapshot(),
        .cell_width = input.projection.host_size.cell_width_px,
        .cell_height = input.projection.host_size.cell_height_px,
        .mode = .control,
        .now_ns = if (comptime diagnostics.enabled) monotonic(presenter.io) else 0,
    };
    presenter.screen.graphics = if (controlGraphicsReady(input.projection, input.resources)) .{
        .context = &control_writer,
        .write = kitty.KittyGraphicsWriter.writeOpaque,
    } else null;
    try presenter.flushScreen(input.resources.writer);
    presenter.notePaneGraphics(control_writer.stats);
    var acks: FrameAcks = .{};
    for (composed.commit.slice()) |pane| {
        if (!pane.attached or pane.frame_id == 0) {
            continue;
        }

        acks.items[acks.len] = .{ .pane_id = pane.pane_id, .frame_id = pane.frame_id };
        acks.len += 1;
    }
    return .{
        .presented_ns = monotonic(presenter.io),
        .acks = acks,
        .commit = composed.commit,
    };
}

fn presentEmpty(presenter: *Presenter, resources: Resources) !Presented {
    presenter.compositor.invalidate();
    const buffer = presenter.screen.buffer();
    buffer.clear(.{});
    presenter.screen.cursor = null;
    presenter.screen.mouse_pointer = .default;
    presenter.screen.graphics = null;
    try presenter.flushScreen(resources.writer);

    return .{ .presented_ns = monotonic(presenter.io), .acks = .{}, .commit = .{} };
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

/// Sends the host window title when the rendered template changes. The
/// bytes join the frame already being flushed, so a title never costs an
/// extra host write.
fn syncWindowTitle(presenter: *Presenter, projection: Projection, writer: *Io.Writer) !void {
    const tab_label = if (projection.tabs.activeConst()) |tab| tab.labelSlice() else "";
    const pane_title = if (projection.model) |model| focusedPaneTitle(model) else "";

    try presenter.window_title.sync(writer, projection.window_title_template, .{
        .workspace = projection.tabs.workspaceName(),
        .tab = tab_label,
        .pane_title = pane_title,
    });
}

fn focusedPaneTitle(model: *const multiplexer.Model) []const u8 {
    const pane_id = model.layout.focused() orelse return "";
    const pane = model.findConst(pane_id) orelse return "";
    return pane.titleSlice();
}

fn flushScreen(presenter: *Presenter, writer: *Io.Writer) !void {
    const started = diagnostics.now(presenter.io);
    const stats = try presenter.screen.flush(writer);
    if (comptime diagnostics.enabled) {
        presenter.metrics.flushes += 1;
        presenter.metrics.scanned_cells += stats.scanned;
        presenter.metrics.flushed_cells += stats.cells;
        presenter.metrics.flushed_bytes += stats.bytes;
        presenter.metrics.graphics_flushed_bytes += stats.graphics_bytes;
        // Only pane control escapes ride the cell frame.
        presenter.metrics.pane_graphics_flushed_bytes += stats.graphics_bytes;
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
