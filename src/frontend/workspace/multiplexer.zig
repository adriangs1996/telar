//! Multi-pane client state and composition.

const std = @import("std");
const core = @import("telar-core");
const presentation = @import("../presentation/root.zig");
const input_capability = @import("../input/root.zig");
const diff = presentation.diff;
const copy_mode = input_capability.copy_mode;
const client_panes = @import("telar-client").panes;
const frame_apply = client_panes.frame;
const layout_mod = @import("telar-client").workspace.layout;
const fullscreen_tabs = @import("fullscreen_tabs.zig");
const term = presentation.screen;
const theme = @import("../ui/root.zig").theme;

const schema = core.schema;
const ui = core.ui;

pub const max_panes = layout_mod.max_panes;

pub const MetadataChange = @import("telar-client").workspace.multiplexer.MetadataChange;

const pane_index_capacity = max_panes * 2;
const PaneIndex = core.fixed_index.SlotIndex(pane_index_capacity);

const BorderTheme = struct {
    focused: ui.Color,
    unfocused: ui.Color,
    tab_text: ui.Color,
    selected_tab_text: ui.Color,
};

pub const PaneSpec = @import("telar-client").workspace.multiplexer.PaneSpec;

pub const PaneSplit = @import("telar-client").workspace.multiplexer.PaneSplit;

pub const DiscoveredPane = @import("telar-client").workspace.multiplexer.DiscoveredPane;

pub const Pane = client_panes.Pane;

pub const PaneMousePlan = @import("telar-client").workspace.multiplexer.PaneMousePlan;

pub const RenderStats = struct {
    panes: usize = 0,
    cells: usize = 0,
    damaged_cells: usize = 0,
    full: bool = false,
};

pub const PresentationCommit = client_panes.PresentationCommit;

pub const CopyProjection = struct {
    pane_id: schema.PaneId,
    view: copy_mode.View,
};

pub const CompositionInput = struct {
    area: ui.Rect,
    palette: *const theme.Palette,
    copy: ?CopyProjection = null,
    bottom_reservation: ?layout_mod.PaneBottomReservation = null,
    progress_animation_frame: u8 = 0,
    force: bool = false,
};

pub const Composition = struct {
    model: *const Model,
    screen: *term.Screen,
    input: CompositionInput,
};

pub const CompositionResult = struct {
    stats: RenderStats,
    commit: PresentationCommit,
};

/// Presentation-owned cache for one active tab. It borrows an immutable
/// multiplexer model during composition and returns the exact model work that
/// may be committed only after the host flush succeeds.
pub const Compositor = struct {
    gpa: std.mem.Allocator,
    composed: ?ui.Buffer = null,
    area: ui.Rect = .{},
    source: ?schema.TabLocation = null,
    border_theme: ?BorderTheme = null,
    copy: ?CopyProjection = null,
    bottom_reservation: ?layout_mod.PaneBottomReservation = null,
    bottom_reservation_area: ui.Rect = .{},
    layout_snapshot: layout_mod.Snapshot = .{},
    fullscreen_labels: presentation.pane_labels.Plan = .{},
    panes: [max_panes]PaneProjection = undefined,
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
        var commit: PresentationCommit = .{ .location = model.location };
        for (&model.panes) |*slot| {
            const pane = if (slot.*) |*value| value else continue;
            commit.append(pane);
        }
        const stats = if (compositor.invalidated) full: {
            target.clear(.{});
            screen.cursor = null;
            var full_stats: RenderStats = .{ .full = true };
            compositor.fullscreen_labels = .{};
            for (compositor.layout_snapshot.views()) |view| {
                const pane = model.findConst(view.pane_id) orelse continue;
                full_stats.panes += 1;
                if (model.layout.hasBorders()) {
                    compositor.fullscreen_labels = drawBorder(target, .{
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
                        if (copyView(options.copy, pane.id)) |copy| {
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
                    setPaneCursor(screen, pane, .{
                        .content = view.content,
                        .copy = copyView(options.copy, pane.id),
                    });
                }
                if (pane.graphics_placeholder) {
                    drawGraphicsPlaceholder(target, view.content, options.palette);
                }
            }
            full_stats.damaged_cells = try syncComposed(screen, target);
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
    pub fn copyArea(compositor: *const Compositor, destination: *ui.Buffer, area: ui.Rect) void {
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
    pub fn layoutSnapshot(compositor: *const Compositor) *const layout_mod.Snapshot {
        return &compositor.layout_snapshot;
    }

    /// Returns the area removed from the pane projection for its bottom
    /// reservation.
    ///
    /// ```zig
    /// const shelf = compositor.bottomReservationArea();
    /// ```
    pub fn bottomReservationArea(compositor: *const Compositor) ui.Rect {
        return compositor.bottom_reservation_area;
    }

    /// Returns owned labels from the last cell composition for deferred media.
    /// Example: `const labels = compositor.fullscreenLabels();`.
    pub fn fullscreenLabels(compositor: *const Compositor) *const presentation.pane_labels.Plan {
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
                stats.damaged_cells += try syncPaneRange(.{
                    .screen = context.screen,
                    .composed = context.target,
                    .pane = pane,
                    .destination_x = view.content.x,
                    .destination_y = view.content.y + y,
                    .source_y = y,
                    .start = start,
                    .end = end,
                    .copy = copyView(compositor.copy, pane.id),
                });
            }
            if (view.focused) {
                setPaneCursor(context.screen, pane, .{
                    .content = view.content,
                    .copy = copyView(compositor.copy, pane.id),
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

            compositor.fullscreen_labels = drawBorder(context.target, .{
                .view = view,
                .foreground_name = pane.foregroundName(),
                .fullscreen_model = if (context.model.layout.isFullscreen()) context.model else null,
                .progress_state = pane.progress_state,
                .progress_percent = pane.progress_percent,
                .animation_frame = options.progress_animation_frame,
                .palette = options.palette,
            });
            _ = try syncComposedRow(context.screen, context.target, view.outer.y);
        }
    }

    fn composeCopyChange(compositor: *Compositor, context: *IncrementalComposition, input: CopyChangeComposition) !void {
        const previous = copyView(context.previous_copy, input.pane.id);
        const next = copyView(compositor.copy, input.pane.id);
        if (std.meta.eql(previous, next)) {
            return;
        }

        var source_y: u16 = 0;
        while (source_y < input.rows) : (source_y += 1) {
            const absolute_y = input.pane.scroll.offset + source_y;
            const before = copySelectionRange(previous, absolute_y, input.cols);
            const after = copySelectionRange(next, absolute_y, input.cols);
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
            input.stats.damaged_cells += try syncPaneRange(.{
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

    fn paneProjectionChanged(compositor: *Compositor, model: *const Model) bool {
        var next: [max_panes]PaneProjection = undefined;
        var next_count: u8 = 0;
        for (compositor.layout_snapshot.views()) |view| {
            const pane = model.findConst(view.pane_id) orelse continue;
            next[next_count] = .{
                .pane_id = pane.id,
                .cols = pane.buffer.w,
                .rows = pane.buffer.h,
                .scroll_offset = highlightedScrollOffset(compositor.copy, pane),
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
};

const PaneProjection = struct {
    pane_id: schema.PaneId,
    cols: u16,
    rows: u16,
    scroll_offset: u32,
    graphics_placeholder: bool,
    progress_state: schema.PaneProgressState,
    progress_percent: ?u8,
};

const IncrementalComposition = struct {
    model: *const Model,
    screen: *term.Screen,
    target: *ui.Buffer,
    previous_copy: ?CopyProjection,
    copy_changed: bool,
};

const CopyChangeComposition = struct {
    pane: *const Pane,
    view: layout_mod.View,
    rows: u16,
    cols: u16,
    stats: *RenderStats,
};

fn copyView(copy: ?CopyProjection, pane_id: schema.PaneId) ?copy_mode.View {
    const projection = copy orelse return null;
    return if (projection.pane_id == pane_id) projection.view else null;
}

/// The viewport offset reaches composed cells only through a copy-mode
/// selection, which is anchored to absolute scrollback rows. Without one the
/// content scrolling under a live pane arrives as frame damage, so the offset
/// stays out of the projection and cannot force a full composition per frame.
///
/// ```zig
/// const offset = highlightedScrollOffset(compositor.copy, pane);
/// ```
fn highlightedScrollOffset(copy: ?CopyProjection, pane: *const Pane) u32 {
    if (copyView(copy, pane.id) == null) {
        return 0;
    }

    return pane.scroll.offset;
}

const CopySelectionRange = struct {
    start: u16,
    end: u16,
};

fn copySelectionRange(view: ?copy_mode.View, y: u32, cols: u16) ?CopySelectionRange {
    if (cols == 0) {
        return null;
    }

    const copy = view orelse return null;
    const anchor = copy.anchor orelse return null;
    if (copy.linewise) {
        const first_y = @min(anchor.y, copy.cursor.y);
        const last_y = @max(anchor.y, copy.cursor.y);
        return if (y >= first_y and y <= last_y)
            .{ .start = 0, .end = cols }
        else
            null;
    }

    const anchor_first = anchor.y < copy.cursor.y or
        (anchor.y == copy.cursor.y and anchor.x <= copy.cursor.x);
    const first = if (anchor_first) anchor else copy.cursor;
    const last = if (anchor_first) copy.cursor else anchor;
    if (y < first.y or y > last.y) {
        return null;
    }

    const start: u16 = if (y == first.y) @min(first.x, cols) else 0;
    const end: u16 = if (y == last.y) @min(last.x +| 1, cols) else cols;
    return if (start < end) .{ .start = start, .end = end } else null;
}

pub const Model = @import("telar-client").workspace.multiplexer.Model;

/// Copies each changed run into the composed buffer and the screen at once,
/// so the composed cache and the terminal patch can never disagree.
const ComposeSink = struct {
    patch: term.PatchSink,
    composed_row: []ui.Cell,

    pub fn copyRun(sink: *ComposeSink, run_start: u16, count: u16) !void {
        @memcpy(
            sink.composed_row[run_start..][0..count],
            sink.patch.source_row[run_start..][0..count],
        );
        try sink.patch.copyRun(run_start, count);
    }
};

const PaneRange = struct {
    screen: *term.Screen,
    composed: *ui.Buffer,
    pane: *const Pane,
    destination_x: u16,
    destination_y: u16,
    source_y: u16,
    start: u16,
    end: u16,
    copy: ?copy_mode.View,
};

fn syncPaneRange(range: PaneRange) !usize {
    std.debug.assert(range.start < range.end);
    const source_row = range.pane.buffer.cells[@as(usize, range.source_y) * range.pane.buffer.w ..];
    const destination_base = @as(usize, range.destination_y) * range.composed.w + range.destination_x;
    if (range.copy) |selection| {
        const composed_row = range.composed.cells[destination_base..];
        const absolute_y = range.pane.scroll.offset + range.source_y;
        var copied: usize = 0;
        var x = range.start;
        while (x < range.end) {
            var projected = source_row[x];
            if (selection.selected(x, absolute_y)) {
                projected.style.flags.inverse = !projected.style.flags.inverse;
            }
            if (projected.eqlPublic(&composed_row[x])) {
                x += 1;
                continue;
            }
            const run_start = x;
            while (x < range.end) : (x += 1) {
                projected = source_row[x];
                if (selection.selected(x, absolute_y)) {
                    projected.style.flags.inverse = !projected.style.flags.inverse;
                }
                if (projected.eqlPublic(&composed_row[x])) {
                    break;
                }
                composed_row[x] = projected;
            }
            const count: u16 = x - run_start;
            const destination = try range.screen.patchCells(
                @intCast(destination_base + run_start),
                count,
            );
            @memcpy(destination, composed_row[run_start..][0..count]);
            copied += count;
        }
        return copied;
    }
    var sink: ComposeSink = .{
        .patch = .{ .screen = range.screen, .source_row = source_row, .base = destination_base },
        .composed_row = range.composed.cells[destination_base..],
    };
    return diff.syncRow(.{
        .source = source_row,
        .reference = sink.composed_row,
        .start = range.start,
        .end = range.end,
    }, &sink);
}

const PaneCursor = struct {
    content: ui.Rect,
    copy: ?copy_mode.View,
};

fn setPaneCursor(screen: *term.Screen, pane: *const Pane, projection: PaneCursor) void {
    if (projection.copy != null and !projection.copy.?.pointer) {
        const selection = projection.copy.?;
        if (selection.cursor.y < pane.scroll.offset or selection.cursor.x >= projection.content.w) {
            return;
        }
        const visible_y = selection.cursor.y - pane.scroll.offset;
        if (visible_y >= projection.content.h) {
            return;
        }
        screen.cursor = .{
            .x = projection.content.x + selection.cursor.x,
            .y = projection.content.y + @as(u16, @intCast(visible_y)),
        };
        return;
    }
    if (!pane.cursor.visible or pane.cursor.x >= projection.content.w or pane.cursor.y >= projection.content.h) {
        return;
    }
    screen.cursor = .{
        .x = projection.content.x + pane.cursor.x,
        .y = projection.content.y + pane.cursor.y,
    };
}

fn syncComposed(screen: *term.Screen, composed: *const ui.Buffer) !usize {
    std.debug.assert(screen.sizeMatches(composed.w, composed.h));
    var damaged: usize = 0;
    var y: u16 = 0;
    while (y < composed.h) : (y += 1) {
        const row_start = @as(usize, y) * composed.w;
        const source_row = composed.cells[row_start..][0..composed.w];
        var sink: term.PatchSink = .{
            .screen = screen,
            .source_row = source_row,
            .base = row_start,
        };
        damaged += try diff.syncRow(.{
            .source = source_row,
            .reference = screen.back.cells[row_start..][0..composed.w],
            .start = 0,
            .end = composed.w,
        }, &sink);
    }
    return damaged;
}

fn syncComposedRow(screen: *term.Screen, composed: *const ui.Buffer, y: u16) !usize {
    std.debug.assert(screen.sizeMatches(composed.w, composed.h));
    if (y >= composed.h) {
        return 0;
    }

    const row_start = @as(usize, y) * composed.w;
    const source_row = composed.cells[row_start..][0..composed.w];
    var sink: term.PatchSink = .{
        .screen = screen,
        .source_row = source_row,
        .base = row_start,
    };
    return diff.syncRow(.{
        .source = source_row,
        .reference = screen.back.cells[row_start..][0..composed.w],
        .start = 0,
        .end = composed.w,
    }, &sink);
}

/// The buffer a discovered pane keeps while the layout gives it no content.
pub const placeholder_size = @import("telar-client").workspace.multiplexer.placeholder_size;

pub const rectSize = @import("telar-client").workspace.multiplexer.rectSize;

const BorderInput = struct {
    view: layout_mod.View,
    foreground_name: []const u8,
    fullscreen_model: ?*const Model = null,
    progress_state: schema.PaneProgressState,
    progress_percent: ?u8,
    animation_frame: u8,
    palette: *const theme.Palette,
};

fn drawBorder(buffer: *ui.Buffer, input: BorderInput) presentation.pane_labels.Plan {
    const style: ui.Style = if (input.view.focused)
        .{ .fg = input.palette.accent, .flags = .{ .bold = true } }
    else
        .{ .fg = input.palette.overlay0 };

    if (input.fullscreen_model != null) {
        buffer.box(input.view.outer, .{ .style = style });
        const tabs = drawFullscreenTabs(buffer, input);
        drawProgress(buffer, input, tabs.width);
        return tabs.plan;
    }

    var title_buffer: [schema.max_foreground_name_bytes + 32]u8 = undefined;
    const text = std.fmt.bufPrint(
        &title_buffer,
        " {d} {s} ",
        .{ input.view.display_index, if (input.foreground_name.len == 0) "shell" else input.foreground_name },
    ) catch " pane ";
    buffer.box(input.view.outer, .{ .style = style, .title = text });
    drawProgress(buffer, input, ui.measure(text));
    return .{};
}

fn drawFullscreenTabs(buffer: *ui.Buffer, input: BorderInput) fullscreen_tabs.Result {
    const model = input.fullscreen_model.?;
    const outer = input.view.outer;
    if (outer.w <= 4 or outer.h < 2) {
        return .{};
    }

    var storage: [max_panes]schema.PaneId = undefined;
    const panes = model.layout.orderedPanes(&storage);
    var names: [max_panes][]const u8 = undefined;

    for (panes, 0..) |pane_id, index| {
        names[index] = if (model.findConst(pane_id)) |pane| pane.foregroundName() else "";
    }

    const available = outer.w - 4;
    const progress_width: u16 = if (input.progress_state != .remove and available >= 16) 8 else 0;
    return fullscreen_tabs.draw(buffer, .{
        .area = .{ .x = outer.x + 2, .y = outer.y, .w = available - progress_width, .h = 1 },
        .names = names[0..panes.len],
        .focused = input.view.display_index - 1,
        .palette = input.palette,
    });
}

fn drawProgress(buffer: *ui.Buffer, input: BorderInput, title_width: u16) void {
    if (input.progress_state == .remove or input.view.outer.w < 8) {
        return;
    }

    const start = input.view.outer.x + 2 + @min(title_width, input.view.outer.w -| 4);
    const right = input.view.outer.x + input.view.outer.w - 1;
    if (start >= right) {
        return;
    }

    const width = right - start;
    const color = switch (input.progress_state) {
        .@"error" => input.palette.red,
        .pause => input.palette.yellow,
        else => input.palette.teal,
    };
    const progress_style: ui.Style = .{ .fg = color, .flags = .{ .bold = true } };
    const head = switch (input.progress_state) {
        .@"error" => "×",
        .pause => "Ⅱ",
        else => if (input.animation_frame % 2 == 0) "◆" else "◇",
    };
    const position: u16 = switch (input.progress_state) {
        .indeterminate => bouncingPosition(width, input.animation_frame),
        .set, .pause => @intCast((@as(u32, width - 1) * (input.progress_percent orelse 0)) / 100),
        .@"error" => if (input.progress_percent) |percent|
            @intCast((@as(u32, width - 1) * percent) / 100)
        else
            width - 1,
        .remove => unreachable,
    };
    if (input.progress_state != .indeterminate) {
        var x: u16 = 0;
        while (x < position) : (x += 1) {
            buffer.setCell(.{ .x = start + x, .y = input.view.outer.y }, .{ .text = "━", .width = 1, .style = progress_style });
        }
    } else if (position > 0) {
        buffer.setCell(.{ .x = start + position - 1, .y = input.view.outer.y }, .{ .text = "·", .width = 1, .style = progress_style });
    }
    buffer.setCell(.{ .x = start + position, .y = input.view.outer.y }, .{ .text = head, .width = 1, .style = progress_style });
    if (input.progress_state == .indeterminate and position + 1 < width) {
        buffer.setCell(.{ .x = start + position + 1, .y = input.view.outer.y }, .{ .text = "·", .width = 1, .style = progress_style });
    }
}

fn bouncingPosition(width: u16, frame: u8) u16 {
    if (width <= 1) {
        return 0;
    }

    const phase: u16 = if (frame < 128) frame else 255 - @as(u16, frame);
    return @intCast((@as(u32, width - 1) * phase) / 127);
}

fn drawGraphicsPlaceholder(buffer: *ui.Buffer, area: ui.Rect, palette: *const theme.Palette) void {
    if (area.w == 0 or area.h == 0) {
        return;
    }
    const label = "[graphics unavailable]";
    const width = @min(area.w, ui.measure(label));
    const x = area.x + (area.w - width) / 2;
    const y = area.y + area.h / 2;
    _ = buffer.writeTruncated(area, .{ .point = .{ .x = x, .y = y }, .text = label, .max_width = width, .style = .{
        .fg = palette.yellow,
        .bg = palette.surface_dim,
        .flags = .{ .bold = true },
    } });
}

test "progress thread weaves determinate state and moves indeterminate shuttle" {
    var buffer = try ui.Buffer.init(std.testing.allocator, 32, 3);
    defer buffer.deinit();
    const view: layout_mod.View = .{
        .pane_id = @enumFromInt(1),
        .outer = .{ .x = 0, .y = 0, .w = 32, .h = 3 },
        .content = .{ .x = 1, .y = 1, .w = 30, .h = 1 },
        .focused = true,
        .display_index = 1,
    };

    _ = drawBorder(&buffer, .{
        .view = view,
        .foreground_name = "zsh",
        .progress_state = .set,
        .progress_percent = 50,
        .animation_frame = 0,
        .palette = &theme.default_theme.palette,
    });
    var woven = false;
    var shuttle = false;
    for (buffer.cells[0..buffer.w]) |cell| {
        woven = woven or std.mem.eql(u8, cell.text(), "━");
        shuttle = shuttle or std.mem.eql(u8, cell.text(), "◆");
    }
    try std.testing.expect(woven);
    try std.testing.expect(shuttle);

    _ = drawBorder(&buffer, .{
        .view = view,
        .foreground_name = "zsh",
        .progress_state = .indeterminate,
        .progress_percent = null,
        .animation_frame = 26,
        .palette = &theme.default_theme.palette,
    });
    try std.testing.expectEqualStrings("◆", buffer.at(13, 0).?.text());
}

const TestingComposition = struct {
    model: *Model,
    screen: *term.Screen,
    area: ui.Rect,
    palette: *const theme.Palette = &theme.default_theme.palette,
    copy: ?CopyProjection = null,
    bottom_reservation: ?layout_mod.PaneBottomReservation = null,
    force: bool = false,
};

fn testingRender(compositor: *Compositor, composition: TestingComposition) !RenderStats {
    const rendered = try compositor.render(.{
        .model = composition.model,
        .screen = composition.screen,
        .input = .{
            .area = composition.area,
            .palette = composition.palette,
            .copy = composition.copy,
            .bottom_reservation = composition.bottom_reservation,
            .force = composition.force,
        },
    });
    composition.model.commitPresentation(rendered.commit);
    return rendered.stats;
}

fn testingRenderDefault(compositor: *Compositor, model: *Model, screen: *term.Screen) !RenderStats {
    return testingRender(compositor, .{
        .model = model,
        .screen = screen,
        .area = screen.back.area(),
    });
}

test "two pane buffers compose into their layout rectangles" {
    const gpa = std.testing.allocator;
    var model = Model.init(gpa);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 20, .rows = 6 } });
    try model.split(.{ .existing_pane = @enumFromInt(1), .new_pane = @enumFromInt(2), .location = location, .axis = .horizontal, .area = .{ .w = 40, .h = 7 } });
    model.find(@enumFromInt(1)).?.buffer.setCell(.{ .x = 0, .y = 0 }, .{ .text = "a", .width = 1, .style = .{} });
    model.find(@enumFromInt(2)).?.buffer.setCell(.{ .x = 0, .y = 0 }, .{ .text = "b", .width = 1, .style = .{} });

    var screen = try term.Screen.init(gpa, 40, 7);
    defer screen.deinit();
    var compositor = Compositor.init(gpa);
    defer compositor.deinit();
    const stats = try testingRenderDefault(&compositor, &model, &screen);

    try std.testing.expectEqual(@as(usize, 2), stats.panes);
    try std.testing.expectEqualStrings("a", screen.back.cells[40 + 1].text());
    try std.testing.expectEqualStrings("b", screen.back.cells[40 + 21].text());
    try std.testing.expectEqualDeep(
        theme.default_theme.palette.accent,
        screen.back.cells[20].style.fg,
    );
    try std.testing.expect(screen.back.cells[20].style.flags.bold);
    try std.testing.expect(!screen.back.cells[20].style.flags.inverse);
    try std.testing.expectEqualStrings(" ", screen.back.cells[19].text());
    try std.testing.expect(!screen.back.cells[19].style.flags.inverse);
}

test "compositor places a bottom reservation below only its target pane" {
    const gpa = std.testing.allocator;
    const first: schema.PaneId = @enumFromInt(1);
    const second: schema.PaneId = @enumFromInt(2);
    const area: ui.Rect = .{ .w = 40, .h = 12 };
    var model = Model.init(gpa);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = first, .location = location, .size = .{ .cols = 40, .rows = 12 } });
    try model.split(.{ .existing_pane = first, .new_pane = second, .location = location, .axis = .horizontal, .area = area });

    var screen = try term.Screen.init(gpa, area.w, area.h);
    defer screen.deinit();
    var compositor = Compositor.init(gpa);
    defer compositor.deinit();
    _ = try testingRender(&compositor, .{
        .model = &model,
        .screen = &screen,
        .area = area,
        .bottom_reservation = .{
            .pane_id = second,
            .preferred_height = 4,
            .minimum_height = 3,
            .minimum_pane_height = 3,
        },
    });

    const shelf = compositor.bottomReservationArea();
    const first_view = compositor.layoutSnapshot().find(first).?;
    const second_view = compositor.layoutSnapshot().find(second).?;
    try std.testing.expectEqual(@as(u16, 4), shelf.h);
    try std.testing.expectEqual(second_view.outer.x, shelf.x);
    try std.testing.expectEqual(second_view.outer.w, shelf.w);
    try std.testing.expectEqual(second_view.outer.y + second_view.outer.h, shelf.y);
    try std.testing.expectEqual(area.h, first_view.outer.h);
    try std.testing.expectEqual(area.h - shelf.h, second_view.outer.h);

    const restored = try testingRender(&compositor, .{
        .model = &model,
        .screen = &screen,
        .area = area,
    });
    try std.testing.expect(restored.full);
    try std.testing.expect(compositor.bottomReservationArea().isEmpty());
    try std.testing.expectEqual(area.h, compositor.layoutSnapshot().find(second).?.outer.h);
}

test "copy mode highlights an absolute scrollback selection" {
    const gpa = std.testing.allocator;
    var model = Model.init(gpa);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 4, .rows = 2 } });
    const pane = model.find(@enumFromInt(1)).?;
    pane.scroll = .{ .total_rows = 12, .offset = 10 };
    const copy: CopyProjection = .{ .pane_id = pane.id, .view = .{
        .anchor = .{ .x = 1, .y = 10 },
        .cursor = .{ .x = 2, .y = 11 },
        .linewise = false,
    } };

    var screen = try term.Screen.init(gpa, 4, 2);
    defer screen.deinit();
    var compositor = Compositor.init(gpa);
    defer compositor.deinit();
    _ = try testingRender(&compositor, .{
        .model = &model,
        .screen = &screen,
        .area = screen.back.area(),
        .copy = copy,
    });

    try std.testing.expect(!screen.back.cells[0].style.flags.inverse);
    try std.testing.expect(screen.back.cells[1].style.flags.inverse);
    try std.testing.expect(screen.back.cells[6].style.flags.inverse);
    try std.testing.expect(!screen.back.cells[7].style.flags.inverse);
    try std.testing.expectEqual(term.Screen.Position{ .x = 2, .y = 1 }, screen.cursor.?);
}

test "copy mode projection stays outside the multiplexer model" {
    const gpa = std.testing.allocator;
    var model = Model.init(gpa);
    defer model.deinit();
    const pane_id: schema.PaneId = @enumFromInt(1);
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = pane_id, .location = location, .size = .{ .cols = 4, .rows = 2 } });
    var screen = try term.Screen.init(gpa, 4, 2);
    defer screen.deinit();
    var compositor = Compositor.init(gpa);
    defer compositor.deinit();
    try std.testing.expect((try testingRenderDefault(&compositor, &model, &screen)).full);

    const cursor: CopyProjection = .{ .pane_id = pane_id, .view = .{
        .anchor = null,
        .cursor = .{ .x = 2, .y = 1 },
        .linewise = false,
    } };
    const cursor_only = try testingRender(&compositor, .{
        .model = &model,
        .screen = &screen,
        .area = screen.back.area(),
        .copy = cursor,
    });
    try std.testing.expect(!cursor_only.full);
    try std.testing.expectEqual(@as(usize, 0), cursor_only.cells);
    try std.testing.expectEqual(term.Screen.Position{ .x = 2, .y = 1 }, screen.cursor.?);

    const selection: CopyProjection = .{ .pane_id = pane_id, .view = .{
        .anchor = .{ .x = 1, .y = 0 },
        .cursor = .{ .x = 2, .y = 0 },
        .linewise = false,
    } };
    const selected = try testingRender(&compositor, .{
        .model = &model,
        .screen = &screen,
        .area = screen.back.area(),
        .copy = selection,
    });
    try std.testing.expect(!selected.full);
    try std.testing.expectEqual(@as(usize, 2), selected.cells);
    try std.testing.expectEqual(@as(usize, 2), selected.damaged_cells);
    try std.testing.expect(screen.back.cells[1].style.flags.inverse);
    try std.testing.expect(screen.back.cells[2].style.flags.inverse);

    const pane = model.find(pane_id).?;
    pane.buffer.setCell(.{ .x = 1, .y = 0 }, .{ .text = "x", .width = 1, .style = .{} });
    pane.markSpan(1, 1);
    const patched = try testingRender(&compositor, .{
        .model = &model,
        .screen = &screen,
        .area = screen.back.area(),
        .copy = selection,
    });
    try std.testing.expect(!patched.full);
    try std.testing.expectEqual(@as(usize, 1), patched.cells);
    try std.testing.expectEqualStrings("x", screen.back.cells[1].text());
    try std.testing.expect(screen.back.cells[1].style.flags.inverse);

    const idle = try testingRender(&compositor, .{
        .model = &model,
        .screen = &screen,
        .area = screen.back.area(),
        .copy = selection,
    });
    try std.testing.expect(!idle.full);
    try std.testing.expectEqual(@as(usize, 0), idle.cells);
}

test "fullscreen composes only the focused pane across the whole tab" {
    const gpa = std.testing.allocator;
    var model = Model.init(gpa);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const area: ui.Rect = .{ .w = 40, .h = 7 };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 20, .rows = 6 } });
    try model.split(.{ .existing_pane = @enumFromInt(1), .new_pane = @enumFromInt(2), .location = location, .axis = .horizontal, .area = area });
    try std.testing.expect(model.focusPane(@enumFromInt(1)));
    model.find(@enumFromInt(1)).?.buffer.setCell(.{ .x = 0, .y = 0 }, .{ .text = "x", .width = 1, .style = .{} });
    model.find(@enumFromInt(2)).?.buffer.setCell(.{ .x = 0, .y = 0 }, .{ .text = "y", .width = 1, .style = .{} });
    try std.testing.expect(model.toggleFullscreen());

    try std.testing.expectEqual(
        schema.TerminalSize{ .cols = 38, .rows = 5 },
        model.contentSize(@enumFromInt(1), area).?,
    );
    try std.testing.expectEqual(@as(?schema.TerminalSize, null), model.contentSize(@enumFromInt(2), area));
    var screen = try term.Screen.init(gpa, area.w, area.h);
    defer screen.deinit();
    var compositor = Compositor.init(gpa);
    defer compositor.deinit();
    const stats = try testingRender(&compositor, .{
        .model = &model,
        .screen = &screen,
        .area = area,
    });
    try std.testing.expectEqual(@as(usize, 1), stats.panes);
    try std.testing.expectEqualStrings("╭", screen.back.cells[0].text());
    try std.testing.expectEqualStrings("x", screen.back.cells[area.w + 1].text());

    try std.testing.expect(model.toggleFullscreen());
    try std.testing.expect(model.contentSize(@enumFromInt(2), area) != null);
}

test "single-pane fullscreen draws labels and progress and restores borderless content" {
    const gpa = std.testing.allocator;
    var model = Model.init(gpa);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const area: ui.Rect = .{ .w = 40, .h = 7 };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.addRoot(.{ .pane_id = pane_id, .location = location, .size = .{ .cols = area.w, .rows = area.h } });
    const pane = model.find(pane_id).?;
    pane.buffer.setCell(.{ .x = 0, .y = 0 }, .{ .text = "x", .width = 1, .style = .{} });
    try std.testing.expect(model.toggleFullscreen());
    var screen = try term.Screen.init(gpa, area.w, area.h);
    defer screen.deinit();
    var compositor = Compositor.init(gpa);
    defer compositor.deinit();
    _ = try testingRender(&compositor, .{ .model = &model, .screen = &screen, .area = area });
    try std.testing.expectEqualStrings("╭", screen.back.at(0, 0).?.text());
    try std.testing.expectEqualStrings("1", screen.back.at(3, 0).?.text());
    try std.testing.expectEqualStrings("x", screen.back.at(1, 1).?.text());
    try std.testing.expectEqual(@as(u8, 1), compositor.fullscreenLabels().len);
    const idle = try testingRender(&compositor, .{ .model = &model, .screen = &screen, .area = area });
    try std.testing.expect(!idle.full);
    try std.testing.expectEqual(@as(usize, 0), idle.cells);

    pane.progress_state = .indeterminate;
    _ = try testingRender(&compositor, .{ .model = &model, .screen = &screen, .area = area });
    const animated = try compositor.render(.{
        .model = &model,
        .screen = &screen,
        .input = .{ .area = area, .palette = &theme.default_theme.palette, .progress_animation_frame = 127 },
    });
    try std.testing.expect(!animated.stats.full);
    try std.testing.expectEqualStrings("◇", screen.back.at(38, 0).?.text());
    try std.testing.expectEqual(@as(u8, 1), compositor.fullscreenLabels().len);

    try std.testing.expect(model.toggleFullscreen());
    _ = try testingRender(&compositor, .{ .model = &model, .screen = &screen, .area = area });
    try std.testing.expectEqualStrings("x", screen.back.at(0, 0).?.text());
    try std.testing.expectEqual(@as(u8, 0), compositor.fullscreenLabels().len);
    try std.testing.expectEqual(schema.TerminalSize{ .cols = area.w, .rows = area.h }, model.contentSize(pane_id, area).?);
}

test "fullscreen border keeps the pane's tiled display index" {
    const gpa = std.testing.allocator;
    var model = Model.init(gpa);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const area: ui.Rect = .{ .w = 40, .h = 7 };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 20, .rows = 6 } });
    try model.split(.{ .existing_pane = @enumFromInt(1), .new_pane = @enumFromInt(2), .location = location, .axis = .horizontal, .area = area });
    try std.testing.expect(model.focusPane(@enumFromInt(2)));
    try std.testing.expect(model.toggleFullscreen());
    var screen = try term.Screen.init(gpa, area.w, area.h);
    defer screen.deinit();
    var compositor = Compositor.init(gpa);
    defer compositor.deinit();
    _ = try testingRender(&compositor, .{
        .model = &model,
        .screen = &screen,
        .area = area,
    });

    // Labels follow tiled order, with only the second pane selected.
    try std.testing.expectEqualStrings(" ", screen.back.cells[2].text());
    try std.testing.expectEqualStrings("1", screen.back.cells[3].text());
    try std.testing.expectEqualStrings("2", screen.back.cells[13].text());
    try std.testing.expectEqual(theme.default_theme.palette.accent, screen.back.cells[13].style.bg);
    try std.testing.expectEqual(ui.Color.default, screen.back.cells[3].style.bg);
    try std.testing.expectEqualStrings("│", screen.back.cells[area.w].text());
    try std.testing.expectEqualStrings("│", screen.back.cells[2 * area.w - 1].text());
}

test "fullscreen tabs follow focus and survive progress animation without idle redraws" {
    const gpa = std.testing.allocator;
    var model = Model.init(gpa);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const area: ui.Rect = .{ .x = 2, .y = 1, .w = 60, .h = 12 };
    const first: schema.PaneId = @enumFromInt(1);
    const second: schema.PaneId = @enumFromInt(2);
    const third: schema.PaneId = @enumFromInt(3);
    try model.addRoot(.{ .pane_id = first, .location = location, .size = .{ .cols = 20, .rows = 6 } });
    try model.split(.{ .existing_pane = first, .new_pane = second, .location = location, .axis = .horizontal, .area = area });
    try model.split(.{ .existing_pane = first, .new_pane = third, .location = location, .axis = .vertical, .area = area });
    _ = model.setPaneForeground(first, "nvim");
    _ = model.setPaneForeground(third, "claude");
    try std.testing.expect(model.toggleFullscreen());
    var screen = try term.Screen.init(gpa, 64, 14);
    defer screen.deinit();
    var compositor = Compositor.init(gpa);
    defer compositor.deinit();
    const palette = &theme.default_theme.palette;
    _ = try testingRender(&compositor, .{ .model = &model, .screen = &screen, .area = area });
    try std.testing.expectEqualStrings("1", screen.back.at(5, 1).?.text());
    try std.testing.expectEqualStrings("2", screen.back.at(14, 1).?.text());
    try std.testing.expectEqualStrings("c", screen.back.at(16, 1).?.text());
    try std.testing.expectEqual(palette.accent, screen.back.at(14, 1).?.style.bg);
    try std.testing.expectEqualStrings("3", screen.back.at(25, 1).?.text());

    try std.testing.expectEqual(second, model.focusDirection(.right, area).?);
    _ = try testingRender(&compositor, .{ .model = &model, .screen = &screen, .area = area });
    try std.testing.expectEqual(ui.Color.default, screen.back.at(14, 1).?.style.bg);
    try std.testing.expectEqual(palette.accent, screen.back.at(25, 1).?.style.bg);
    const idle = try testingRender(&compositor, .{ .model = &model, .screen = &screen, .area = area });
    try std.testing.expect(!idle.full);
    try std.testing.expectEqual(@as(usize, 0), idle.cells);
    try std.testing.expectEqual(@as(usize, 0), idle.damaged_cells);

    model.find(second).?.progress_state = .indeterminate;
    _ = try testingRender(&compositor, .{ .model = &model, .screen = &screen, .area = area });
    const animated = try compositor.render(.{
        .model = &model,
        .screen = &screen,
        .input = .{ .area = area, .palette = palette, .progress_animation_frame = 127 },
    });
    try std.testing.expect(!animated.stats.full);
    try std.testing.expectEqual(@as(usize, 0), animated.stats.cells);
    try std.testing.expectEqual(palette.accent, screen.back.at(25, 1).?.style.bg);
    try std.testing.expectEqualStrings("◇", screen.back.at(60, 1).?.text());
    try std.testing.expectEqualStrings("╮", screen.back.at(61, 1).?.text());
    try std.testing.expectEqualStrings("│", screen.back.at(2, 2).?.text());

    // Presenter invalidates composition when any pane's foreground changes,
    // including a hidden pane whose label is now part of the border.
    _ = model.setPaneForeground(first, "zig");
    compositor.invalidate();
    _ = try testingRender(&compositor, .{ .model = &model, .screen = &screen, .area = area });
    try std.testing.expectEqualStrings("z", screen.back.at(7, 1).?.text());

    var changed_palette = palette.*;
    changed_palette.surface_dim = .{ .rgb = .{ 1, 2, 3 } };
    const restyled = try testingRender(&compositor, .{ .model = &model, .screen = &screen, .area = area, .palette = &changed_palette });
    try std.testing.expect(restyled.full);
    try std.testing.expectEqual(changed_palette.surface_dim, screen.back.at(24, 1).?.style.fg);
}

test "pane borders use the selected theme without coloring pane contents" {
    const gpa = std.testing.allocator;
    var model = Model.init(gpa);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = @enumFromInt(10), .location = location, .size = .{ .cols = 10, .rows = 3 } });
    try model.split(.{ .existing_pane = @enumFromInt(10), .new_pane = @enumFromInt(41), .location = location, .axis = .horizontal, .area = .{ .w = 20, .h = 4 } });
    const first = model.find(@enumFromInt(10)).?;
    const second = model.find(@enumFromInt(41)).?;
    try std.testing.expectEqual(MetadataChange.display_changed, model.setPaneForeground(first.id, "zsh"));
    try std.testing.expectEqual(MetadataChange.display_changed, model.setPaneForeground(second.id, "Claude Code"));
    first.buffer.setCell(.{ .x = 0, .y = 0 }, .{ .text = "x", .width = 1, .style = .{} });
    const selected = theme.builtin(.tokyo_night);
    var screen = try term.Screen.init(gpa, 20, 4);
    defer screen.deinit();
    var compositor = Compositor.init(gpa);
    defer compositor.deinit();
    _ = try testingRender(&compositor, .{
        .model = &model,
        .screen = &screen,
        .area = screen.back.area(),
        .palette = &selected.palette,
    });

    try std.testing.expectEqualDeep(selected.palette.accent, screen.back.cells[10].style.fg);
    try std.testing.expectEqualDeep(ui.Color.default, screen.back.cells[21].style.bg);
    try std.testing.expectEqualStrings("1", screen.back.at(3, 0).?.text());
    try std.testing.expectEqualStrings("z", screen.back.at(5, 0).?.text());
    try std.testing.expectEqualStrings("2", screen.back.at(13, 0).?.text());
    try std.testing.expectEqualStrings("C", screen.back.at(15, 0).?.text());

    const replacement = theme.builtin(.catppuccin);
    const replaced = try testingRender(&compositor, .{
        .model = &model,
        .screen = &screen,
        .area = screen.back.area(),
        .palette = &replacement.palette,
    });
    try std.testing.expect(replaced.full);
    try std.testing.expectEqualDeep(replacement.palette.accent, screen.back.cells[10].style.fg);
}

test "one pane has no telar border" {
    const gpa = std.testing.allocator;
    var model = Model.init(gpa);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 12, .rows = 3 } });
    model.find(@enumFromInt(1)).?.buffer.setCell(.{ .x = 0, .y = 0 }, .{ .text = "x", .width = 1, .style = .{} });

    var screen = try term.Screen.init(gpa, 12, 3);
    defer screen.deinit();
    var compositor = Compositor.init(gpa);
    defer compositor.deinit();
    _ = try testingRenderDefault(&compositor, &model, &screen);

    try std.testing.expectEqualStrings("x", screen.back.cells[0].text());
    try std.testing.expect(!screen.back.cells[0].style.flags.inverse);
}

test "frame state and pending acknowledgements stay per pane" {
    const gpa = std.testing.allocator;
    var model = Model.init(gpa);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 2, .rows = 1 } });
    try model.split(.{ .existing_pane = @enumFromInt(1), .new_pane = @enumFromInt(2), .location = location, .axis = .horizontal, .area = .{ .w = 7, .h = 3 } });

    const cells = [_]ui.Cell{ .{}, .{} };
    const spans = [_]schema.frame.Span{.{ .start = 0, .cells = &cells }};
    var encoded: [256]u8 = undefined;
    const payload = try schema.encodePaneFrame(&encoded, .{
        .pane_id = @enumFromInt(2),
        .frame_id = 1,
        .base_frame_id = 0,
        .cols = 2,
        .rows = 1,
        .scroll = .{ .total_rows = 1, .offset = 0 },
        .spans = &spans,
    });
    _ = try model.applyFrame((try schema.decodeServer(payload)).pane_frame);

    try std.testing.expectEqual(@as(u64, 0), model.find(@enumFromInt(1)).?.pending_frame_id);
    try std.testing.expectEqual(@as(u64, 1), model.find(@enumFromInt(2)).?.pending_frame_id);
}

test "composition damage retires only after its presentation commits" {
    const gpa = std.testing.allocator;
    var model = Model.init(gpa);
    defer model.deinit();
    const pane_id: schema.PaneId = @enumFromInt(1);
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = pane_id, .location = location, .size = .{ .cols = 2, .rows = 1 } });
    const pane = model.find(pane_id).?;
    pane.pending_frame_id = 7;
    pane.damage_rows[0].mark(0, 1);

    var screen = try term.Screen.init(gpa, 2, 1);
    defer screen.deinit();
    var compositor = Compositor.init(gpa);
    defer compositor.deinit();
    const composed = try compositor.render(.{
        .model = &model,
        .screen = &screen,
        .input = .{ .area = screen.back.area(), .palette = &theme.default_theme.palette },
    });

    try std.testing.expectEqual(@as(u64, 7), pane.pending_frame_id);
    try std.testing.expect(pane.damage_rows[0].dirty());
    try std.testing.expectEqual(@as(u64, 7), composed.commit.slice()[0].frame_id);

    model.commitPresentation(composed.commit);

    try std.testing.expectEqual(@as(u64, 0), pane.pending_frame_id);
    try std.testing.expect(!pane.damage_rows[0].dirty());
}

test "stale presentation commits preserve newer pane work" {
    const gpa = std.testing.allocator;
    var model = Model.init(gpa);
    defer model.deinit();
    const pane_id: schema.PaneId = @enumFromInt(1);
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = pane_id, .location = location, .size = .{ .cols = 2, .rows = 1 } });
    const pane = model.find(pane_id).?;
    pane.pending_frame_id = 7;
    pane.damage_rows[0].mark(0, 1);

    var screen = try term.Screen.init(gpa, 2, 1);
    defer screen.deinit();
    var compositor = Compositor.init(gpa);
    defer compositor.deinit();
    const stale = try compositor.render(.{
        .model = &model,
        .screen = &screen,
        .input = .{ .area = screen.back.area(), .palette = &theme.default_theme.palette },
    });
    pane.pending_frame_id = 8;
    pane.damage_rows[0].mark(1, 2);

    model.commitPresentation(stale.commit);

    try std.testing.expectEqual(@as(u64, 8), pane.pending_frame_id);
    try std.testing.expect(pane.damage_rows[0].dirty());
    try std.testing.expectEqual(@as(u16, 0), pane.damage_rows[0].start);
    try std.testing.expectEqual(@as(u16, 2), pane.damage_rows[0].end);
}

test "fullscreen presentation commits include hidden panes" {
    const gpa = std.testing.allocator;
    var model = Model.init(gpa);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const area: ui.Rect = .{ .w = 20, .h = 4 };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 9, .rows = 3 } });
    try model.split(.{ .existing_pane = @enumFromInt(1), .new_pane = @enumFromInt(2), .location = location, .axis = .horizontal, .area = area });
    try std.testing.expect(model.focusPane(@enumFromInt(1)));
    try std.testing.expect(model.toggleFullscreen());
    model.find(@enumFromInt(1)).?.pending_frame_id = 3;
    model.find(@enumFromInt(2)).?.pending_frame_id = 4;

    var screen = try term.Screen.init(gpa, area.w, area.h);
    defer screen.deinit();
    var compositor = Compositor.init(gpa);
    defer compositor.deinit();
    const composed = try compositor.render(.{
        .model = &model,
        .screen = &screen,
        .input = .{ .area = area, .palette = &theme.default_theme.palette },
    });

    try std.testing.expectEqual(@as(usize, 2), composed.commit.slice().len);
    try std.testing.expectEqual(@as(u64, 3), composed.commit.slice()[0].frame_id);
    try std.testing.expectEqual(@as(u64, 4), composed.commit.slice()[1].frame_id);
}

test "snapshot discovery does not imply a runtime attachment" {
    const gpa = std.testing.allocator;
    var model = Model.init(gpa);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 40, .rows = 8 } });
    try model.addDiscovered(.{ .pane_id = @enumFromInt(2), .location = location, .area = .{ .w = 40, .h = 8 } });

    try std.testing.expect(model.find(@enumFromInt(1)).?.attached);
    try std.testing.expect(!model.find(@enumFromInt(2)).?.attached);
    try model.markAttached(@enumFromInt(2));
    try std.testing.expect(model.find(@enumFromInt(2)).?.attached);
}

test "snapshot discovery keeps a pane the area cannot fit" {
    const gpa = std.testing.allocator;
    var model = Model.init(gpa);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const area: ui.Rect = .{ .w = 4, .h = 3 };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 4, .rows = 3 } });

    try model.addDiscovered(.{ .pane_id = @enumFromInt(2), .location = location, .area = area });

    try std.testing.expectEqual(@as(usize, 2), model.pane_count);
    try std.testing.expect(model.layout.contains(@enumFromInt(2)));
    try std.testing.expect(!model.find(@enumFromInt(2)).?.attached);
    try std.testing.expectEqual(@as(?schema.TerminalSize, null), model.contentSize(@enumFromInt(2), area));
}

test "unchanged composition produces no terminal damage" {
    const gpa = std.testing.allocator;
    var model = Model.init(gpa);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 8, .rows = 3 } });
    var screen = try term.Screen.init(gpa, 8, 3);
    defer screen.deinit();
    var compositor = Compositor.init(gpa);
    defer compositor.deinit();

    const first = try testingRenderDefault(&compositor, &model, &screen);
    var output: [4096]u8 = undefined;
    var initial_writer = std.Io.Writer.fixed(&output);
    _ = try screen.flush(&initial_writer);

    const snapshot_cells = [_]ui.Cell{.{}} ** 24;
    const snapshot_spans = [_]schema.frame.Span{.{
        .start = 0,
        .cells = &snapshot_cells,
    }};
    var encoded: [4096]u8 = undefined;
    const snapshot_payload = try schema.encodePaneFrame(&encoded, .{
        .pane_id = @enumFromInt(1),
        .frame_id = 1,
        .base_frame_id = 0,
        .cols = 8,
        .rows = 3,
        .scroll = .{ .total_rows = 3, .offset = 0 },
        .spans = &snapshot_spans,
    });
    _ = try model.applyFrame((try schema.decodeServer(snapshot_payload)).pane_frame);
    const snapshot = try testingRenderDefault(&compositor, &model, &screen);
    var snapshot_writer = std.Io.Writer.fixed(&output);
    _ = try screen.flush(&snapshot_writer);

    const second = try testingRenderDefault(&compositor, &model, &screen);
    var unchanged_writer = std.Io.Writer.fixed(&output);
    const unchanged_flush = try screen.flush(&unchanged_writer);
    try std.testing.expectEqual(@as(usize, 0), first.damaged_cells);
    try std.testing.expectEqual(@as(usize, 24), snapshot.cells);
    try std.testing.expectEqual(@as(usize, 0), snapshot.damaged_cells);
    try std.testing.expectEqual(@as(usize, 0), second.damaged_cells);
    try std.testing.expectEqual(@as(usize, 0), unchanged_flush.scanned);

    const patch_cells = [_]ui.Cell{.{
        .bytes = [_]u8{'x'} ++ [_]u8{0} ** (ui.Cell.max_bytes - 1),
    }};
    const patch_spans = [_]schema.frame.Span{.{ .start = 11, .cells = &patch_cells }};
    const patch_payload = try schema.encodePaneFrame(&encoded, .{
        .pane_id = @enumFromInt(1),
        .frame_id = 2,
        .base_frame_id = 1,
        .cols = 8,
        .rows = 3,
        .scroll = .{ .total_rows = 3, .offset = 0 },
        .spans = &patch_spans,
    });
    _ = try model.applyFrame((try schema.decodeServer(patch_payload)).pane_frame);
    const changed = try testingRenderDefault(&compositor, &model, &screen);
    var changed_writer = std.Io.Writer.fixed(&output);
    const changed_flush = try screen.flush(&changed_writer);
    try std.testing.expectEqual(@as(usize, 1), changed.cells);
    try std.testing.expectEqual(@as(usize, 1), changed.damaged_cells);
    try std.testing.expectEqual(@as(usize, 1), changed_flush.scanned);
}

test "compositor detects focus changes while stable focus stays incremental" {
    const gpa = std.testing.allocator;
    var model = Model.init(gpa);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 20, .rows = 5 } });
    try model.split(.{ .existing_pane = @enumFromInt(1), .new_pane = @enumFromInt(2), .location = location, .axis = .horizontal, .area = .{ .w = 40, .h = 6 } });
    var screen = try term.Screen.init(gpa, 40, 6);
    defer screen.deinit();
    var compositor = Compositor.init(gpa);
    defer compositor.deinit();

    try std.testing.expect((try testingRenderDefault(&compositor, &model, &screen)).full);
    try std.testing.expect(model.focusPane(@enumFromInt(1)));
    try std.testing.expect((try testingRenderDefault(&compositor, &model, &screen)).full);
    try std.testing.expect(model.focusPane(@enumFromInt(1)));
    const stable = try testingRenderDefault(&compositor, &model, &screen);
    try std.testing.expect(!stable.full);
    try std.testing.expectEqual(@as(usize, 0), stable.cells);
}

test "compositor detects pane projection changes without model cache flags" {
    const gpa = std.testing.allocator;
    var model = Model.init(gpa);
    defer model.deinit();
    const pane_id: schema.PaneId = @enumFromInt(1);
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = pane_id, .location = location, .size = .{ .cols = 24, .rows = 3 } });
    const pane = model.find(pane_id).?;

    var screen = try term.Screen.init(gpa, 24, 3);
    defer screen.deinit();
    var compositor = Compositor.init(gpa);
    defer compositor.deinit();
    try std.testing.expect((try testingRenderDefault(&compositor, &model, &screen)).full);

    // Content scrolling moves the offset every frame; its cells arrive as
    // frame damage, so it must not invalidate the composition on its own.
    pane.scroll = .{ .total_rows = 4, .offset = 1 };
    const scrolled = try testingRenderDefault(&compositor, &model, &screen);
    try std.testing.expect(!scrolled.full);
    try std.testing.expectEqual(@as(usize, 0), scrolled.cells);

    // A copy-mode selection is anchored to absolute rows, so under it the
    // offset shapes the composed cells and does invalidate.
    const copy: CopyProjection = .{ .pane_id = pane_id, .view = .{
        .anchor = .{ .x = 0, .y = 1 },
        .cursor = .{ .x = 1, .y = 1 },
        .linewise = false,
    } };
    try std.testing.expect((try testingRender(&compositor, .{
        .model = &model,
        .screen = &screen,
        .area = screen.back.area(),
        .copy = copy,
    })).full);
    pane.scroll = .{ .total_rows = 5, .offset = 2 };
    try std.testing.expect((try testingRender(&compositor, .{
        .model = &model,
        .screen = &screen,
        .area = screen.back.area(),
        .copy = copy,
    })).full);
    // Leaving copy mode drops the offset from the projection again.
    try std.testing.expect((try testingRenderDefault(&compositor, &model, &screen)).full);

    pane.graphics_placeholder = true;
    try std.testing.expect((try testingRenderDefault(&compositor, &model, &screen)).full);

    const stable = try testingRenderDefault(&compositor, &model, &screen);
    try std.testing.expect(!stable.full);
    try std.testing.expectEqual(@as(usize, 0), stable.cells);
}

test "pane index survives collisions removal and slot reuse" {
    const gpa = std.testing.allocator;
    var model = Model.init(gpa);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const area: ui.Rect = .{ .w = 80, .h = 24 };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 80, .rows = 24 } });
    try model.split(.{ .existing_pane = @enumFromInt(1), .new_pane = @enumFromInt(129), .location = location, .axis = .horizontal, .area = area });

    try std.testing.expect(model.removePane(@enumFromInt(1)));
    try std.testing.expect(model.find(@enumFromInt(1)) == null);
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(129)), model.find(@enumFromInt(129)).?.id);

    try model.addDiscovered(.{ .pane_id = @enumFromInt(257), .location = location, .area = area });
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(257)), model.find(@enumFromInt(257)).?.id);
    try std.testing.expectEqual(@as(usize, 2), model.pane_count);
}

test "layout snapshot cache invalidates on geometry and revision" {
    const gpa = std.testing.allocator;
    var model = Model.init(gpa);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 80, .rows = 24 } });

    const first = model.layoutSnapshot(.{ .w = 80, .h = 24 });
    const first_revision = first.revision;
    try std.testing.expectEqual(@as(u16, 80), first.find(@enumFromInt(1)).?.content.w);

    const resized = model.layoutSnapshot(.{ .w = 40, .h = 12 });
    try std.testing.expectEqual(first_revision, resized.revision);
    try std.testing.expectEqual(@as(u16, 40), resized.find(@enumFromInt(1)).?.content.w);

    try model.split(.{ .existing_pane = @enumFromInt(1), .new_pane = @enumFromInt(2), .location = location, .axis = .horizontal, .area = .{ .w = 40, .h = 12 } });
    const split = model.layoutSnapshot(.{ .w = 40, .h = 12 });
    try std.testing.expect(split.revision != first_revision);
    try std.testing.expectEqual(@as(usize, 2), split.views().len);
}

test "pane mouse planning keeps buttons focused and wheels pointer-local" {
    const gpa = std.testing.allocator;
    var model = Model.init(gpa);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const area: ui.Rect = .{ .w = 80, .h = 24 };
    const first: schema.PaneId = @enumFromInt(1);
    const second: schema.PaneId = @enumFromInt(2);
    try model.addRoot(.{ .pane_id = first, .location = location, .size = .{ .cols = 39, .rows = 24 } });
    try model.split(.{ .existing_pane = first, .new_pane = second, .location = location, .axis = .horizontal, .area = area });
    try std.testing.expect(model.focusPane(first));
    const second_pane = model.find(second).?;
    second_pane.mouse = .{ .tracking = .any, .sgr = true, .pixels = true };
    second_pane.input_modes = .{ .alternate_screen = true, .alternate_scroll = true };
    second_pane.scroll = .{ .total_rows = second_pane.buffer.h, .offset = 0 };
    const second_view = model.layoutSnapshot(area).find(second).?;
    const second_point: term.Event.Mouse = .{
        .x = second_view.content.x,
        .y = second_view.content.y,
        .kind = .press,
    };

    try std.testing.expect(model.planPaneMouse(second_point, area) == null);

    var wheel = second_point;
    wheel.kind = .scroll_up;
    const plan = model.planPaneMouse(wheel, area).?;

    try std.testing.expectEqual(second, plan.pane_id);
    try std.testing.expectEqualDeep(second_view.content, plan.content);
    try std.testing.expectEqualDeep(second_pane.mouse, plan.protocol);
    try std.testing.expect(plan.alternate_scroll);
    try std.testing.expect(plan.at_bottom);

    const first_view = model.layoutSnapshot(area).find(first).?;
    const focused = model.planPaneMouse(.{
        .x = first_view.content.x,
        .y = first_view.content.y,
        .kind = .release,
    }, area).?;
    try std.testing.expectEqual(first, focused.pane_id);

    const revision = model.layout.currentRevision();
    const focused_scroll = model.planFocusedPaneMouse(area).?;
    try std.testing.expectEqual(first, focused_scroll.pane_id);
    try std.testing.expectEqualDeep(first_view.content, focused_scroll.content);
    try std.testing.expectEqualDeep(model.find(first).?.mouse, focused_scroll.protocol);
    try std.testing.expectEqual(revision, model.layout.currentRevision());
    try std.testing.expectEqual(first, model.layout.focused().?);

    try std.testing.expect(model.focusPane(second));
    try std.testing.expectEqualDeep(plan, model.planFocusedPaneMouse(area).?);
}

test "focused pane mouse planning ignores missing and empty pane content" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const area: ui.Rect = .{ .w = 80, .h = 24 };
    const pane_id: schema.PaneId = @enumFromInt(1);
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };

    try std.testing.expect(model.planFocusedPaneMouse(area) == null);
    try model.addRoot(.{ .pane_id = pane_id, .location = location, .size = .{ .cols = 80, .rows = 24 } });
    try std.testing.expect(model.planFocusedPaneMouse(.{ .w = 0, .h = 24 }) == null);
    try std.testing.expect(model.planFocusedPaneMouse(.{ .w = 80, .h = 0 }) == null);
    try std.testing.expectEqual(pane_id, model.planFocusedPaneMouse(area).?.pane_id);

    try std.testing.expect(model.removePane(pane_id));
    try std.testing.expect(model.planFocusedPaneMouse(area) == null);
}
