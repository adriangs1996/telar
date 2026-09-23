const core = @import("telar-core");
const client = @import("telar-client");
const data = @import("model");
const std = @import("std");
const Plan = @import("../presentation/Plan.zig");
const Composition = @import("Composition.zig");
const CompositionResult = @import("CompositionResult.zig");
const RenderStats = @import("RenderStats.zig");
const multiplexer = @import("multiplexer.zig");
const IncrementalComposition = @import("IncrementalComposition.zig");
const CompositionInput = @import("CompositionInput.zig");
const thread_surface = @import("thread_surface.zig");
/// Presentation-owned cache for one active tab. It borrows an immutable
/// multiplexer model during composition and returns the exact model work that
/// may be committed only after the host flush succeeds.
const Compositor = @This();

gpa: std.mem.Allocator,
composed: ?core.Buffer = null,
area: core.Rect = .{},
source: ?core.TabLocation = null,
border_theme: ?BorderTheme = null,
copy: ?client.CopyProjection = null,
bottom_reservation: ?data.PaneBottomReservation = null,
bottom_reservation_area: core.Rect = .{},
layout_snapshot: data.LayoutSnapshot = .{},
fullscreen_labels: Plan = .{},
panes: [core.max_panes_per_tab]PaneProjection = undefined,
pane_count: u8 = 0,
progress_animation_frame: u8 = 0,
agents_revision: u64 = 0,
thread_surfaces: bool = false,
invalidated: bool = true,

/// Creates an empty composition cache. Buffer allocation is deferred
/// until the first frame.
///
/// ```zig
/// var compositor = Compositor.init(gpa);
/// ```
pub fn init(gpa: std.mem.Allocator) Compositor {
    return .{ .gpa = gpa };
}

/// Releases the presentation-owned cell cache.
///
/// ```zig
/// defer compositor.deinit();
/// ```
pub fn deinit(self: *Compositor) void {
    if (self.composed) |*buffer| {
        buffer.deinit();
    }

    self.composed = null;
}

/// Forces the next frame to rebuild the complete active composition.
///
/// ```zig
/// compositor.invalidate();
/// ```
pub fn invalidate(self: *Compositor) void {
    self.invalidated = true;
}

/// Composes an immutable tab model into the host screen and records which
/// pane work the caller may retire after a successful flush.
///
/// ```zig
/// const result = try compositor.render(composition);
/// ```
pub fn render(self: *Compositor, composition: Composition) !CompositionResult {
    core.profiling.add(.tui_compose, 1);
    const model = composition.model;
    const tab = composition.tab;
    const screen = composition.screen;
    const options = composition.input;
    const previous_copy = self.copy;
    const copy_changed = !std.meta.eql(previous_copy, options.copy);
    const progress_animation_changed = self.progress_animation_frame != options.progress_animation_frame;
    const border_theme: BorderTheme = .{
        .focused = options.palette.accent,
        .unfocused = options.palette.overlay0,
        .tab_text = options.palette.subtext0,
        .selected_tab_text = options.palette.surface_dim,
    };
    if (self.border_theme == null or !std.meta.eql(self.border_theme.?, border_theme)) {
        self.border_theme = border_theme;
        self.invalidated = true;
    }
    if (try self.ensureComposed(screen.back.w, screen.back.h)) {
        self.invalidated = true;
    }
    if (!std.meta.eql(self.area, options.area)) {
        self.area = options.area;
        self.invalidated = true;
    }
    if (!std.meta.eql(self.source, model.tabs.location[tab])) {
        self.source = model.tabs.location[tab];
        self.invalidated = true;
    }
    if (!std.meta.eql(self.bottom_reservation, options.bottom_reservation)) {
        self.bottom_reservation = options.bottom_reservation;
        self.invalidated = true;
    }
    self.copy = options.copy;
    if (options.force) {
        self.invalidated = true;
    }

    if (self.layout_snapshot.revision != model.tabs.layout[tab].currentRevision()) {
        self.invalidated = true;
    }

    // Area, tab, reservation and revision changes all invalidate, so an
    // unchanged frame keeps the snapshot it already reserved.
    if (self.invalidated) {
        model.tabs.layout[tab].snapshot(options.area, &self.layout_snapshot);
        self.bottom_reservation_area = self.layout_snapshot.reserveBelowPane(options.bottom_reservation);
    }
    if (self.paneProjectionChanged(model, tab)) {
        self.invalidated = true;
    }
    if (self.thread_surfaces and self.agents_revision != options.agents_revision) {
        self.invalidated = true;
    }
    self.agents_revision = options.agents_revision;
    const target = &self.composed.?;
    const commit = data.presentation_delivery.capture(model, tab);
    const stats = if (self.invalidated) full: {
        target.clear(.{});
        screen.cursor = null;
        var full_stats: RenderStats = .{ .full = true };
        self.fullscreen_labels = .{};
        for (self.layout_snapshot.views()) |view| {
            const pane = model.panes.findInConst(model.tabs.location[tab].tab_id, view.pane_id) orelse continue;
            full_stats.panes += 1;
            if (model.tabs.layout[tab].hasBorders()) {
                self.fullscreen_labels = multiplexer.drawBorder(target, .{
                    .view = view,
                    .foreground_name = pane.foregroundName(),
                    .fullscreen_model = if (model.tabs.layout[tab].isFullscreen()) model else null,
                    .tab = tab,
                    .progress_state = pane.progress_state,
                    .progress_percent = pane.progress_percent,
                    .animation_frame = options.progress_animation_frame,
                    .palette = options.palette,
                });
            }

            target.pushClip(view.content);
            defer target.popClip();
            if (view.surface == .thread) {
                if (client.ThreadView.capture(model, options.agents, pane.id)) |thread| {
                    thread_surface.paint(target, view.content, .{ .view = thread, .palette = options.palette });
                }
                continue;
            }
            const rows = @min(view.content.h, pane.buffer.h);
            const cols = @min(view.content.w, pane.buffer.w);
            var y: u16 = 0;
            while (y < rows) : (y += 1) {
                var x: u16 = 0;
                while (x < cols) : (x += 1) {
                    const source = &pane.buffer.cells[@as(usize, y) * pane.buffer.w + x];
                    var style = source.style;
                    if (multiplexer.copyView(options.copy, pane.id)) |copy| {
                        const absolute_y = pane.scroll.offset + y;
                        if (copy.selected(x, absolute_y)) {
                            style.flags.inverse = !style.flags.inverse;
                        }
                    }

                    target.setCell(
                        .{ .x = view.content.x + x, .y = view.content.y + y },
                        .{ .text = source.text(), .width = source.width, .style = style },
                    );
                    full_stats.cells += 1;
                }
            }
            if (view.focused) {
                multiplexer.setPaneCursor(screen, pane, .{
                    .content = view.content,
                    .copy = multiplexer.copyView(options.copy, pane.id),
                });
            }
            if (pane.graphics_placeholder) {
                multiplexer.drawGraphicsPlaceholder(target, view.content, options.palette);
            }
        }
        full_stats.damaged_cells = try multiplexer.syncComposed(screen, target);
        break :full full_stats;
    } else incremental: {
        var context: IncrementalComposition = .{
            .model = model,
            .tab = tab,
            .screen = screen,
            .target = target,
            .previous_copy = previous_copy,
            .copy_changed = copy_changed,
        };
        if (progress_animation_changed) {
            try self.composeProgressBorders(&context, options);
        }
        break :incremental try self.composeIncremental(&context);
    };

    self.progress_animation_frame = options.progress_animation_frame;
    self.invalidated = false;
    return .{ .stats = stats, .commit = commit };
}

/// Restores an overlay region from the last pane composition without
/// reading or mutating semantic client state.
///
/// ```zig
/// compositor.copyArea(destination, area);
/// ```
pub fn copyArea(self: *const Compositor, destination: *core.Buffer, area: core.Rect) void {
    const source = if (self.composed) |*buffer| buffer else return;
    if (source.w != destination.w or source.h != destination.h) {
        return;
    }

    const clipped = area.intersect(source.area());
    var y = clipped.y;
    while (y < clipped.y + clipped.h) : (y += 1) {
        const row_start = @as(usize, y) * source.w + clipped.x;
        @memcpy(
            destination.cells[row_start..][0..clipped.w],
            source.cells[row_start..][0..clipped.w],
        );
    }
}

/// Returns the immutable geometry used for the last pane composition.
///
/// ```zig
/// const layout = compositor.layoutSnapshot();
/// ```
pub fn layoutSnapshot(self: *const Compositor) *const data.LayoutSnapshot {
    return &self.layout_snapshot;
}

/// Returns the area removed from the pane projection for its bottom
/// reservation.
///
/// ```zig
/// const shelf = compositor.bottomReservationArea();
/// ```
pub fn bottomReservationArea(self: *const Compositor) core.Rect {
    return self.bottom_reservation_area;
}

/// Returns owned labels from the last cell composition for deferred media.
/// Example: `const labels = compositor.fullscreenLabels();`.
pub fn fullscreenLabels(self: *const Compositor) *const Plan {
    return &self.fullscreen_labels;
}

fn ensureComposed(self: *Compositor, width: u16, height: u16) !bool {
    if (self.composed) |*buffer| {
        if (buffer.w == width and buffer.h == height) {
            return false;
        }

        try buffer.resize(width, height);
        return true;
    }

    self.composed = try .init(self.gpa, width, height);
    return true;
}

fn composeIncremental(self: *Compositor, context: *IncrementalComposition) !RenderStats {
    var stats: RenderStats = .{};
    context.screen.cursor = null;
    for (self.layout_snapshot.views()) |view| {
        const pane = context.model.panes.findInConst(context.model.tabs.location[context.tab].tab_id, view.pane_id) orelse continue;
        stats.panes += 1;
        if (view.surface == .thread) {
            continue;
        }
        const rows = @min(view.content.h, pane.buffer.h);
        const cols = @min(view.content.w, pane.buffer.w);
        if (context.copy_changed) {
            try self.composeCopyChange(context, .{
                .pane = pane,
                .view = view,
                .rows = rows,
                .cols = cols,
                .stats = &stats,
            });
        }
        var y: u16 = 0;
        while (y < rows) : (y += 1) {
            const damage = pane.damage_rows[y];
            if (!damage.dirty()) {
                continue;
            }

            const start = @min(damage.start, cols);
            const end = @min(damage.end, cols);
            if (start >= end) {
                continue;
            }

            stats.cells += end - start;
            stats.damaged_cells += try multiplexer.syncPaneRange(.{
                .screen = context.screen,
                .composed = context.target,
                .pane = pane,
                .destination_x = view.content.x,
                .destination_y = view.content.y + y,
                .source_y = y,
                .start = start,
                .end = end,
                .copy = multiplexer.copyView(self.copy, pane.id),
            });
        }
        if (view.focused) {
            multiplexer.setPaneCursor(context.screen, pane, .{
                .content = view.content,
                .copy = multiplexer.copyView(self.copy, pane.id),
            });
        }
    }

    return stats;
}

fn composeProgressBorders(self: *Compositor, context: *IncrementalComposition, options: CompositionInput) !void {
    if (!context.model.tabs.layout[context.tab].hasBorders()) {
        return;
    }

    for (self.layout_snapshot.views()) |view| {
        const pane = context.model.panes.findInConst(context.model.tabs.location[context.tab].tab_id, view.pane_id) orelse continue;
        if (pane.progress_state == .remove) {
            continue;
        }

        self.fullscreen_labels = multiplexer.drawBorder(context.target, .{
            .view = view,
            .foreground_name = pane.foregroundName(),
            .fullscreen_model = if (context.model.tabs.layout[context.tab].isFullscreen()) context.model else null,
            .tab = context.tab,
            .progress_state = pane.progress_state,
            .progress_percent = pane.progress_percent,
            .animation_frame = options.progress_animation_frame,
            .palette = options.palette,
        });
        _ = try multiplexer.syncComposedRow(context.screen, context.target, view.outer.y);
    }
}

fn composeCopyChange(self: *Compositor, context: *IncrementalComposition, input: CopyChangeComposition) !void {
    const previous = multiplexer.copyView(context.previous_copy, input.pane.id);
    const next = multiplexer.copyView(self.copy, input.pane.id);
    if (std.meta.eql(previous, next)) {
        return;
    }

    var source_y: u16 = 0;
    while (source_y < input.rows) : (source_y += 1) {
        const absolute_y = input.pane.scroll.offset + source_y;
        const before = multiplexer.copySelectionRange(previous, absolute_y, input.cols);
        const after = multiplexer.copySelectionRange(next, absolute_y, input.cols);
        if (std.meta.eql(before, after)) {
            continue;
        }

        const start = @min(
            if (before) |range| range.start else input.cols,
            if (after) |range| range.start else input.cols,
        );
        const end = @max(
            if (before) |range| range.end else 0,
            if (after) |range| range.end else 0,
        );
        if (start >= end) {
            continue;
        }

        input.stats.cells += end - start;
        input.stats.damaged_cells += try multiplexer.syncPaneRange(.{
            .screen = context.screen,
            .composed = context.target,
            .pane = input.pane,
            .destination_x = input.view.content.x,
            .destination_y = input.view.content.y + source_y,
            .source_y = source_y,
            .start = start,
            .end = end,
            .copy = next,
        });
    }
}

fn paneProjectionChanged(self: *Compositor, model: *const data.ClientModel, tab: usize) bool {
    var next: [core.max_panes_per_tab]PaneProjection = undefined;
    var next_count: u8 = 0;
    for (self.layout_snapshot.views()) |view| {
        const pane = model.panes.findInConst(model.tabs.location[tab].tab_id, view.pane_id) orelse continue;
        next[next_count] = .{
            .pane_id = pane.id,
            .surface = view.surface,
            .cols = pane.buffer.w,
            .rows = pane.buffer.h,
            .scroll_offset = multiplexer.highlightedScrollOffset(self.copy, pane),
            .graphics_placeholder = pane.graphics_placeholder,
            .progress_state = pane.progress_state,
            .progress_percent = pane.progress_percent,
        };
        next_count += 1;
    }

    var changed = self.pane_count != next_count;
    if (!changed) {
        for (self.panes[0..self.pane_count], next[0..next_count]) |previous, current| {
            if (!std.meta.eql(previous, current)) {
                changed = true;
                break;
            }
        }
    }
    @memcpy(self.panes[0..next_count], next[0..next_count]);
    self.pane_count = next_count;
    self.thread_surfaces = false;
    for (next[0..next_count]) |projection| {
        if (projection.surface == .thread) {
            self.thread_surfaces = true;
        }
    }
    return changed;
}

const PaneProjection = struct {
    pane_id: core.PaneId,
    surface: core.PaneSurface,
    cols: u16,
    rows: u16,
    scroll_offset: u32,
    graphics_placeholder: bool,
    progress_state: core.PaneProgressState,
    progress_percent: ?u8,
};

const BorderTheme = struct {
    focused: core.Color,
    unfocused: core.Color,
    tab_text: core.Color,
    selected_tab_text: core.Color,
};

const CopyChangeComposition = struct {
    pane: *const data.Pane,
    view: data.LayoutView,
    rows: u16,
    cols: u16,
    stats: *RenderStats,
};
