//! Frame pacing and presentation: the draw-request → deadline → compose →
//! cell-flush cycle, plus a lower-priority media pass. Owns the host-terminal
//! back/front buffers. Shared presentation tokens become commits only after
//! the host output adapter reports successful delivery.

const data = @import("model");
const client = @import("telar-client");
const core = @import("telar-core");
const std = @import("std");
const Screen = @import("../../presentation/Screen.zig");
const Compositor = @import("../../workspace/Compositor.zig");
const State = @import("../../presentation/State.zig");
const toast_graphics = @import("../../graphics/toast.zig");
const KittySidebarRenderer = @import("../../graphics/KittySidebarRenderer.zig");
const IconsRenderer = @import("../../graphics/IconsRenderer.zig");
const ToastRenderer = @import("../../graphics/ToastRenderer.zig");
const ModalRenderer = @import("../../graphics/ModalRenderer.zig");
const kitty_codec = @import("../../graphics/kitty_codec.zig");
const Stats = @import("../../graphics/Stats.zig");
const delivery_module = @import("../../attachments/delivery.zig");
const CellPresentation = @import("CellPresentation.zig");
const Presented = @import("Presented.zig");
const KittyGraphicsWriter = @import("../../graphics/KittyGraphicsWriter.zig");
const PillRenderer = @import("../../graphics/PillRenderer.zig");

const Presenter = @This();

pub const Token = client.Token;

pub const Observation = client.Observation;

pub const PresentationIngress = client.PresentationIngress;

pub const Projection = client.Projection;

pub const Resources = @import("Resources.zig");

pub const Scheduler = @import("Scheduler.zig");

io: std.Io,
scheduler: Scheduler,
metrics: *client.TelemetryMetrics,
screen: Screen,
compositor: Compositor,
pacer: core.Pacer = .{},
/// The client's one presentation lifecycle, borrowed for the presenter's
/// life.
presentation_state: *client.PresentationLifecycleState,
window_title: State = .{},
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
pub fn deinit(self: *Presenter) void {
    self.compositor.deinit();
    self.screen.deinit();
}

/// Resizes the host screen buffers to one validated terminal grid.
///
/// ```zig
/// try presenter.resize(80, 24);
/// ```
pub fn resize(self: *Presenter, cols: u16, rows: u16) !void {
    try self.screen.resize(cols, rows);
    self.compositor.invalidate();
}

/// Records host input activity for media-idle policy.
///
/// ```zig
/// presenter.noteInput(now_ns);
/// ```
pub fn noteInput(self: *Presenter, now_ns: u64) void {
    self.last_input_ns = now_ns;
    self.pacer.noteInput(now_ns);
}

/// Observes semantic and physical client revisions and schedules one frame.
///
/// ```zig
/// try presenter.observe(observation);
/// ```
pub fn observe(self: *Presenter, observation: client.Observation) !void {
    if (self.presentation_state.observe(observation)) {
        try self.requestDraw();
        return;
    }
    if (self.presentation_state.needsPreparation() and !self.draw_pending) {
        try self.requestDraw();
    }
}

/// Registers one pending update and arms the paced draw timer if none is
/// armed. What does not fit the frame budget folds into the next frame.
///
/// ```zig
/// try presenter.requestDraw();
/// ```
pub fn requestDraw(self: *Presenter) !void {
    self.pending_updates +|= 1;
    if (comptime core.enabled) {
        self.metrics.max_pending_updates = @max(
            self.metrics.max_pending_updates,
            self.pending_updates,
        );
    }
    const now_ns = client.monotonic(self.io);
    if (self.pacer.waitUntil(now_ns)) |deadline_ns| {
        if (self.draw_pending) {
            return;
        }

        self.pacer.noteThrottled();
        self.draw_pending = true;
        self.draw_due_ns = deadline_ns;
        self.draw_scheduled = true;
        self.scheduler.draw(self.scheduler.context, deadline_ns) catch |err| {
            self.draw_pending = false;
            return err;
        };
        return;
    }

    // Present now even while a paced draw task is armed: input grace must
    // not wait behind a flood's cadence slot. The armed task keeps its token
    // and finds nothing pending when it fires.
    self.draw_due_ns = now_ns;
    self.draw_scheduled = false;
    try self.scheduler.draw_now(self.scheduler.context);
}

/// Arms one independently paced bulk media pass. Cell work always wins before
/// a pass starts, and each pass emits at most the baseline KGP byte budget. A
/// pass that yielded to the frame just presented runs right away.
///
/// ```zig
/// try presenter.requestMedia();
/// ```
pub fn requestMedia(self: *Presenter) !void {
    const now_ns = client.monotonic(self.io);
    const deadline_ns = if (self.media_after_draw) now_ns else now_ns +| core.pace.default_interval;
    self.media_after_draw = false;
    try self.requestMediaAt(deadline_ns);
}

fn requestMediaAt(self: *Presenter, deadline_ns: u64) !void {
    if (self.media_tick_pending) {
        return;
    }

    self.media_tick_pending = true;
    self.scheduler.media(self.scheduler.context, deadline_ns) catch |err| {
        self.media_tick_pending = false;
        return err;
    };
}

/// Releases the single draw-task token before propagating its result.
///
/// ```zig
/// try presenter.completeDraw(result);
/// ```
pub fn completeDraw(self: *Presenter, result: anyerror!void) !void {
    self.draw_pending = false;

    try result;
}

/// Releases the single media-task token before propagating its result.
///
/// ```zig
/// try presenter.completeMediaTick(result);
/// ```
pub fn completeMediaTick(self: *Presenter, result: anyerror!void) !void {
    self.media_tick_pending = false;

    try result;
}

/// The `.draw` event: presents the latest client model, including its
/// explicit empty state during startup and workspace handoff.
///
/// ```zig
/// const token = try presenter.presentDue(projection, resources) orelse return;
/// ```
pub fn presentDue(self: *Presenter, projection: client.Projection, resources: Resources) !?client.Token {
    if (comptime core.enabled) {
        self.metrics.draw_lateness.observe(client.monotonic(self.io) -| self.draw_due_ns);
    }
    if (self.pending_updates == 0 or self.presentation_state.active != null) {
        return null;
    }

    std.debug.assert(std.meta.eql(projection.version, self.presentation_state.observed.model));
    std.debug.assert(std.meta.eql(
        projection.presentation_ingress,
        self.presentation_state.observed.presentation_ingress,
    ));
    const workspace_changed = self.presentation_state.prepared.model.workspace !=
        projection.version.workspace;
    const configuration_changed = self.presentation_state.prepared.model.configuration !=
        projection.version.configuration;
    const diagnostic_changed = self.presentation_state.prepared.model.diagnostic !=
        projection.version.diagnostic;
    const host_changed = self.presentation_state.prepared.model.host !=
        projection.version.host;
    const workspace_list_changed = self.presentation_state.prepared.model.workspace_list !=
        projection.version.workspace_list;
    const agents_changed = self.presentation_state.prepared.model.agents !=
        projection.version.agents;
    const sidebar_animation_changed = self.presentation_state.prepared.model.sidebar_animation !=
        projection.version.sidebar_animation;
    const proxy_status_changed = self.presentation_state.prepared.model.proxy_status !=
        projection.version.proxy_status;
    const system_metrics_changed = self.presentation_state.prepared.model.system_metrics !=
        projection.version.system_metrics;
    const bars_changed = self.presentation_state.prepared.model.bars != projection.version.bars;
    const notifications_changed = self.presentation_state.prepared.model.notifications !=
        projection.version.notifications;
    const tabs_changed = self.presentation_state.prepared.model.tabs !=
        projection.version.tabs;
    const active_tab_changed = self.presentation_state.prepared.model.active_tab !=
        projection.version.active_tab;
    const panes_changed = self.presentation_state.prepared.model.panes !=
        projection.version.panes;
    const pane_metadata_changed = self.presentation_state.prepared.model.pane_metadata !=
        projection.version.pane_metadata;
    const pane_foreground_changed = self.presentation_state.prepared.model.pane_foreground !=
        projection.version.pane_foreground;
    const pane_progress_changed = self.presentation_state.prepared.model.pane_progress !=
        projection.version.pane_progress;
    const pane_graphics_changed = self.presentation_state.prepared.model.pane_graphics !=
        projection.version.pane_graphics;
    const chrome_changed = self.presentation_state.prepared.model.chrome !=
        projection.version.chrome;
    const prompt_changed = self.presentation_state.prepared.model.prompt !=
        projection.version.prompt;
    const history_changed = self.presentation_state.prepared.model.history !=
        projection.version.history;
    const suggestion_changed = self.presentation_state.prepared.model.suggestion !=
        projection.version.suggestion;
    const path_completion_changed = self.presentation_state.prepared.model.path_completion !=
        projection.version.path_completion;
    const viewport_changed = self.presentation_state.prepared.model.viewport !=
        projection.version.viewport;
    const was_copy_mode = if (self.compositor.copy) |copy| !copy.view.pointer else false;
    const is_copy_mode = if (projection.copy) |copy| !copy.view.pointer else false;
    const copy_status_changed = was_copy_mode != is_copy_mode;
    const view_interaction_changed = self.presentation_state.prepared.presentation_ingress.view_interaction !=
        projection.presentation_ingress.view_interaction;
    const input_routing_changed = self.presentation_state.prepared.presentation_ingress.input_routing !=
        projection.presentation_ingress.input_routing;
    if (agents_changed) {
        resources.view.resetSidebarScroll();
    }
    if (prompt_changed or copy_status_changed) {
        resources.view.clearHover();
    }
    if (workspace_changed or configuration_changed or diagnostic_changed or host_changed or
        workspace_list_changed or agents_changed or sidebar_animation_changed or
        proxy_status_changed or system_metrics_changed or bars_changed or notifications_changed or tabs_changed or
        active_tab_changed or panes_changed or pane_metadata_changed or chrome_changed or
        pane_progress_changed or
        prompt_changed or history_changed or suggestion_changed or path_completion_changed or copy_status_changed or
        view_interaction_changed or input_routing_changed)
    {
        resources.view.invalidate();
    }

    const force_composition = workspace_changed or configuration_changed or host_changed or
        active_tab_changed or panes_changed or pane_foreground_changed or pane_graphics_changed or
        viewport_changed;
    try self.syncWindowTitle(projection, resources.writer);
    const presented = if (projection.tab) |tab|
        try self.present(.{
            .projection = projection,
            .resources = resources,
            .tab = tab,
            .force = force_composition,
        })
    else
        try self.presentEmpty(projection, resources);
    const geometry = client.Geometry.capture(projection);
    const token = try self.presentation_state.begin(.{
        .observation = self.presentation_state.observed,
        .commit = presented.commit,
        .geometry = geometry,
        .media_pending = projection.tab != null and mediaWorkPending(projection, resources),
    });
    self.observePresentation(presented.presented_ns);
    self.pacer.record(.{
        .now = presented.presented_ns,
        .scheduled_deadline = if (self.draw_scheduled) self.draw_due_ns else null,
        .absorbed = self.pending_updates,
    });
    self.pending_updates = 0;

    return token;
}

/// The bulk media event never composes cells. A pending or scheduled cell
/// frame defers it to that frame's completion, which gives interactive output
/// priority without concurrent writes corrupting the terminal protocol stream.
/// Shared names and placements do not wait here: the cell frame carries them.
///
/// ```zig
/// try presenter.presentMedia(projection, resources);
/// ```
pub fn presentMedia(self: *Presenter, projection: client.Projection, resources: Resources) !void {
    if (self.pending_updates != 0 or self.draw_pending) {
        if (comptime core.enabled) {
            self.metrics.media_deferrals += 1;
        }
        self.media_after_draw = true;
        return;
    }

    _ = projection.tab orelse return;
    const media_idle = client.monotonic(self.io) -| self.last_input_ns >=
        toast_graphics.idle_after_ns;
    resources.view.kittyAttachments().reapRetired();
    const covered_before = resources.view.graphicalToastsCover(projection.notifications);
    const modal_covered_before = resources.view.graphicalModalCoversPlan();
    const pill_covered_before = resources.view.graphicalPillCoversPlan();
    const icon_fallback_changed = try resources.view.prepareGraphics(projection.notifications, media_idle);
    if (icon_fallback_changed) {
        try self.requestDraw();
    }
    if (!mediaWorkPending(projection, resources)) {
        return;
    }
    if (onlyWaitingForMediaIdle(resources, media_idle)) {
        try self.requestMediaAt(self.last_input_ns +| toast_graphics.idle_after_ns);
        return;
    }

    var graphics_writer: CombinedGraphicsWriter = .{
        .panes = .{
            .store = resources.graphics_store,
            .layout_snapshot = self.compositor.layoutSnapshot(),
            .cell_width = projection.host_size.cell_width_px,
            .cell_height = projection.host_size.cell_height_px,
            .budget = kitty_codec.transmission_budget_per_frame,
            .now_ns = if (comptime core.enabled) client.monotonic(self.io) else 0,
        },
        .sidebar = resources.view.kittySidebar(),
        .icons = resources.view.kittyIcons(),
        .toasts = resources.view.kittyToasts(),
        .modal = resources.view.kittyModal(),
        .pill = resources.view.kittyPill(),
        .attachments = resources.view.kittyAttachments(),
        .allow_toast_transmission = media_idle,
        .metrics = self.metrics,
    };
    self.screen.graphics = .{
        .context = &graphics_writer,
        .write = CombinedGraphicsWriter.writeOpaque,
    };
    try self.flushMedia(resources.writer);
    self.notePaneGraphics(graphics_writer.panes.stats);

    if (covered_before != resources.view.graphicalToastsCover(projection.notifications) or
        modal_covered_before != resources.view.graphicalModalCoversPlan() or
        pill_covered_before != resources.view.graphicalPillCoversPlan())
    {
        resources.view.invalidate();
        try self.requestDraw();
    }
    if (mediaWorkPending(projection, resources)) {
        if (onlyWaitingForMediaIdle(resources, media_idle)) {
            try self.requestMediaAt(self.last_input_ns +| toast_graphics.idle_after_ns);
        } else {
            try self.requestMedia();
        }
    }
}

fn notePaneGraphics(self: *Presenter, graphics_stats: Stats) void {
    if (comptime !core.enabled) {
        return;
    }
    self.metrics.pane_shared_images += graphics_stats.shared_images;
    self.metrics.pane_inline_images += graphics_stats.inline_images;
    self.metrics.pane_compressed_images += graphics_stats.compressed_images;
    self.metrics.pane_transmission_passes += graphics_stats.transmission_passes;
    self.metrics.pane_compress_passes += graphics_stats.compress_passes;
    if (graphics_stats.shared_images + graphics_stats.inline_images != 0) {
        const presented_ns = client.monotonic(self.io);
        if (self.last_pane_present_ns) |previous| {
            self.metrics.pane_present_interval.observe(presented_ns -| previous);
        }
        self.last_pane_present_ns = presented_ns;
    }
}

/// Whether the cell frame may carry pane graphics control escapes. Any open
/// chunked transfer owns the graphics stream, so the frame stays clean until
/// the bulk pass closes it.
fn controlGraphicsReady(projection: client.Projection, resources: Resources) bool {
    const pane_control = projection.host_capabilities.images == .supported and resources.graphics_store.damage;
    if ((!pane_control and !resources.view.kittyPill().retirementPending()) or resources.graphics_store.delivery.partial != null) {
        return false;
    }

    const view = resources.view;
    return !delivery_module.transferInProgress(view.kittyAttachments()) and
        !view.kittyModal().transferInProgress() and
        !view.kittyPill().transferInProgress() and
        !view.kittyToasts().transferInProgress() and
        !view.kittyIcons().transferInProgress();
}

fn mediaWorkPending(projection: client.Projection, resources: Resources) bool {
    return resources.view.kittyPill().damaged() or resources.view.kittyAttachments().cleanupPending() or
        (projection.host_capabilities.images == .supported and
            (resources.view.graphicsPreparationPending() or resources.graphics_store.damage or
                resources.view.kittySidebar().damaged() or resources.view.kittyIcons().damaged() or
                resources.view.kittyToasts().damaged() or resources.view.kittyModal().damaged() or
                delivery_module.damaged(resources.view.kittyAttachments())));
}

fn onlyWaitingForMediaIdle(resources: Resources, media_idle: bool) bool {
    return !media_idle and !resources.view.graphicsPreparationPending() and
        !resources.graphics_store.damage and !resources.view.kittySidebar().damaged() and
        !resources.view.kittyIcons().damaged() and !delivery_module.damaged(resources.view.kittyAttachments()) and
        !resources.view.kittyModal().damaged() and !resources.view.kittyPill().damaged() and
        resources.view.kittyToasts().waitingForMediaIdle();
}

fn observePresentation(self: *Presenter, presented_ns: u64) void {
    if (comptime core.enabled) {
        if (self.last_presented_ns) |previous| {
            self.metrics.paced_interval.observe(presented_ns -| previous);
        }
    }

    self.last_presented_ns = presented_ns;
}

pub const Delivery = client.PresentationDelivery;

fn present(self: *Presenter, input: CellPresentation) !Presented {
    const compose_started = core.now(self.io);
    const composed = try self.compositor.render(.{
        .model = input.projection.model,
        .tab = input.tab,
        .screen = &self.screen,
        .input = .{
            .area = input.resources.view.workbench(),
            .palette = input.resources.view.palette(),
            .copy = input.projection.copy,
            .bottom_reservation = input.resources.view.attachmentReservation(),
            .progress_animation_frame = input.projection.sidebar_animation_frame,
            .force = input.force,
            .agents = input.projection.agents,
            .agents_revision = input.projection.version.agents,
        },
    });
    var prompt = input.projection.prompt;
    const chrome = try input.resources.view.render(&self.screen, .{
        .model = input.projection.model,
        .tab = input.tab,
        .compositor = &self.compositor,
        .agents = input.projection.agents,
        .sidebar_animation_frame = input.projection.sidebar_animation_frame,
        .notifications = input.projection.notifications,
        .workspaces = input.projection.workspaces,
        .prompt = if (prompt) |*value| value else null,
        .history = input.projection.history,
        .suggestion = input.projection.suggestion,
        .path_completion = input.projection.path_completion,
        .proxy_tls_active = input.projection.proxy_tls_active,
        .proxy_tls_scope = input.projection.proxy_tls_scope,
        .proxy_system_trusted = input.projection.proxy_system_trusted,
        .system_metrics = input.projection.system_metrics,
        .copy_mode_active = if (input.projection.copy) |copy| !copy.view.pointer else false,
        .bar_state = input.projection.bar_state,
        .status_mode = input.projection.status_mode,
        .force = composed.stats.full,
        .diagnostic = input.projection.diagnostic,
    });
    if (comptime core.enabled) {
        self.metrics.composed_panes += composed.stats.panes;
        self.metrics.composed_cells += composed.stats.cells;
        self.metrics.composed_damage_cells += composed.stats.damaged_cells;
        self.metrics.chrome_scanned_cells += chrome.scanned;
        self.metrics.chrome_damaged_cells += chrome.damaged;
        self.metrics.full_compositions += @intFromBool(composed.stats.full);
        self.metrics.compose.observe(
            core.elapsed(compose_started, core.now(self.io)),
        );
    }
    // Pane graphics that are only names, placements and deletes ride inside
    // this synchronized update, after the cells and before the cursor. Pixel
    // streams and UI rasters wait for the byte-bounded bulk media pass.
    var control_writer: CellGraphicsWriter = .{
        .panes = if (input.projection.host_capabilities.images == .supported) .{
            .store = input.resources.graphics_store,
            .layout_snapshot = self.compositor.layoutSnapshot(),
            .cell_width = input.projection.host_size.cell_width_px,
            .cell_height = input.projection.host_size.cell_height_px,
            .mode = .control,
            .now_ns = if (comptime core.enabled) client.monotonic(self.io) else 0,
        } else null,
        .pill = input.resources.view.kittyPill(),
    };
    self.screen.graphics = if (controlGraphicsReady(input.projection, input.resources)) .{
        .context = &control_writer,
        .write = CellGraphicsWriter.writeOpaque,
    } else null;
    try self.flushScreen(input.resources.writer);
    if (control_writer.panes) |panes| {
        self.notePaneGraphics(panes.stats);
    }

    if (comptime core.enabled) {
        self.metrics.pill_graphics_flushed_bytes += control_writer.pill_bytes;
    }
    return .{
        .presented_ns = client.monotonic(self.io),
        .commit = composed.commit,
    };
}

fn presentEmpty(self: *Presenter, projection: client.Projection, resources: Resources) !Presented {
    self.compositor.invalidate();
    resources.view.kittyPill().observe(&.{}, resources.view.palette());
    const buffer = self.screen.buffer();
    buffer.clear(.{});
    self.screen.cursor = null;
    self.screen.mouse_pointer = .default;
    var control_writer: CellGraphicsWriter = .{ .pill = resources.view.kittyPill() };
    self.screen.graphics = if (controlGraphicsReady(projection, resources)) .{
        .context = &control_writer,
        .write = CellGraphicsWriter.writeOpaque,
    } else null;
    try self.flushScreen(resources.writer);
    if (comptime core.enabled) {
        self.metrics.pill_graphics_flushed_bytes += control_writer.pill_bytes;
    }

    return .{ .presented_ns = client.monotonic(self.io), .commit = .{} };
}

/// Sends the host window title when the rendered template changes. The
/// bytes join the frame already being flushed, so a title never costs an
/// extra host write.
fn syncWindowTitle(self: *Presenter, projection: client.Projection, writer: *std.Io.Writer) !void {
    const tab_label = if (projection.tab) |tab| data.tab_label.text(projection.model, tab) else "";
    const pane_title = projection.model.focusedPaneTitle();

    try self.window_title.sync(writer, .{
        .template = projection.window_title_template,
        .tokens = .{
            .workspace = projection.model.workspaceName(),
            .tab = tab_label,
            .pane_title = pane_title,
        },
    });
}

fn flushScreen(self: *Presenter, writer: *std.Io.Writer) !void {
    const started = core.now(self.io);
    const stats = try self.screen.flush(writer);
    if (comptime core.enabled) {
        self.metrics.flushes += 1;
        self.metrics.scanned_cells += stats.scanned;
        self.metrics.flushed_cells += stats.cells;
        self.metrics.flushed_bytes += stats.bytes;
        self.metrics.graphics_flushed_bytes += stats.graphics_bytes;
        // Only pane control escapes ride the cell frame.
        self.metrics.pane_graphics_flushed_bytes += stats.graphics_bytes;
        self.metrics.flush.observe(core.elapsed(started, core.now(self.io)));
    }
}

fn flushMedia(self: *Presenter, writer: *std.Io.Writer) !void {
    const started = core.now(self.io);
    const stats = try self.screen.flush(writer);
    if (comptime core.enabled) {
        self.metrics.media_flushes += 1;
        self.metrics.graphics_flushed_bytes += stats.graphics_bytes;
        self.metrics.media_flush.observe(core.elapsed(started, core.now(self.io)));
    }
}

const CellGraphicsWriter = struct {
    panes: ?KittyGraphicsWriter = null,
    pill: *PillRenderer,
    pill_bytes: usize = 0,

    pub fn writeOpaque(context: *anyopaque, writer: *std.Io.Writer) std.Io.Writer.Error!usize {
        const self: *CellGraphicsWriter = @ptrCast(@alignCast(context));
        self.pill_bytes = try self.pill.writeRetirements(writer);
        const pane_bytes = if (self.panes) |*panes| try panes.write(writer) else 0;
        return self.pill_bytes + pane_bytes;
    }
};

const CombinedGraphicsWriter = struct {
    panes: KittyGraphicsWriter,
    sidebar: *KittySidebarRenderer,
    icons: *IconsRenderer,
    toasts: *ToastRenderer,
    modal: *ModalRenderer,
    pill: *PillRenderer,
    attachments: *delivery_module.Store,
    allow_toast_transmission: bool,
    metrics: *client.TelemetryMetrics,

    pub fn writeOpaque(context: *anyopaque, writer: *std.Io.Writer) std.Io.Writer.Error!usize {
        const self: *CombinedGraphicsWriter = @ptrCast(@alignCast(context));
        var pane_bytes: usize = 0;
        var toast_bytes: usize = 0;
        var sidebar_bytes: usize = 0;
        var icon_bytes: usize = 0;
        var modal_bytes: usize = 0;
        var pill_bytes: usize = 0;
        var attachment_bytes: usize = 0;

        // KGP continuation chunks do not identify their image. Whichever
        // renderer opened a transfer owns the graphics stream until it closes;
        // a pane, toast, or icon atlas can never interleave another transfer.
        if (delivery_module.transferInProgress(self.attachments)) {
            attachment_bytes = try delivery_module.write(self.attachments, writer);
        } else if (self.pill.transferInProgress()) {
            pill_bytes = try self.pill.write(writer);
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
            if (pane_bytes == 0 and self.panes.store.delivery.partial == null) {
                modal_bytes = try self.modal.write(writer);
                if (modal_bytes == 0) {
                    attachment_bytes = try delivery_module.write(self.attachments, writer);
                    if (attachment_bytes == 0) {
                        toast_bytes = try self.toasts.write(writer, self.allow_toast_transmission);
                        if (toast_bytes == 0) {
                            sidebar_bytes = try self.sidebar.write(writer);
                            if (sidebar_bytes == 0) {
                                pill_bytes = try self.pill.write(writer);
                                if (pill_bytes == 0) {
                                    icon_bytes = try self.icons.write(writer);
                                }
                            }
                        }
                    }
                }
            }
        }
        if (comptime core.enabled) {
            self.metrics.pane_graphics_flushed_bytes += pane_bytes;
            self.metrics.toast_graphics_flushed_bytes += toast_bytes;
            self.metrics.sidebar_graphics_flushed_bytes += sidebar_bytes;
            self.metrics.icon_graphics_flushed_bytes += icon_bytes;
            self.metrics.modal_graphics_flushed_bytes += modal_bytes;
            self.metrics.pill_graphics_flushed_bytes += pill_bytes;
            self.metrics.attachment_graphics_flushed_bytes += attachment_bytes;
        }
        return pane_bytes + toast_bytes + sidebar_bytes + icon_bytes + modal_bytes + pill_bytes + attachment_bytes;
    }
};
