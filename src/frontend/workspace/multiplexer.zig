//! Multi-pane client state and composition.

const std = @import("std");
const core = @import("telar-core");
const presentation = @import("../presentation/root.zig");
const input_capability = @import("../input/root.zig");
const diff = presentation.diff;
const copy_mode = input_capability.copy_mode;
const frame_apply = presentation.frame;
const layout_mod = @import("layout.zig");
const term = presentation.screen;
const theme = @import("../ui/root.zig").theme;

const schema = core.schema;
const max_cwd_name_bytes = 48;
const ui = core.ui;

pub const max_panes = layout_mod.max_panes;

pub const MetadataChange = enum {
    unchanged,
    stored,
    display_changed,
};

const DamageRow = diff.DamageRow;
const pane_index_capacity = max_panes * 2;
const PaneIndex = core.fixed_index.SlotIndex(pane_index_capacity);

const BorderTheme = struct {
    focused: ui.Color,
    unfocused: ui.Color,
};

pub const Pane = struct {
    gpa: std.mem.Allocator,
    id: schema.PaneId,
    location: schema.TabLocation,
    buffer: ui.Buffer,
    damage_rows: []DamageRow,
    attached: bool,
    cursor: schema.frame.Cursor = .{},
    mouse: schema.frame.Mouse = .{},
    input_modes: schema.frame.InputModes = .{},
    scroll: schema.frame.Scroll,
    applied_frame_id: u64 = 0,
    pending_frame_id: u64 = 0,
    graphics_placeholder: bool = false,
    cwd: []u8 = &.{},
    foreground_name: [schema.max_foreground_name_bytes]u8 = @splat(0),
    foreground_name_len: u8 = 0,
    progress_state: schema.PaneProgressState = .remove,
    progress_percent: ?u8 = null,
    /// Owned copy of the child's window title; empty until the runtime
    /// reports one. Allocated on change so idle panes cost nothing.
    title: []u8 = &.{},

    fn init(gpa: std.mem.Allocator, pane_id: schema.PaneId, location: schema.TabLocation, size: schema.TerminalSize, attached: bool) !Pane {
        var buffer = try ui.Buffer.init(gpa, size.cols, size.rows);
        errdefer buffer.deinit();
        const damage_rows = try gpa.alloc(DamageRow, size.rows);
        @memset(damage_rows, .{});
        return .{
            .gpa = gpa,
            .id = pane_id,
            .location = location,
            .buffer = buffer,
            .damage_rows = damage_rows,
            .attached = attached,
            .scroll = .{ .total_rows = size.rows, .offset = 0 },
        };
    }

    fn deinit(pane: *Pane) void {
        if (pane.cwd.len != 0) {
            pane.gpa.free(pane.cwd);
        }
        if (pane.title.len != 0) {
            pane.gpa.free(pane.title);
        }
        pane.gpa.free(pane.damage_rows);
        pane.buffer.deinit();
    }

    fn clearDamage(pane: *Pane) void {
        for (pane.damage_rows) |*row| row.clear();
    }

    fn markSpan(pane: *Pane, start: u32, count: u32) void {
        diff.markRows(pane.damage_rows, pane.buffer.w, start, count);
    }

    fn setCwd(pane: *Pane, path: []const u8) !bool {
        std.debug.assert(path.len != 0 and path.len <= schema.max_cwd_bytes);
        if (std.mem.eql(u8, pane.cwd, path)) {
            return false;
        }

        const display_changed = !std.mem.eql(u8, pane.cwdName(), displayCwdName(path));
        const replacement = try pane.gpa.dupe(u8, path);
        if (pane.cwd.len != 0) {
            pane.gpa.free(pane.cwd);
        }

        pane.cwd = replacement;
        return display_changed;
    }

    pub fn cwdName(pane: *const Pane) []const u8 {
        return displayCwdName(pane.cwd);
    }

    pub fn cwdSlice(pane: *const Pane) []const u8 {
        return pane.cwd;
    }

    fn setForegroundName(pane: *Pane, name: []const u8) bool {
        std.debug.assert(name.len != 0 and name.len <= pane.foreground_name.len);
        if (std.mem.eql(u8, pane.foregroundName(), name)) {
            return false;
        }

        @memcpy(pane.foreground_name[0..name.len], name);
        pane.foreground_name_len = @intCast(name.len);
        return true;
    }

    pub fn foregroundName(pane: *const Pane) []const u8 {
        return pane.foreground_name[0..pane.foreground_name_len];
    }

    /// Replaces the latest semantic progress report without allocating.
    ///
    /// ```zig
    /// _ = pane.setProgress(progress);
    /// ```
    pub fn setProgress(pane: *Pane, progress: schema.PaneProgress) bool {
        if (pane.progress_state == progress.state and pane.progress_percent == progress.percent) {
            return false;
        }

        pane.progress_state = progress.state;
        pane.progress_percent = progress.percent;
        return true;
    }

    fn setTitle(pane: *Pane, title: []const u8) !bool {
        std.debug.assert(title.len <= schema.max_pane_title_bytes);
        if (std.mem.eql(u8, pane.title, title)) {
            return false;
        }

        const replacement = if (title.len != 0) try pane.gpa.dupe(u8, title) else &[_]u8{};
        if (pane.title.len != 0) {
            pane.gpa.free(pane.title);
        }

        pane.title = @constCast(replacement);
        return true;
    }

    pub fn titleSlice(pane: *const Pane) []const u8 {
        return pane.title;
    }
};

pub const PaneMousePlan = struct {
    pane_id: schema.PaneId,
    content: ui.Rect,
    protocol: schema.frame.Mouse,
    alternate_scroll: bool,
    at_bottom: bool,
};

fn displayCwdName(path: []const u8) []const u8 {
    if (path.len == 0) {
        return "";
    }
    const basename = cwdBaseName(path);
    if (!validCwdName(basename)) {
        return "";
    }
    return truncateCwdName(basename);
}

fn cwdBaseName(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and isPathSeparator(path[end - 1])) end -= 1;
    const trimmed = path[0..end];
    if (trimmed.len == 1 and isPathSeparator(trimmed[0])) {
        return trimmed;
    }
    const separator = std.mem.lastIndexOfAny(u8, trimmed, "/\\") orelse return trimmed;
    const name = trimmed[separator + 1 ..];
    return if (name.len == 0) trimmed else name;
}

fn truncateCwdName(name: []const u8) []const u8 {
    if (name.len <= max_cwd_name_bytes) {
        return name;
    }
    var end: usize = max_cwd_name_bytes;
    while (end > 0 and name[end] & 0b1100_0000 == 0b1000_0000) end -= 1;
    return name[0..end];
}

fn validCwdName(name: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(name)) {
        return false;
    }
    for (name) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn isPathSeparator(byte: u8) bool {
    return byte == '/' or byte == '\\';
}

test "pane cwd names use a bounded basename" {
    try std.testing.expectEqualStrings("telar", cwdBaseName("/work/telar"));
    try std.testing.expectEqualStrings("telar", cwdBaseName("/work/telar/"));
    try std.testing.expectEqualStrings("/", cwdBaseName("/"));
    try std.testing.expectEqualStrings("api", cwdBaseName("C:\\work\\api\\"));
    try std.testing.expectEqualStrings("relative", cwdBaseName("relative"));

    var pane: Pane = undefined;
    pane.gpa = std.testing.allocator;
    pane.cwd = &.{};
    defer if (pane.cwd.len != 0) pane.gpa.free(pane.cwd);
    const long_name = [_]u8{'x'} ** (max_cwd_name_bytes + 1);
    try std.testing.expect(try pane.setCwd("/work/telar"));
    try std.testing.expectEqualStrings("telar", pane.cwdName());
    try std.testing.expect(try pane.setCwd(&long_name));
    try std.testing.expectEqual(@as(usize, max_cwd_name_bytes), pane.cwdName().len);
    try std.testing.expect(try pane.setCwd("/work/\xff"));
    try std.testing.expectEqualStrings("", pane.cwdName());
    try std.testing.expect(!try pane.setCwd("/work/\x1b[31m"));
    try std.testing.expect(!try pane.setCwd("/other/\x1b[31m"));
    try std.testing.expectEqualStrings("/other/\x1b[31m", pane.cwdSlice());
}

pub const RenderStats = struct {
    panes: usize = 0,
    cells: usize = 0,
    damaged_cells: usize = 0,
    full: bool = false,
};

pub const PresentationCommit = struct {
    location: ?schema.TabLocation = null,
    panes: [max_panes]PaneCommit = undefined,
    len: u8 = 0,

    pub const PaneCommit = struct {
        pane_id: schema.PaneId,
        frame_id: u64,
        attached: bool,
    };

    /// Returns the panes whose damage and pending frame are safe to retire
    /// after one successful host presentation.
    ///
    /// ```zig
    /// for (commit.slice()) |pane| acknowledge(pane);
    /// ```
    pub fn slice(commit: *const PresentationCommit) []const PaneCommit {
        return commit.panes[0..commit.len];
    }

    fn append(commit: *PresentationCommit, pane: *const Pane) void {
        commit.panes[commit.len] = .{
            .pane_id = pane.id,
            .frame_id = pane.pending_frame_id,
            .attached = pane.attached,
        };
        commit.len += 1;
    }
};

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
            for (compositor.layout_snapshot.views()) |view| {
                const pane = model.findConst(view.pane_id) orelse continue;
                full_stats.panes += 1;
                if (model.layout.count() > 1) {
                    drawBorder(target, .{
                        .view = view,
                        .foreground_name = pane.foregroundName(),
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
                            view.content.x + x,
                            view.content.y + y,
                            source.text(),
                            source.width,
                            style,
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
        if (context.model.layout.count() <= 1) {
            return;
        }

        for (compositor.layout_snapshot.views()) |view| {
            const pane = context.model.findConst(view.pane_id) orelse continue;
            if (pane.progress_state == .remove) {
                continue;
            }

            drawBorder(context.target, .{
                .view = view,
                .foreground_name = pane.foregroundName(),
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

pub const Model = struct {
    gpa: std.mem.Allocator,
    layout: layout_mod.Layout = .{},
    panes: [max_panes]?Pane = [_]?Pane{null} ** max_panes,
    pane_index: PaneIndex = .{},
    pane_count: usize = 0,
    location: ?schema.TabLocation = null,
    cell_width_px: u16 = 0,
    cell_height_px: u16 = 0,
    layout_snapshot: layout_mod.Snapshot = .{},

    pub fn init(gpa: std.mem.Allocator) Model {
        return .{ .gpa = gpa };
    }

    pub fn deinit(model: *Model) void {
        for (&model.panes) |*slot| {
            if (slot.*) |*pane| {
                pane.deinit();
            }
            slot.* = null;
        }
        model.pane_count = 0;
        model.pane_index.reset();
    }

    pub fn setPaneGaps(model: *Model, enabled: bool) void {
        _ = model.layout.setPaneGaps(enabled);
    }

    /// Iterates the live panes without exposing the slot array.
    pub const PaneIterator = struct {
        panes: *[max_panes]?Pane,
        index: usize = 0,

        pub fn next(iterator: *PaneIterator) ?*Pane {
            while (iterator.index < max_panes) {
                const slot = &iterator.panes[iterator.index];
                iterator.index += 1;
                if (slot.*) |*pane| {
                    return pane;
                }
            }
            return null;
        }
    };

    pub fn paneIterator(model: *Model) PaneIterator {
        return .{ .panes = &model.panes };
    }

    pub fn focusedPane(model: *Model) ?*Pane {
        const pane_id = model.layout.focused() orelse return null;
        return model.find(pane_id);
    }

    pub fn focusedPaneConst(model: *const Model) ?*const Pane {
        const pane_id = model.layout.focused() orelse return null;
        return model.findConst(pane_id);
    }

    pub fn displayIndex(model: *const Model, pane_id: schema.PaneId) ?u16 {
        return model.layout.displayIndex(pane_id);
    }

    pub fn find(model: *Model, pane_id: schema.PaneId) ?*Pane {
        if (pane_id == .invalid) {
            return null;
        }
        const slot = model.pane_index.get(schema.id.raw(pane_id)) orelse return null;
        return &model.panes[slot].?;
    }

    pub fn findConst(model: *const Model, pane_id: schema.PaneId) ?*const Pane {
        if (pane_id == .invalid) {
            return null;
        }
        const slot = model.pane_index.get(schema.id.raw(pane_id)) orelse return null;
        return &model.panes[slot].?;
    }

    /// Stores one pane working directory and reports whether its bounded
    /// display name changed. Rendering caches remain untouched.
    ///
    /// ```zig
    /// const change = try model.setPaneCwd(pane_id, "/work/telar");
    /// ```
    pub fn setPaneCwd(model: *Model, pane_id: schema.PaneId, path: []const u8) !MetadataChange {
        const pane = model.find(pane_id) orelse return .unchanged;
        if (std.mem.eql(u8, pane.cwdSlice(), path)) {
            return .unchanged;
        }

        return if (try pane.setCwd(path)) .display_changed else .stored;
    }

    /// Stores one pane foreground label without mutating composition caches.
    ///
    /// ```zig
    /// const change = model.setPaneForeground(pane_id, "zsh");
    /// ```
    pub fn setPaneForeground(model: *Model, pane_id: schema.PaneId, name: []const u8) MetadataChange {
        const pane = model.find(pane_id) orelse return .unchanged;

        return if (pane.setForegroundName(name)) .display_changed else .unchanged;
    }

    /// Stores one pane window title without mutating composition caches.
    ///
    /// ```zig
    /// const change = model.setPaneTitle(pane_id, "vim README.md");
    /// ```
    pub fn setPaneTitle(model: *Model, pane_id: schema.PaneId, title: []const u8) !MetadataChange {
        const pane = model.find(pane_id) orelse return .unchanged;

        return if (try pane.setTitle(title)) .display_changed else .unchanged;
    }

    pub fn addRoot(model: *Model, pane_id: schema.PaneId, location: schema.TabLocation, size: schema.TerminalSize) !void {
        if (model.pane_count != 0) {
            return error.ModelNotEmpty;
        }
        try model.insertPane(pane_id, location, size, true);
        errdefer _ = model.removePane(pane_id);
        try model.layout.addRoot(pane_id);
        model.location = location;
    }

    pub fn split(model: *Model, existing_pane: schema.PaneId, new_pane: schema.PaneId, location: schema.TabLocation, axis: layout_mod.Axis, area: ui.Rect) !void {
        const prospective = model.prospectiveSplit(existing_pane, axis, area) orelse
            return error.PaneTooSmall;
        const size = rectSize(prospective.new_content) orelse return error.PaneTooSmall;
        try model.insertPane(new_pane, location, size, true);
        errdefer _ = model.removePane(new_pane);
        try model.layout.split(existing_pane, new_pane, axis);
    }

    /// Adds panes discovered in a location snapshot. Reconstructed layouts are
    /// intentionally local and deterministic: each additional pane splits the
    /// currently focused leaf left-to-right. The runtime owns membership, so a
    /// pane the area cannot fit still joins the layout, detached and without
    /// visible content until the geometry changes.
    ///
    /// ```zig
    /// try model.addDiscovered(pane_id, location, area);
    /// ```
    pub fn addDiscovered(model: *Model, pane_id: schema.PaneId, location: schema.TabLocation, area: ui.Rect) !void {
        if (model.find(pane_id) != null) {
            return;
        }
        const focused = model.layout.focused() orelse {
            const size = rectSize(area) orelse placeholder_size;
            try model.insertPane(pane_id, location, size, false);
            errdefer _ = model.removePane(pane_id);
            try model.layout.addRoot(pane_id);
            model.location = location;
            return;
        };

        const size = if (model.prospectiveSplit(focused, .horizontal, area)) |prospective|
            rectSize(prospective.new_content) orelse placeholder_size
        else
            placeholder_size;
        try model.insertPane(pane_id, location, size, false);
        errdefer _ = model.removePane(pane_id);
        try model.layout.split(focused, pane_id, .horizontal);
    }

    pub fn restoreDisplayOrder(model: *Model, pane_ids: []const schema.PaneId, focused_pane: schema.PaneId) !void {
        if (pane_ids.len != model.pane_count) {
            return error.UnexpectedPaneCount;
        }
        for (pane_ids) |pane_id|
            if (model.find(pane_id) == null) return error.PaneNotFound;
        try model.layout.restoreDisplayOrder(pane_ids, focused_pane);
    }

    pub fn restoreSavedLayout(model: *Model, saved: layout_mod.Layout, pane_ids: []const schema.PaneId, focused_pane: schema.PaneId) bool {
        if (pane_ids.len != model.pane_count) {
            return false;
        }
        for (pane_ids) |pane_id|
            if (model.find(pane_id) == null) return false;
        if (!model.layout.restoreSaved(saved, pane_ids, focused_pane)) {
            return false;
        }
        return true;
    }

    pub fn markAttached(model: *Model, pane_id: schema.PaneId) !void {
        const pane = model.find(pane_id) orelse return error.PaneNotFound;
        pane.attached = true;
    }

    pub fn removePane(model: *Model, pane_id: schema.PaneId) bool {
        var removed = false;
        for (&model.panes) |*slot| {
            const pane = if (slot.*) |*value| value else continue;
            if (pane.id != pane_id) {
                continue;
            }
            pane.deinit();
            slot.* = null;
            model.pane_count -= 1;
            removed = true;
            break;
        }
        if (removed) {
            model.pane_index.remove(schema.id.raw(pane_id));
        }
        _ = model.layout.remove(pane_id);
        if (model.pane_count == 0) {
            model.location = null;
        }
        return removed;
    }

    pub fn focusPane(model: *Model, pane_id: schema.PaneId) bool {
        if (!model.layout.focusPane(pane_id)) {
            return false;
        }
        return true;
    }

    pub fn focusDirection(model: *Model, direction: layout_mod.Direction, area: ui.Rect) ?schema.PaneId {
        _ = model.layout.focused() orelse return null;
        const focused = model.layout.focusDirection(direction, area) orelse return null;
        return focused;
    }

    pub fn resizeFocused(model: *Model, direction: layout_mod.Direction, area: ui.Rect) bool {
        if (!model.layout.resizeFocused(direction, area)) {
            return false;
        }
        return true;
    }

    pub fn toggleFullscreen(model: *Model) bool {
        if (!model.layout.toggleFullscreen()) {
            return false;
        }
        return true;
    }

    pub fn applyFrame(model: *Model, frame: schema.frame.FrameView) !frame_apply.Applied {
        const pane = model.find(frame.pane_id) orelse return error.PaneNotFound;
        if (frame.base_frame_id != 0 and frame.base_frame_id != pane.applied_frame_id) {
            return error.FrameBaseMismatch;
        }
        const resized = pane.buffer.w != frame.cols or pane.buffer.h != frame.rows;
        const replacement_damage = if (resized)
            try model.gpa.alloc(DamageRow, frame.rows)
        else
            null;
        errdefer if (replacement_damage) |rows| model.gpa.free(rows);
        const applied = try frame_apply.applyBuffer(&pane.buffer, &pane.cursor, frame);
        pane.mouse = frame.mouse;
        pane.input_modes = frame.input_modes;
        pane.scroll = frame.scroll;
        if (replacement_damage) |rows| {
            @memset(rows, .{});
            model.gpa.free(pane.damage_rows);
            pane.damage_rows = rows;
        } else {
            var spans = frame.spans();
            while (try spans.next()) |span| pane.markSpan(span.start, span.cell_count);
        }
        pane.applied_frame_id = frame.frame_id;
        pane.pending_frame_id = frame.frame_id;
        return applied;
    }

    pub fn contentSize(model: *Model, pane_id: schema.PaneId, area: ui.Rect) ?schema.TerminalSize {
        const view = model.layoutSnapshot(area).find(pane_id) orelse return null;
        var size = rectSize(view.content) orelse return null;
        size.cell_width_px = model.cell_width_px;
        size.cell_height_px = model.cell_height_px;
        return size;
    }

    pub fn viewForPane(model: *Model, pane_id: schema.PaneId, area: ui.Rect) ?layout_mod.View {
        return model.layoutSnapshot(area).find(pane_id);
    }

    /// Resolves one pointer event to a visible pane and returns only the state
    /// required by mouse-input policy. Wheel events target the pane under the
    /// pointer; every other event targets the focused pane.
    ///
    /// ```zig
    /// const plan = model.planPaneMouse(event, area) orelse return;
    /// ```
    pub fn planPaneMouse(model: *Model, event: term.Event.Mouse, area: ui.Rect) ?PaneMousePlan {
        const snapshot = model.layoutSnapshot(area);
        const wheel = event.kind == .scroll_up or event.kind == .scroll_down;
        var pane = model.focusedPane() orelse return null;
        if (wheel) {
            for (snapshot.views()) |candidate| {
                if (!candidate.content.contains(event.x, event.y)) {
                    continue;
                }

                pane = model.find(candidate.pane_id) orelse return null;
                break;
            }
        }

        const view = snapshot.find(pane.id) orelse return null;
        if (!view.content.contains(event.x, event.y)) {
            return null;
        }

        return .{
            .pane_id = pane.id,
            .content = view.content,
            .protocol = pane.mouse,
            .alternate_scroll = pane.input_modes.alternate_screen and pane.input_modes.alternate_scroll,
            .at_bottom = pane.scroll.atBottom(pane.buffer.h),
        };
    }

    pub fn layoutSnapshot(model: *Model, area: ui.Rect) *const layout_mod.Snapshot {
        if (model.layout_snapshot.revision != model.layout.currentRevision() or
            !std.meta.eql(model.layout_snapshot.area, area))
        {
            model.layout.snapshot(area, &model.layout_snapshot);
        }
        return &model.layout_snapshot;
    }

    pub fn prospectiveSplit(model: *Model, pane_id: schema.PaneId, axis: layout_mod.Axis, area: ui.Rect) ?layout_mod.ProspectiveSplit {
        return model.layoutSnapshot(area).prospectiveSplit(pane_id, axis, model.pane_count);
    }

    pub fn setCellSize(model: *Model, width: u16, height: u16) void {
        if (model.cell_width_px == width and model.cell_height_px == height) {
            return;
        }
        model.cell_width_px = width;
        model.cell_height_px = height;
    }

    /// Sets one pane's cell fallback and reports whether composition changed.
    ///
    /// ```zig
    /// if (model.setGraphicsPlaceholder(pane_id, true)) scheduleObservation();
    /// ```
    pub fn setGraphicsPlaceholder(model: *Model, pane_id: schema.PaneId, visible: bool) bool {
        const pane = model.find(pane_id) orelse return false;
        if (pane.graphics_placeholder == visible) {
            return false;
        }
        pane.graphics_placeholder = visible;

        return true;
    }

    /// Retires only the damage and frame identifiers included in a successful
    /// host presentation. A stale commit cannot consume newer pane work.
    ///
    /// ```zig
    /// model.commitPresentation(commit);
    /// ```
    pub fn commitPresentation(model: *Model, commit: PresentationCommit) void {
        if (!std.meta.eql(model.location, commit.location)) {
            return;
        }

        for (commit.slice()) |presented| {
            const pane = model.find(presented.pane_id) orelse continue;
            if (pane.pending_frame_id != presented.frame_id) {
                continue;
            }

            pane.clearDamage();
            pane.pending_frame_id = 0;
        }
    }

    fn insertPane(model: *Model, pane_id: schema.PaneId, location: schema.TabLocation, size: schema.TerminalSize, attached: bool) !void {
        if (pane_id == .invalid) {
            return error.InvalidPaneId;
        }
        if (model.find(pane_id) != null) {
            return error.DuplicatePane;
        }
        if (model.pane_count == max_panes) {
            return error.PaneLimitReached;
        }
        for (&model.panes, 0..) |*slot, slot_index| {
            if (slot.* == null) {
                slot.* = try Pane.init(model.gpa, pane_id, location, size, attached);
                model.pane_count += 1;
                model.indexPane(pane_id, @intCast(slot_index));
                return;
            }
        }
        unreachable;
    }

    fn indexPane(model: *Model, pane_id: schema.PaneId, pane_slot: u8) void {
        model.pane_index.put(schema.id.raw(pane_id), pane_slot);
    }
};

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
    return diff.syncRow(source_row, sink.composed_row, range.start, range.end, &sink);
}

const PaneCursor = struct {
    content: ui.Rect,
    copy: ?copy_mode.View,
};

fn setPaneCursor(screen: *term.Screen, pane: *const Pane, projection: PaneCursor) void {
    if (projection.copy) |selection| {
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
        damaged += try diff.syncRow(
            source_row,
            screen.back.cells[row_start..][0..composed.w],
            0,
            composed.w,
            &sink,
        );
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
    return diff.syncRow(source_row, screen.back.cells[row_start..][0..composed.w], 0, composed.w, &sink);
}

/// The buffer a discovered pane keeps while the layout gives it no content.
const placeholder_size: schema.TerminalSize = .{ .cols = 1, .rows = 1 };

pub fn rectSize(rect: ui.Rect) ?schema.TerminalSize {
    if (rect.w == 0 or rect.h == 0) {
        return null;
    }
    return .{ .cols = rect.w, .rows = rect.h };
}

const BorderInput = struct {
    view: layout_mod.View,
    foreground_name: []const u8,
    progress_state: schema.PaneProgressState,
    progress_percent: ?u8,
    animation_frame: u8,
    palette: *const theme.Palette,
};

fn drawBorder(buffer: *ui.Buffer, input: BorderInput) void {
    const style: ui.Style = if (input.view.focused)
        .{ .fg = input.palette.accent, .flags = .{ .bold = true } }
    else
        .{ .fg = input.palette.overlay0 };
    var title_buffer: [schema.max_foreground_name_bytes + 32]u8 = undefined;
    const text = std.fmt.bufPrint(
        &title_buffer,
        " {d} {s} ",
        .{ input.view.display_index, if (input.foreground_name.len == 0) "shell" else input.foreground_name },
    ) catch " pane ";
    buffer.box(input.view.outer, style, text);
    drawProgress(buffer, input, ui.measure(text));
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
            buffer.setCell(start + x, input.view.outer.y, "━", 1, progress_style);
        }
    } else if (position > 0) {
        buffer.setCell(start + position - 1, input.view.outer.y, "·", 1, progress_style);
    }
    buffer.setCell(start + position, input.view.outer.y, head, 1, progress_style);
    if (input.progress_state == .indeterminate and position + 1 < width) {
        buffer.setCell(start + position + 1, input.view.outer.y, "·", 1, progress_style);
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
    _ = buffer.writeTruncated(area, x, y, label, width, .{
        .fg = palette.yellow,
        .bg = palette.surface_dim,
        .flags = .{ .bold = true },
    });
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

    drawBorder(&buffer, .{
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

    drawBorder(&buffer, .{
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
    try model.addRoot(@enumFromInt(1), location, .{ .cols = 20, .rows = 6 });
    try model.split(
        @enumFromInt(1),
        @enumFromInt(2),
        location,
        .horizontal,
        .{ .w = 40, .h = 7 },
    );
    model.find(@enumFromInt(1)).?.buffer.setCell(0, 0, "a", 1, .{});
    model.find(@enumFromInt(2)).?.buffer.setCell(0, 0, "b", 1, .{});

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
    try model.addRoot(first, location, .{ .cols = 40, .rows = 12 });
    try model.split(first, second, location, .horizontal, area);

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
    try model.addRoot(@enumFromInt(1), location, .{ .cols = 4, .rows = 2 });
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
    try model.addRoot(pane_id, location, .{ .cols = 4, .rows = 2 });
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
    pane.buffer.setCell(1, 0, "x", 1, .{});
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
    try model.addRoot(@enumFromInt(1), location, .{ .cols = 20, .rows = 6 });
    try model.split(@enumFromInt(1), @enumFromInt(2), location, .horizontal, area);
    try std.testing.expect(model.focusPane(@enumFromInt(1)));
    model.find(@enumFromInt(1)).?.buffer.setCell(0, 0, "x", 1, .{});
    model.find(@enumFromInt(2)).?.buffer.setCell(0, 0, "y", 1, .{});
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

test "fullscreen border keeps the pane's tiled display index" {
    const gpa = std.testing.allocator;
    var model = Model.init(gpa);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const area: ui.Rect = .{ .w = 40, .h = 7 };
    try model.addRoot(@enumFromInt(1), location, .{ .cols = 20, .rows = 6 });
    try model.split(@enumFromInt(1), @enumFromInt(2), location, .horizontal, area);
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

    // The title starts two cells in: " 2 shell ".
    try std.testing.expectEqualStrings(" ", screen.back.cells[2].text());
    try std.testing.expectEqualStrings("2", screen.back.cells[3].text());
    try std.testing.expectEqualStrings("│", screen.back.cells[area.w].text());
    try std.testing.expectEqualStrings("│", screen.back.cells[2 * area.w - 1].text());
}

test "pane borders use the selected theme without coloring pane contents" {
    const gpa = std.testing.allocator;
    var model = Model.init(gpa);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(@enumFromInt(10), location, .{ .cols = 10, .rows = 3 });
    try model.split(
        @enumFromInt(10),
        @enumFromInt(41),
        location,
        .horizontal,
        .{ .w = 20, .h = 4 },
    );
    const first = model.find(@enumFromInt(10)).?;
    const second = model.find(@enumFromInt(41)).?;
    try std.testing.expectEqual(MetadataChange.display_changed, model.setPaneForeground(first.id, "zsh"));
    try std.testing.expectEqual(MetadataChange.display_changed, model.setPaneForeground(second.id, "Claude Code"));
    first.buffer.setCell(0, 0, "x", 1, .{});
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
    try model.addRoot(@enumFromInt(1), location, .{ .cols = 12, .rows = 3 });
    model.find(@enumFromInt(1)).?.buffer.setCell(0, 0, "x", 1, .{});

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
    try model.addRoot(@enumFromInt(1), location, .{ .cols = 2, .rows = 1 });
    try model.split(
        @enumFromInt(1),
        @enumFromInt(2),
        location,
        .horizontal,
        .{ .w = 7, .h = 3 },
    );

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
    try model.addRoot(pane_id, location, .{ .cols = 2, .rows = 1 });
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
    try model.addRoot(pane_id, location, .{ .cols = 2, .rows = 1 });
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
    try model.addRoot(@enumFromInt(1), location, .{ .cols = 9, .rows = 3 });
    try model.split(@enumFromInt(1), @enumFromInt(2), location, .horizontal, area);
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
    try model.addRoot(@enumFromInt(1), location, .{ .cols = 40, .rows = 8 });
    try model.addDiscovered(
        @enumFromInt(2),
        location,
        .{ .w = 40, .h = 8 },
    );

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
    try model.addRoot(@enumFromInt(1), location, .{ .cols = 4, .rows = 3 });

    try model.addDiscovered(@enumFromInt(2), location, area);

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
    try model.addRoot(@enumFromInt(1), location, .{ .cols = 8, .rows = 3 });
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
    try model.addRoot(@enumFromInt(1), location, .{ .cols = 20, .rows = 5 });
    try model.split(
        @enumFromInt(1),
        @enumFromInt(2),
        location,
        .horizontal,
        .{ .w = 40, .h = 6 },
    );
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
    try model.addRoot(pane_id, location, .{ .cols = 24, .rows = 3 });
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
    try model.addRoot(@enumFromInt(1), location, .{ .cols = 80, .rows = 24 });
    try model.split(@enumFromInt(1), @enumFromInt(129), location, .horizontal, area);

    try std.testing.expect(model.removePane(@enumFromInt(1)));
    try std.testing.expect(model.find(@enumFromInt(1)) == null);
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(129)), model.find(@enumFromInt(129)).?.id);

    try model.addDiscovered(@enumFromInt(257), location, area);
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
    try model.addRoot(@enumFromInt(1), location, .{ .cols = 80, .rows = 24 });

    const first = model.layoutSnapshot(.{ .w = 80, .h = 24 });
    const first_revision = first.revision;
    try std.testing.expectEqual(@as(u16, 80), first.find(@enumFromInt(1)).?.content.w);

    const resized = model.layoutSnapshot(.{ .w = 40, .h = 12 });
    try std.testing.expectEqual(first_revision, resized.revision);
    try std.testing.expectEqual(@as(u16, 40), resized.find(@enumFromInt(1)).?.content.w);

    try model.split(
        @enumFromInt(1),
        @enumFromInt(2),
        location,
        .horizontal,
        .{ .w = 40, .h = 12 },
    );
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
    try model.addRoot(first, location, .{ .cols = 39, .rows = 24 });
    try model.split(first, second, location, .horizontal, area);
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
}
