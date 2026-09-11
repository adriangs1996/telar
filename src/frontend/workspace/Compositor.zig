const std = @import("std");
const BufferType = @import("telar-core").Buffer;
const RectType = @import("telar-core").Rect;
const TabLocationType = @import("telar-core").TabLocation;
const BorderTheme = @import("BorderTheme.zig");
const CopyProjection = @import("telar-client").CopyProjection;
const PaneBottomReservationType = @import("telar-client").PaneBottomReservation;
const LayoutSnapshot = @import("telar-client").LayoutSnapshot;
const PlanType = @import("../presentation/Plan.zig");
const max_panes_per_tab = @import("telar-core").max_panes_per_tab;
const PaneProjection = @import("PaneProjection.zig");
const Composition = @import("Composition.zig");
const CompositionResult = @import("CompositionResult.zig");
const RenderStats = @import("RenderStats.zig");
const multiplexer = @import("multiplexer.zig");
const IncrementalComposition = @import("IncrementalComposition.zig");
const CompositionInput = @import("CompositionInput.zig");
const CopyChangeComposition = @import("CopyChangeComposition.zig");
const MultiplexerModel = @import("telar-client").MultiplexerModel;
/// Presentation-owned cache for one active tab. It borrows an immutable
/// multiplexer model during composition and returns the exact model work that
/// may be committed only after the host flush succeeds.
const Compositor = @This();

gpa: std.mem.Allocator,
composed: ?BufferType = null,
area: RectType = .{},
source: ?TabLocationType = null,
border_theme: ?BorderTheme = null,
copy: ?CopyProjection = null,
bottom_reservation: ?PaneBottomReservationType = null,
bottom_reservation_area: RectType = .{},
layout_snapshot: LayoutSnapshot = .{},
fullscreen_labels: PlanType = .{},
panes: [max_panes_per_tab]PaneProjection = undefined,
pane_count: u8 = 0,
progress_animation_frame: u8 = 0,
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
pub fn deinit(compositor: *Compositor) void {
    if (compositor.composed) |*buffer| {
        buffer.deinit();
    }

    compositor.composed = null;
}

/// Forces the next frame to rebuild the complete active composition.
///
/// ```zig
/// compositor.invalidate();
/// ```
pub fn invalidate(compositor: *Compositor) void {
    compositor.invalidated = true;
}

/// Composes an immutable tab model into the host screen and records which
/// pane work the caller may retire after a successful flush.
///
/// ```zig
/// const result = try compositor.render(composition);
/// ```
pub fn render(compositor: *Compositor, composition: Composition) !CompositionResult {
    const model = composition.model;
    const screen = composition.screen;
    const options = composition.input;
    const previous_copy = compositor.copy;
    const copy_changed = !std.meta.eql(previous_copy, options.copy);
    const progress_animation_changed = compositor.progress_animation_frame != options.progress_animation_frame;
    const border_theme: BorderTheme = .{
        .focused = options.palette.accent,
        .unfocused = options.palette.overlay0,
        .tab_text = options.palette.subtext0,
        .selected_tab_text = options.palette.surface_dim,
    };
    if (compositor.border_theme == null or !std.meta.eql(compositor.border_theme.?, border_theme)) {
        compositor.border_theme = border_theme;
        compositor.invalidated = true;
    }
    if (try compositor.ensureComposed(screen.back.w, screen.back.h)) {
        compositor.invalidated = true;
    }
    if (!std.meta.eql(compositor.area, options.area)) {
        compositor.area = options.area;
        compositor.invalidated = true;
    }
    if (!std.meta.eql(compositor.source, model.location)) {
        compositor.source = model.location;
        compositor.invalidated = true;
    }
    if (!std.meta.eql(compositor.bottom_reservation, options.bottom_reservation)) {
        compositor.bottom_reservation = options.bottom_reservation;
        compositor.invalidated = true;
    }
    compositor.copy = options.copy;
    if (options.force) {
        compositor.invalidated = true;
    }

    if (compositor.layout_snapshot.revision != model.layout.currentRevision()) {
        compositor.invalidated = true;
    }
    model.layout.snapshot(options.area, &compositor.layout_snapshot);
    compositor.bottom_reservation_area = compositor.layout_snapshot.reserveBelowPane(options.bottom_reservation);
    if (compositor.paneProjectionChanged(model)) {
        compositor.invalidated = true;
    }
    const target = &compositor.composed.?;
    const commit = model.presentationCommit();
    const stats = if (compositor.invalidated) full: {
        target.clear(.{});
        screen.cursor = null;
        var full_stats: RenderStats = .{ .full = true };
        compositor.fullscreen_labels = .{};
        for (compositor.layout_snapshot.views()) |view| {
            const pane = model.findConst(view.pane_id) orelse continue;
            full_stats.panes += 1;
            if (model.layout.hasBorders()) {
                compositor.fullscreen_labels = multiplexer.drawBorder(target, .{
                    .view = view,
                    .foreground_name = pane.foregroundName(),
                    .fullscreen_model = if (model.layout.isFullscreen()) model else null,
                    .progress_state = pane.progress_state,
                    .progress_percent = pane.progress_percent,
                    .animation_frame = options.progress_animation_frame,
                    .palette = options.palette,
                });
            }

            target.pushClip(view.content);
            defer target.popClip();
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
            .screen = screen,
            .target = target,
            .previous_copy = previous_copy,
            .copy_changed = copy_changed,
        };
        if (progress_animation_changed) {
            try compositor.composeProgressBorders(&context, options);
        }
        break :incremental try compositor.composeIncremental(&context);
    };

    compositor.progress_animation_frame = options.progress_animation_frame;
    compositor.invalidated = false;
    return .{ .stats = stats, .commit = commit };
}

/// Restores an overlay region from the last pane composition without
/// reading or mutating semantic client state.
///
/// ```zig
/// compositor.copyArea(destination, area);
/// ```
pub fn copyArea(compositor: *const Compositor, destination: *BufferType, area: RectType) void {
    const source = if (compositor.composed) |*buffer| buffer else return;
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
pub fn layoutSnapshot(compositor: *const Compositor) *const LayoutSnapshot {
    return &compositor.layout_snapshot;
}

/// Returns the area removed from the pane projection for its bottom
/// reservation.
///
/// ```zig
/// const shelf = compositor.bottomReservationArea();
/// ```
pub fn bottomReservationArea(compositor: *const Compositor) RectType {
    return compositor.bottom_reservation_area;
}

/// Returns owned labels from the last cell composition for deferred media.
/// Example: `const labels = compositor.fullscreenLabels();`.
pub fn fullscreenLabels(compositor: *const Compositor) *const PlanType {
    return &compositor.fullscreen_labels;
}

fn ensureComposed(compositor: *Compositor, width: u16, height: u16) !bool {
    if (compositor.composed) |*buffer| {
        if (buffer.w == width and buffer.h == height) {
            return false;
        }

        try buffer.resize(width, height);
        return true;
    }

    compositor.composed = try .init(compositor.gpa, width, height);
    return true;
}

fn composeIncremental(compositor: *Compositor, context: *IncrementalComposition) !RenderStats {
    var stats: RenderStats = .{};
    context.screen.cursor = null;
    for (compositor.layout_snapshot.views()) |view| {
        const pane = context.model.findConst(view.pane_id) orelse continue;
        stats.panes += 1;
        const rows = @min(view.content.h, pane.buffer.h);
        const cols = @min(view.content.w, pane.buffer.w);
        if (context.copy_changed) {
            try compositor.composeCopyChange(context, .{
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
                .copy = multiplexer.copyView(compositor.copy, pane.id),
            });
        }
        if (view.focused) {
            multiplexer.setPaneCursor(context.screen, pane, .{
                .content = view.content,
                .copy = multiplexer.copyView(compositor.copy, pane.id),
            });
        }
    }

    return stats;
}

fn composeProgressBorders(compositor: *Compositor, context: *IncrementalComposition, options: CompositionInput) !void {
    if (!context.model.layout.hasBorders()) {
        return;
    }

    for (compositor.layout_snapshot.views()) |view| {
        const pane = context.model.findConst(view.pane_id) orelse continue;
        if (pane.progress_state == .remove) {
            continue;
        }

        compositor.fullscreen_labels = multiplexer.drawBorder(context.target, .{
            .view = view,
            .foreground_name = pane.foregroundName(),
            .fullscreen_model = if (context.model.layout.isFullscreen()) context.model else null,
            .progress_state = pane.progress_state,
            .progress_percent = pane.progress_percent,
            .animation_frame = options.progress_animation_frame,
            .palette = options.palette,
        });
        _ = try multiplexer.syncComposedRow(context.screen, context.target, view.outer.y);
    }
}

fn composeCopyChange(compositor: *Compositor, context: *IncrementalComposition, input: CopyChangeComposition) !void {
    const previous = multiplexer.copyView(context.previous_copy, input.pane.id);
    const next = multiplexer.copyView(compositor.copy, input.pane.id);
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

fn paneProjectionChanged(compositor: *Compositor, model: *const MultiplexerModel) bool {
    var next: [max_panes_per_tab]PaneProjection = undefined;
    var next_count: u8 = 0;
    for (compositor.layout_snapshot.views()) |view| {
        const pane = model.findConst(view.pane_id) orelse continue;
        next[next_count] = .{
            .pane_id = pane.id,
            .cols = pane.buffer.w,
            .rows = pane.buffer.h,
            .scroll_offset = multiplexer.highlightedScrollOffset(compositor.copy, pane),
            .graphics_placeholder = pane.graphics_placeholder,
            .progress_state = pane.progress_state,
            .progress_percent = pane.progress_percent,
        };
        next_count += 1;
    }

    var changed = compositor.pane_count != next_count;
    if (!changed) {
        for (compositor.panes[0..compositor.pane_count], next[0..next_count]) |previous, current| {
            if (!std.meta.eql(previous, current)) {
                changed = true;
                break;
            }
        }
    }
    @memcpy(compositor.panes[0..next_count], next[0..next_count]);
    compositor.pane_count = next_count;
    return changed;
}
