//! Frame pacing and presentation: the draw-request → deadline → compose →
//! cell-flush cycle, plus a lower-priority media pass. Owns the host-terminal
//! back/front buffers. Shared presentation tokens become commits only after
//! the host output adapter reports successful delivery.

const TokenType = @import("telar-client").Token;
const ObservationType = @import("telar-client").Observation;
const ProjectionType = @import("telar-client").Projection;
const ResourcesType = @import("Resources.zig");
const SchedulerType = @import("Scheduler.zig");
const std = @import("std");
const MetricsType = @import("../resources/Metrics.zig");
const ScreenType = @import("../../presentation/Screen.zig");
const CompositorType = @import("../../workspace/Compositor.zig");
const PacerType = @import("../../presentation/Pacer.zig");
const LifecycleState = @import("telar-client").PresentationLifecycleState;
const StateType = @import("../../presentation/State.zig");
const enabled_module = @import("telar-core").enabled;
const monotonic = @import("telar-client").monotonic;
const pace = @import("../../presentation/pace.zig");
const GeometryType = @import("telar-client").Geometry;
const toast_graphics = @import("../../graphics/toast.zig");
const CombinedGraphicsWriter = @import("CombinedGraphicsWriter.zig");
const kitty_codec = @import("../../graphics/kitty_codec.zig");
const StatsType = @import("../../graphics/Stats.zig");
const delivery_module = @import("../../attachments/delivery.zig");
const CellPresentation = @import("CellPresentation.zig");
const Presented = @import("Presented.zig");
const now_module = @import("telar-core").now;
const elapsed_module = @import("telar-core").elapsed;
const CellGraphicsWriter = @import("CellGraphicsWriter.zig");
const MultiplexerModel = @import("telar-client").MultiplexerModel;

const Presenter = @This();

pub const Token = @import("telar-client").Token;

pub const Observation = @import("telar-client").Observation;

pub const PresentationIngress = @import("telar-client").PresentationIngress;

pub const Projection = @import("telar-client").Projection;

pub const Resources = @import("Resources.zig");

pub const Scheduler = @import("Scheduler.zig");

io: std.Io,
scheduler: SchedulerType,
metrics: *MetricsType,
screen: ScreenType,
compositor: CompositorType,
pacer: PacerType = .{},
presentation_state: LifecycleState = .{},
window_title: StateType = .{},
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
pub fn observe(presenter: *Presenter, observation: ObservationType) !void {
    if (presenter.presentation_state.observe(observation)) {
        try presenter.requestDraw();
        return;
    }
    if (presenter.presentation_state.needsPreparation() and !presenter.draw_pending) {
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
    if (comptime enabled_module) {
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
/// const token = try presenter.presentDue(projection, resources) orelse return;
/// ```
pub fn presentDue(presenter: *Presenter, projection: ProjectionType, resources: ResourcesType) !?TokenType {
    if (comptime enabled_module) {
        presenter.metrics.draw_lateness.observe(monotonic(presenter.io) -| presenter.draw_due_ns);
    }
    if (presenter.pending_updates == 0 or presenter.presentation_state.active != null) {
        return null;
    }

    std.debug.assert(std.meta.eql(projection.version, presenter.presentation_state.observed.model));
    std.debug.assert(std.meta.eql(
        projection.presentation_ingress,
        presenter.presentation_state.observed.presentation_ingress,
    ));
    const workspace_changed = presenter.presentation_state.prepared.model.workspace !=
        projection.version.workspace;
    const configuration_changed = presenter.presentation_state.prepared.model.configuration !=
        projection.version.configuration;
    const diagnostic_changed = presenter.presentation_state.prepared.model.diagnostic !=
        projection.version.diagnostic;
    const host_changed = presenter.presentation_state.prepared.model.host !=
        projection.version.host;
    const workspace_list_changed = presenter.presentation_state.prepared.model.workspace_list !=
        projection.version.workspace_list;
    const agents_changed = presenter.presentation_state.prepared.model.agents !=
        projection.version.agents;
    const sidebar_animation_changed = presenter.presentation_state.prepared.model.sidebar_animation !=
        projection.version.sidebar_animation;
    const proxy_status_changed = presenter.presentation_state.prepared.model.proxy_status !=
        projection.version.proxy_status;
    const system_metrics_changed = presenter.presentation_state.prepared.model.system_metrics !=
        projection.version.system_metrics;
    const bars_changed = presenter.presentation_state.prepared.model.bars != projection.version.bars;
    const notifications_changed = presenter.presentation_state.prepared.model.notifications !=
        projection.version.notifications;
    const tabs_changed = presenter.presentation_state.prepared.model.tabs !=
        projection.version.tabs;
    const active_tab_changed = presenter.presentation_state.prepared.model.active_tab !=
        projection.version.active_tab;
    const panes_changed = presenter.presentation_state.prepared.model.panes !=
        projection.version.panes;
    const pane_metadata_changed = presenter.presentation_state.prepared.model.pane_metadata !=
        projection.version.pane_metadata;
    const pane_foreground_changed = presenter.presentation_state.prepared.model.pane_foreground !=
        projection.version.pane_foreground;
    const pane_progress_changed = presenter.presentation_state.prepared.model.pane_progress !=
        projection.version.pane_progress;
    const pane_graphics_changed = presenter.presentation_state.prepared.model.pane_graphics !=
        projection.version.pane_graphics;
    const chrome_changed = presenter.presentation_state.prepared.model.chrome !=
        projection.version.chrome;
    const prompt_changed = presenter.presentation_state.prepared.model.prompt !=
        projection.version.prompt;
    const history_changed = presenter.presentation_state.prepared.model.history !=
        projection.version.history;
    const suggestion_changed = presenter.presentation_state.prepared.model.suggestion !=
        projection.version.suggestion;
    const viewport_changed = presenter.presentation_state.prepared.model.viewport !=
        projection.version.viewport;
    const was_copy_mode = if (presenter.compositor.copy) |copy| !copy.view.pointer else false;
    const is_copy_mode = if (projection.copy) |copy| !copy.view.pointer else false;
    const copy_status_changed = was_copy_mode != is_copy_mode;
    const view_interaction_changed = presenter.presentation_state.prepared.presentation_ingress.view_interaction !=
        projection.presentation_ingress.view_interaction;
    const input_routing_changed = presenter.presentation_state.prepared.presentation_ingress.input_routing !=
        projection.presentation_ingress.input_routing;
    if (chrome_changed) {
        resources.view.setSidebarLayout(projection.sidebar_visible, projection.sidebar_width);
        resources.view.setWorkspaceListCollapsed(projection.workspace_list_collapsed);
    }
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
        try presenter.presentEmpty(projection, resources);
    var geometry = GeometryType.capture(projection);
    geometry.region = resources.view.geometry();
    const token = try presenter.presentation_state.begin(.{
        .observation = presenter.presentation_state.observed,
        .commit = presented.commit,
        .geometry = geometry,
        .media_pending = projection.model != null and mediaWorkPending(projection, resources),
    });
    presenter.observePresentation(presented.presented_ns);
    presenter.pacer.record(.{
        .now = presented.presented_ns,
        .scheduled_deadline = if (presenter.draw_scheduled) presenter.draw_due_ns else null,
        .absorbed = presenter.pending_updates,
    });
    presenter.pending_updates = 0;

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
pub fn presentMedia(presenter: *Presenter, projection: ProjectionType, resources: ResourcesType) !void {
    if (presenter.pending_updates != 0 or presenter.draw_pending) {
        if (comptime enabled_module) {
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
    const pill_covered_before = resources.view.graphicalPillCoversPlan();
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

    var graphics_writer: CombinedGraphicsWriter = .{
        .panes = .{
            .store = resources.graphics_store,
            .layout_snapshot = presenter.compositor.layoutSnapshot(),
            .cell_width = projection.host_size.cell_width_px,
            .cell_height = projection.host_size.cell_height_px,
            .budget = kitty_codec.transmission_budget_per_frame,
            .now_ns = if (comptime enabled_module) monotonic(presenter.io) else 0,
        },
        .sidebar = resources.view.kittySidebar(),
        .icons = resources.view.kittyIcons(),
        .toasts = resources.view.kittyToasts(),
        .modal = resources.view.kittyModal(),
        .pill = resources.view.kittyPill(),
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
        modal_covered_before != resources.view.graphicalModalCoversPlan() or
        pill_covered_before != resources.view.graphicalPillCoversPlan())
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

fn notePaneGraphics(presenter: *Presenter, graphics_stats: StatsType) void {
    if (comptime !enabled_module) {
        return;
    }
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
fn controlGraphicsReady(projection: ProjectionType, resources: ResourcesType) bool {
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

fn mediaWorkPending(projection: ProjectionType, resources: ResourcesType) bool {
    return resources.view.kittyPill().damaged() or resources.view.kittyAttachments().cleanupPending() or
        (projection.host_capabilities.images == .supported and
            (resources.view.graphicsPreparationPending() or resources.graphics_store.damage or
                resources.view.kittySidebar().damaged() or resources.view.kittyIcons().damaged() or
                resources.view.kittyToasts().damaged() or resources.view.kittyModal().damaged() or
                delivery_module.damaged(resources.view.kittyAttachments())));
}

fn onlyWaitingForMediaIdle(resources: ResourcesType, media_idle: bool) bool {
    return !media_idle and !resources.view.graphicsPreparationPending() and
        !resources.graphics_store.damage and !resources.view.kittySidebar().damaged() and
        !resources.view.kittyIcons().damaged() and !delivery_module.damaged(resources.view.kittyAttachments()) and
        !resources.view.kittyModal().damaged() and !resources.view.kittyPill().damaged() and
        resources.view.kittyToasts().waitingForMediaIdle();
}

fn observePresentation(presenter: *Presenter, presented_ns: u64) void {
    if (comptime enabled_module) {
        if (presenter.last_presented_ns) |previous| {
            presenter.metrics.paced_interval.observe(presented_ns -| previous);
        }
    }

    presenter.last_presented_ns = presented_ns;
}

pub const Delivery = @import("telar-client").PresentationDelivery;

fn present(presenter: *Presenter, input: CellPresentation) !Presented {
    const compose_started = now_module(presenter.io);
    const composed = try presenter.compositor.render(.{
        .model = input.model,
        .screen = &presenter.screen,
        .input = .{
            .area = input.resources.view.workbench(),
            .palette = input.resources.view.palette(),
            .copy = input.projection.copy,
            .bottom_reservation = input.resources.view.attachmentReservation(),
            .progress_animation_frame = input.projection.sidebar_animation_frame,
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
        .proxy_tls_scope = input.projection.proxy_tls_scope,
        .proxy_system_trusted = input.projection.proxy_system_trusted,
        .system_metrics = input.projection.system_metrics,
        .copy_mode_active = if (input.projection.copy) |copy| !copy.view.pointer else false,
        .bar_state = input.projection.bar_state,
        .status_mode = input.projection.status_mode,
        .force = composed.stats.full,
        .diagnostic = input.projection.diagnostic,
    });
    if (comptime enabled_module) {
        presenter.metrics.composed_panes += composed.stats.panes;
        presenter.metrics.composed_cells += composed.stats.cells;
        presenter.metrics.composed_damage_cells += composed.stats.damaged_cells;
        presenter.metrics.chrome_scanned_cells += chrome.scanned;
        presenter.metrics.chrome_damaged_cells += chrome.damaged;
        presenter.metrics.full_compositions += @intFromBool(composed.stats.full);
        presenter.metrics.compose.observe(
            elapsed_module(compose_started, now_module(presenter.io)),
        );
    }
    // Pane graphics that are only names, placements and deletes ride inside
    // this synchronized update, after the cells and before the cursor. Pixel
    // streams and UI rasters wait for the byte-bounded bulk media pass.
    var control_writer: CellGraphicsWriter = .{
        .panes = if (input.projection.host_capabilities.images == .supported) .{
            .store = input.resources.graphics_store,
            .layout_snapshot = presenter.compositor.layoutSnapshot(),
            .cell_width = input.projection.host_size.cell_width_px,
            .cell_height = input.projection.host_size.cell_height_px,
            .mode = .control,
            .now_ns = if (comptime enabled_module) monotonic(presenter.io) else 0,
        } else null,
        .pill = input.resources.view.kittyPill(),
    };
    presenter.screen.graphics = if (controlGraphicsReady(input.projection, input.resources)) .{
        .context = &control_writer,
        .write = CellGraphicsWriter.writeOpaque,
    } else null;
    try presenter.flushScreen(input.resources.writer);
    if (control_writer.panes) |panes| {
        presenter.notePaneGraphics(panes.stats);
    }

    if (comptime enabled_module) {
        presenter.metrics.pill_graphics_flushed_bytes += control_writer.pill_bytes;
    }
    return .{
        .presented_ns = monotonic(presenter.io),
        .commit = composed.commit,
    };
}

fn presentEmpty(presenter: *Presenter, projection: ProjectionType, resources: ResourcesType) !Presented {
    presenter.compositor.invalidate();
    resources.view.kittyPill().observe(&.{}, resources.view.palette());
    const buffer = presenter.screen.buffer();
    buffer.clear(.{});
    presenter.screen.cursor = null;
    presenter.screen.mouse_pointer = .default;
    var control_writer: CellGraphicsWriter = .{ .pill = resources.view.kittyPill() };
    presenter.screen.graphics = if (controlGraphicsReady(projection, resources)) .{
        .context = &control_writer,
        .write = CellGraphicsWriter.writeOpaque,
    } else null;
    try presenter.flushScreen(resources.writer);
    if (comptime enabled_module) {
        presenter.metrics.pill_graphics_flushed_bytes += control_writer.pill_bytes;
    }

    return .{ .presented_ns = monotonic(presenter.io), .commit = .{} };
}

/// Sends the host window title when the rendered template changes. The
/// bytes join the frame already being flushed, so a title never costs an
/// extra host write.
fn syncWindowTitle(presenter: *Presenter, projection: ProjectionType, writer: *std.Io.Writer) !void {
    const tab_label = if (projection.tabs.activeConst()) |tab| tab.labelSlice() else "";
    const pane_title = if (projection.model) |model| focusedPaneTitle(model) else "";

    try presenter.window_title.sync(writer, .{
        .template = projection.window_title_template,
        .tokens = .{
            .workspace = projection.tabs.workspaceName(),
            .tab = tab_label,
            .pane_title = pane_title,
        },
    });
}

fn focusedPaneTitle(model: *const MultiplexerModel) []const u8 {
    const pane_id = model.layout.focused() orelse return "";
    const pane = model.findConst(pane_id) orelse return "";
    return pane.titleSlice();
}

fn flushScreen(presenter: *Presenter, writer: *std.Io.Writer) !void {
    const started = now_module(presenter.io);
    const stats = try presenter.screen.flush(writer);
    if (comptime enabled_module) {
        presenter.metrics.flushes += 1;
        presenter.metrics.scanned_cells += stats.scanned;
        presenter.metrics.flushed_cells += stats.cells;
        presenter.metrics.flushed_bytes += stats.bytes;
        presenter.metrics.graphics_flushed_bytes += stats.graphics_bytes;
        // Only pane control escapes ride the cell frame.
        presenter.metrics.pane_graphics_flushed_bytes += stats.graphics_bytes;
        presenter.metrics.flush.observe(elapsed_module(started, now_module(presenter.io)));
    }
}

fn flushMedia(presenter: *Presenter, writer: *std.Io.Writer) !void {
    const started = now_module(presenter.io);
    const stats = try presenter.screen.flush(writer);
    if (comptime enabled_module) {
        presenter.metrics.media_flushes += 1;
        presenter.metrics.graphics_flushed_bytes += stats.graphics_bytes;
        presenter.metrics.media_flush.observe(elapsed_module(started, now_module(presenter.io)));
    }
}
