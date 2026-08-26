//! Multi-pane client state and composition.

const std = @import("std");
const core = @import("telar-core");
const presentation = @import("../presentation/root.zig");
const input = @import("../input/root.zig");
const diff = presentation.diff;
const copy_mode = input.copy_mode;
const frame_apply = presentation.frame;
const layout_mod = @import("layout.zig");
const term = presentation.screen;
const theme = @import("../ui/root.zig").theme;

const schema = core.schema;
const max_cwd_name_bytes = 48;
const ui = core.ui;

pub const max_panes = layout_mod.max_panes;

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
    copy_view: ?copy_mode.View = null,
    applied_frame_id: u64 = 0,
    pending_frame_id: u64 = 0,
    graphics_placeholder: bool = false,
    cwd: []u8 = &.{},
    foreground_name: [schema.max_foreground_name_bytes]u8 = @splat(0),
    foreground_name_len: u8 = 0,

    fn init(
        gpa: std.mem.Allocator,
        pane_id: schema.PaneId,
        location: schema.TabLocation,
        size: schema.TerminalSize,
        attached: bool,
    ) !Pane {
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
        if (pane.cwd.len != 0) pane.gpa.free(pane.cwd);
        pane.gpa.free(pane.damage_rows);
        pane.buffer.deinit();
    }

    fn clearDamage(pane: *Pane) void {
        for (pane.damage_rows) |*row| row.clear();
    }

    fn markSpan(pane: *Pane, start: u32, count: u32) void {
        diff.markRows(pane.damage_rows, pane.buffer.w, start, count);
    }

    pub fn setCwd(pane: *Pane, path: []const u8) !bool {
        std.debug.assert(path.len != 0 and path.len <= schema.max_cwd_bytes);
        if (std.mem.eql(u8, pane.cwd, path)) return false;
        const display_changed = !std.mem.eql(u8, pane.cwdName(), displayCwdName(path));
        const replacement = try pane.gpa.dupe(u8, path);
        if (pane.cwd.len != 0) pane.gpa.free(pane.cwd);
        pane.cwd = replacement;
        return display_changed;
    }

    pub fn cwdName(pane: *const Pane) []const u8 {
        return displayCwdName(pane.cwd);
    }

    /// Returns the frame id awaiting acknowledgement and clears it; zero
    /// when nothing is pending.
    pub fn takePendingFrame(pane: *Pane) u64 {
        const frame_id = pane.pending_frame_id;
        pane.pending_frame_id = 0;
        return frame_id;
    }

    pub fn cwdSlice(pane: *const Pane) []const u8 {
        return pane.cwd;
    }

    pub fn setForegroundName(pane: *Pane, name: []const u8) bool {
        std.debug.assert(name.len != 0 and name.len <= pane.foreground_name.len);
        if (std.mem.eql(u8, pane.foregroundName(), name)) return false;
        @memcpy(pane.foreground_name[0..name.len], name);
        pane.foreground_name_len = @intCast(name.len);
        return true;
    }

    pub fn foregroundName(pane: *const Pane) []const u8 {
        return pane.foreground_name[0..pane.foreground_name_len];
    }
};

fn displayCwdName(path: []const u8) []const u8 {
    if (path.len == 0) return "";
    const basename = cwdBaseName(path);
    if (!validCwdName(basename)) return "";
    return truncateCwdName(basename);
}

fn cwdBaseName(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and isPathSeparator(path[end - 1])) end -= 1;
    const trimmed = path[0..end];
    if (trimmed.len == 1 and isPathSeparator(trimmed[0])) return trimmed;
    const separator = std.mem.lastIndexOfAny(u8, trimmed, "/\\") orelse return trimmed;
    const name = trimmed[separator + 1 ..];
    return if (name.len == 0) trimmed else name;
}

fn truncateCwdName(name: []const u8) []const u8 {
    if (name.len <= max_cwd_name_bytes) return name;
    var end: usize = max_cwd_name_bytes;
    while (end > 0 and name[end] & 0b1100_0000 == 0b1000_0000) end -= 1;
    return name[0..end];
}

fn validCwdName(name: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(name)) return false;
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

pub const Model = struct {
    gpa: std.mem.Allocator,
    layout: layout_mod.Layout = .{},
    panes: [max_panes]?Pane = [_]?Pane{null} ** max_panes,
    pane_index: PaneIndex = .{},
    pane_count: usize = 0,
    location: ?schema.TabLocation = null,
    composed: ?ui.Buffer = null,
    composition_area: ui.Rect = .{},
    composition_invalidated: bool = true,
    border_theme: ?BorderTheme = null,
    cell_width_px: u16 = 0,
    cell_height_px: u16 = 0,
    layout_snapshot: layout_mod.Snapshot = .{},

    pub fn init(gpa: std.mem.Allocator) Model {
        return .{ .gpa = gpa };
    }

    pub fn deinit(model: *Model) void {
        for (&model.panes) |*slot| {
            if (slot.*) |*pane| pane.deinit();
            slot.* = null;
        }
        if (model.composed) |*buffer| buffer.deinit();
        model.composed = null;
        model.pane_count = 0;
        model.pane_index.reset();
    }

    pub fn setPaneGaps(model: *Model, enabled: bool) void {
        if (!model.layout.setPaneGaps(enabled)) return;
        model.composition_invalidated = true;
    }

    /// Iterates the live panes without exposing the slot array.
    pub const PaneIterator = struct {
        panes: *[max_panes]?Pane,
        index: usize = 0,

        pub fn next(iterator: *PaneIterator) ?*Pane {
            while (iterator.index < max_panes) {
                const slot = &iterator.panes[iterator.index];
                iterator.index += 1;
                if (slot.*) |*pane| return pane;
            }
            return null;
        }
    };

    pub fn paneIterator(model: *Model) PaneIterator {
        return .{ .panes = &model.panes };
    }

    /// Projects the copy-mode selection onto a pane. Selection changes mark
    /// only the affected visible ranges; clearing passes null.
    pub fn setPaneCopyView(model: *Model, pane_id: schema.PaneId, view: ?copy_mode.View) void {
        const pane = model.find(pane_id) orelse return;
        if (std.meta.eql(pane.copy_view, view)) return;
        markCopyViewDamage(pane, pane.copy_view, view);
        pane.copy_view = view;
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
        if (pane_id == .invalid) return null;
        const slot = model.pane_index.get(schema.id.raw(pane_id)) orelse return null;
        return &model.panes[slot].?;
    }

    pub fn findConst(model: *const Model, pane_id: schema.PaneId) ?*const Pane {
        if (pane_id == .invalid) return null;
        const slot = model.pane_index.get(schema.id.raw(pane_id)) orelse return null;
        return &model.panes[slot].?;
    }

    pub fn addRoot(
        model: *Model,
        pane_id: schema.PaneId,
        location: schema.TabLocation,
        size: schema.TerminalSize,
    ) !void {
        if (model.pane_count != 0) return error.ModelNotEmpty;
        try model.insertPane(pane_id, location, size, true);
        errdefer _ = model.removePane(pane_id);
        try model.layout.addRoot(pane_id);
        model.location = location;
        model.composition_invalidated = true;
    }

    pub fn split(
        model: *Model,
        existing_pane: schema.PaneId,
        new_pane: schema.PaneId,
        location: schema.TabLocation,
        axis: layout_mod.Axis,
        area: ui.Rect,
    ) !void {
        const prospective = model.prospectiveSplit(existing_pane, axis, area) orelse
            return error.PaneTooSmall;
        const size = rectSize(prospective.new_content) orelse return error.PaneTooSmall;
        try model.insertPane(new_pane, location, size, true);
        errdefer _ = model.removePane(new_pane);
        try model.layout.split(existing_pane, new_pane, axis);
        model.composition_invalidated = true;
    }

    /// Adds panes discovered in a location snapshot. Reconstructed layouts are
    /// intentionally local and deterministic: each additional pane splits the
    /// currently focused leaf left-to-right.
    pub fn addDiscovered(
        model: *Model,
        pane_id: schema.PaneId,
        location: schema.TabLocation,
        area: ui.Rect,
    ) !void {
        if (model.find(pane_id) != null) return;
        const focused = model.layout.focused() orelse {
            const size = rectSize(area) orelse return error.PaneTooSmall;
            try model.insertPane(pane_id, location, size, false);
            errdefer _ = model.removePane(pane_id);
            try model.layout.addRoot(pane_id);
            model.location = location;
            model.composition_invalidated = true;
            return;
        };
        const prospective = model.prospectiveSplit(focused, .horizontal, area) orelse
            return error.PaneTooSmall;
        const size = rectSize(prospective.new_content) orelse return error.PaneTooSmall;
        try model.insertPane(pane_id, location, size, false);
        errdefer _ = model.removePane(pane_id);
        try model.layout.split(focused, pane_id, .horizontal);
        model.composition_invalidated = true;
    }

    pub fn restoreDisplayOrder(
        model: *Model,
        pane_ids: []const schema.PaneId,
        focused_pane: schema.PaneId,
    ) !void {
        if (pane_ids.len != model.pane_count) return error.UnexpectedPaneCount;
        for (pane_ids) |pane_id|
            if (model.find(pane_id) == null) return error.PaneNotFound;
        try model.layout.restoreDisplayOrder(pane_ids, focused_pane);
        model.composition_invalidated = true;
    }

    pub fn restoreSavedLayout(
        model: *Model,
        saved: layout_mod.Layout,
        pane_ids: []const schema.PaneId,
        focused_pane: schema.PaneId,
    ) bool {
        if (pane_ids.len != model.pane_count) return false;
        for (pane_ids) |pane_id|
            if (model.find(pane_id) == null) return false;
        if (!model.layout.restoreSaved(saved, pane_ids, focused_pane)) return false;
        model.composition_invalidated = true;
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
            if (pane.id != pane_id) continue;
            pane.deinit();
            slot.* = null;
            model.pane_count -= 1;
            removed = true;
            break;
        }
        if (removed) model.pane_index.remove(schema.id.raw(pane_id));
        _ = model.layout.remove(pane_id);
        if (model.pane_count == 0) model.location = null;
        if (removed) model.composition_invalidated = true;
        return removed;
    }

    pub fn focusPane(model: *Model, pane_id: schema.PaneId) bool {
        const previous = model.layout.focused();
        if (!model.layout.focusPane(pane_id)) return false;
        if (previous != pane_id) model.composition_invalidated = true;
        return true;
    }

    pub const FocusShift = struct { focused: bool, layout_changed: bool };

    /// Focuses the pane and reports whether the change altered geometry,
    /// which happens only while fullscreen, where the fullscreened pane
    /// follows focus.
    pub fn focusPaneShift(model: *Model, pane_id: schema.PaneId) FocusShift {
        const previous = model.layout.focused();
        if (!model.focusPane(pane_id)) return .{ .focused = false, .layout_changed = false };
        return .{
            .focused = true,
            .layout_changed = model.layout.isFullscreen() and
                previous != model.layout.focused(),
        };
    }

    pub fn focusDirection(
        model: *Model,
        direction: layout_mod.Direction,
        area: ui.Rect,
    ) ?schema.PaneId {
        const previous = model.layout.focused() orelse return null;
        const focused = model.layout.focusDirection(direction, area) orelse return null;
        if (previous != focused) model.composition_invalidated = true;
        return focused;
    }

    pub fn resizeFocused(
        model: *Model,
        direction: layout_mod.Direction,
        area: ui.Rect,
    ) bool {
        if (!model.layout.resizeFocused(direction, area)) return false;
        model.composition_invalidated = true;
        return true;
    }

    pub fn toggleFullscreen(model: *Model) bool {
        if (!model.layout.toggleFullscreen()) return false;
        model.composition_invalidated = true;
        return true;
    }

    pub fn applyFrame(
        model: *Model,
        frame: schema.frame.FrameView,
    ) !frame_apply.Applied {
        const pane = model.find(frame.pane_id) orelse return error.PaneNotFound;
        if (frame.base_frame_id != 0 and frame.base_frame_id != pane.applied_frame_id)
            return error.FrameBaseMismatch;
        const resized = pane.buffer.w != frame.cols or pane.buffer.h != frame.rows;
        const replacement_damage = if (resized)
            try model.gpa.alloc(DamageRow, frame.rows)
        else
            null;
        errdefer if (replacement_damage) |rows| model.gpa.free(rows);
        const applied = try frame_apply.applyBuffer(&pane.buffer, &pane.cursor, frame);
        pane.mouse = frame.mouse;
        pane.input_modes = frame.input_modes;
        if (!std.meta.eql(pane.scroll, frame.scroll)) model.composition_invalidated = true;
        pane.scroll = frame.scroll;
        if (replacement_damage) |rows| {
            @memset(rows, .{});
            model.gpa.free(pane.damage_rows);
            pane.damage_rows = rows;
            model.composition_invalidated = true;
        } else {
            var spans = frame.spans();
            while (try spans.next()) |span| pane.markSpan(span.start, span.cell_count);
        }
        pane.applied_frame_id = frame.frame_id;
        pane.pending_frame_id = frame.frame_id;
        return applied;
    }

    pub fn contentSize(
        model: *Model,
        pane_id: schema.PaneId,
        area: ui.Rect,
    ) ?schema.TerminalSize {
        const view = model.layoutSnapshot(area).find(pane_id) orelse return null;
        var size = rectSize(view.content) orelse return null;
        size.cell_width_px = model.cell_width_px;
        size.cell_height_px = model.cell_height_px;
        return size;
    }

    pub fn viewForPane(
        model: *Model,
        pane_id: schema.PaneId,
        area: ui.Rect,
    ) ?layout_mod.View {
        return model.layoutSnapshot(area).find(pane_id);
    }

    pub fn layoutSnapshot(model: *Model, area: ui.Rect) *const layout_mod.Snapshot {
        if (model.layout_snapshot.revision != model.layout.currentRevision() or
            !std.meta.eql(model.layout_snapshot.area, area))
        {
            model.layout.snapshot(area, &model.layout_snapshot);
        }
        return &model.layout_snapshot;
    }

    /// Restores a client overlay region from the pane composition cache.
    /// Toasts draw into the terminal screen but never mutate this cache, so
    /// removing one costs only its bounded rectangle instead of recomposing
    /// the complete workbench.
    pub fn copyComposedArea(model: *const Model, destination: *ui.Buffer, area: ui.Rect) void {
        const source = if (model.composed) |*buffer| buffer else return;
        if (source.w != destination.w or source.h != destination.h) return;
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

    pub fn prospectiveSplit(
        model: *Model,
        pane_id: schema.PaneId,
        axis: layout_mod.Axis,
        area: ui.Rect,
    ) ?layout_mod.ProspectiveSplit {
        return model.layoutSnapshot(area).prospectiveSplit(pane_id, axis, model.pane_count);
    }

    pub fn render(model: *Model, screen: *term.Screen, area: ui.Rect) !RenderStats {
        return model.renderThemed(screen, area, &theme.default_theme.palette);
    }

    pub fn renderThemed(
        model: *Model,
        screen: *term.Screen,
        area: ui.Rect,
        palette: *const theme.Palette,
    ) !RenderStats {
        const border_theme: BorderTheme = .{
            .focused = palette.accent,
            .unfocused = palette.overlay0,
        };
        if (model.border_theme == null or !std.meta.eql(model.border_theme.?, border_theme)) {
            model.border_theme = border_theme;
            model.composition_invalidated = true;
        }
        if (try model.ensureComposed(screen.back.w, screen.back.h))
            model.composition_invalidated = true;
        if (!std.meta.eql(model.composition_area, area)) {
            model.composition_area = area;
            model.composition_invalidated = true;
        }
        const target = &model.composed.?;
        if (!model.composition_invalidated) {
            const stats = try model.composeIncremental(
                screen,
                target,
                model.layoutSnapshot(area),
            );
            model.clearPaneDamage();
            return stats;
        }

        target.clear(.{});
        screen.cursor = null;
        var stats: RenderStats = .{ .full = true };
        const snapshot = model.layoutSnapshot(area);
        for (snapshot.views(), 0..) |view, index| {
            const pane = model.find(view.pane_id) orelse continue;
            stats.panes += 1;
            if (model.layout.count() > 1 and !model.layout.isFullscreen())
                drawBorder(target, view, pane.foregroundName(), index + 1, palette);
            target.pushClip(view.content);
            defer target.popClip();
            const rows = @min(view.content.h, pane.buffer.h);
            const cols = @min(view.content.w, pane.buffer.w);
            var y: u16 = 0;
            while (y < rows) : (y += 1) {
                var x: u16 = 0;
                while (x < cols) : (x += 1) {
                    const source = &pane.buffer.cells[
                        @as(usize, y) * pane.buffer.w + x
                    ];
                    var style = source.style;
                    if (pane.copy_view) |copy| {
                        const absolute_y = pane.scroll.offset + y;
                        if (copy.selected(x, absolute_y)) style.flags.inverse = !style.flags.inverse;
                    }
                    target.setCell(
                        view.content.x + x,
                        view.content.y + y,
                        source.text(),
                        source.width,
                        style,
                    );
                    stats.cells += 1;
                }
            }
            if (view.focused) setPaneCursor(screen, pane, view.content);
            if (pane.graphics_placeholder) drawGraphicsPlaceholder(target, view.content, palette);
        }
        stats.damaged_cells = try syncComposed(screen, target);
        model.composition_invalidated = false;
        model.clearPaneDamage();
        return stats;
    }

    fn ensureComposed(model: *Model, width: u16, height: u16) !bool {
        if (model.composed) |*buffer| {
            if (buffer.w == width and buffer.h == height) return false;
            try buffer.resize(width, height);
            return true;
        }
        model.composed = try .init(model.gpa, width, height);
        return true;
    }

    fn composeIncremental(
        model: *Model,
        screen: *term.Screen,
        target: *ui.Buffer,
        snapshot: *const layout_mod.Snapshot,
    ) !RenderStats {
        var stats: RenderStats = .{};
        screen.cursor = null;
        for (snapshot.views()) |view| {
            const pane = model.find(view.pane_id) orelse continue;
            stats.panes += 1;
            const rows = @min(view.content.h, pane.buffer.h);
            const cols = @min(view.content.w, pane.buffer.w);
            var y: u16 = 0;
            while (y < rows) : (y += 1) {
                const damage = pane.damage_rows[y];
                if (!damage.dirty()) continue;
                const start = @min(damage.start, cols);
                const end = @min(damage.end, cols);
                if (start >= end) continue;
                stats.cells += end - start;
                stats.damaged_cells += try syncPaneRange(
                    screen,
                    target,
                    pane,
                    view.content.x,
                    view.content.y + y,
                    y,
                    start,
                    end,
                );
            }
            if (view.focused) setPaneCursor(screen, pane, view.content);
        }
        return stats;
    }

    pub fn setCellSize(model: *Model, width: u16, height: u16) void {
        if (model.cell_width_px == width and model.cell_height_px == height) return;
        model.cell_width_px = width;
        model.cell_height_px = height;
        model.composition_invalidated = true;
    }

    pub fn setGraphicsPlaceholder(model: *Model, pane_id: schema.PaneId, visible: bool) void {
        const pane = model.find(pane_id) orelse return;
        if (pane.graphics_placeholder == visible) return;
        pane.graphics_placeholder = visible;
        model.composition_invalidated = true;
    }

    fn clearPaneDamage(model: *Model) void {
        for (&model.panes) |*slot| {
            const pane = if (slot.*) |*value| value else continue;
            pane.clearDamage();
        }
    }

    fn insertPane(
        model: *Model,
        pane_id: schema.PaneId,
        location: schema.TabLocation,
        size: schema.TerminalSize,
        attached: bool,
    ) !void {
        if (pane_id == .invalid) return error.InvalidPaneId;
        if (model.find(pane_id) != null) return error.DuplicatePane;
        if (model.pane_count == max_panes) return error.PaneLimitReached;
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

fn syncPaneRange(
    screen: *term.Screen,
    composed: *ui.Buffer,
    pane: *const Pane,
    destination_x: u16,
    destination_y: u16,
    source_y: u16,
    start: u16,
    end: u16,
) !usize {
    std.debug.assert(start < end);
    const source_row = pane.buffer.cells[@as(usize, source_y) * pane.buffer.w ..];
    const destination_base = @as(usize, destination_y) * composed.w + destination_x;
    if (pane.copy_view) |copy| {
        const composed_row = composed.cells[destination_base..];
        const absolute_y = pane.scroll.offset + source_y;
        var copied: usize = 0;
        var x = start;
        while (x < end) {
            var projected = source_row[x];
            if (copy.selected(x, absolute_y))
                projected.style.flags.inverse = !projected.style.flags.inverse;
            if (projected.eqlPublic(&composed_row[x])) {
                x += 1;
                continue;
            }
            const run_start = x;
            while (x < end) : (x += 1) {
                projected = source_row[x];
                if (copy.selected(x, absolute_y))
                    projected.style.flags.inverse = !projected.style.flags.inverse;
                if (projected.eqlPublic(&composed_row[x])) break;
                composed_row[x] = projected;
            }
            const count: u16 = x - run_start;
            const destination = try screen.patchCells(
                @intCast(destination_base + run_start),
                count,
            );
            @memcpy(destination, composed_row[run_start..][0..count]);
            copied += count;
        }
        return copied;
    }
    var sink: ComposeSink = .{
        .patch = .{ .screen = screen, .source_row = source_row, .base = destination_base },
        .composed_row = composed.cells[destination_base..],
    };
    return diff.syncRow(source_row, sink.composed_row, start, end, &sink);
}

const CopySelectionRange = struct {
    start: u16,
    end: u16,
};

fn copySelectionRange(view: ?copy_mode.View, y: u32, cols: u16) ?CopySelectionRange {
    if (cols == 0) return null;
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
    if (y < first.y or y > last.y) return null;
    const start: u16 = if (y == first.y) @min(first.x, cols) else 0;
    const end: u16 = if (y == last.y)
        @min(last.x +| 1, cols)
    else
        cols;
    return if (start < end) .{ .start = start, .end = end } else null;
}

fn markCopyViewDamage(
    pane: *Pane,
    previous: ?copy_mode.View,
    next: ?copy_mode.View,
) void {
    var source_y: u16 = 0;
    while (source_y < pane.buffer.h) : (source_y += 1) {
        const absolute_y = pane.scroll.offset + source_y;
        const before = copySelectionRange(previous, absolute_y, pane.buffer.w);
        const after = copySelectionRange(next, absolute_y, pane.buffer.w);
        if (std.meta.eql(before, after)) continue;
        const start = @min(
            if (before) |range| range.start else pane.buffer.w,
            if (after) |range| range.start else pane.buffer.w,
        );
        const end = @max(
            if (before) |range| range.end else 0,
            if (after) |range| range.end else 0,
        );
        if (start < end) pane.damage_rows[source_y].mark(start, end);
    }
}

fn setPaneCursor(screen: *term.Screen, pane: *const Pane, content: ui.Rect) void {
    if (pane.copy_view) |copy| {
        if (copy.cursor.y < pane.scroll.offset or copy.cursor.x >= content.w) return;
        const visible_y = copy.cursor.y - pane.scroll.offset;
        if (visible_y >= content.h) return;
        screen.cursor = .{
            .x = content.x + copy.cursor.x,
            .y = content.y + @as(u16, @intCast(visible_y)),
        };
        return;
    }
    if (!pane.cursor.visible or pane.cursor.x >= content.w or pane.cursor.y >= content.h) return;
    screen.cursor = .{
        .x = content.x + pane.cursor.x,
        .y = content.y + pane.cursor.y,
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

pub fn rectSize(rect: ui.Rect) ?schema.TerminalSize {
    if (rect.w == 0 or rect.h == 0) return null;
    return .{ .cols = rect.w, .rows = rect.h };
}

fn drawBorder(
    buffer: *ui.Buffer,
    view: layout_mod.View,
    foreground_name: []const u8,
    pane_index: usize,
    palette: *const theme.Palette,
) void {
    const style: ui.Style = if (view.focused)
        .{ .fg = palette.accent, .flags = .{ .bold = true } }
    else
        .{ .fg = palette.overlay0 };
    var title_buffer: [schema.max_foreground_name_bytes + 32]u8 = undefined;
    const text = std.fmt.bufPrint(
        &title_buffer,
        " {d} {s} ",
        .{ pane_index, if (foreground_name.len == 0) "shell" else foreground_name },
    ) catch " pane ";
    buffer.box(view.outer, style, text);
}

fn drawGraphicsPlaceholder(buffer: *ui.Buffer, area: ui.Rect, palette: *const theme.Palette) void {
    if (area.w == 0 or area.h == 0) return;
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
    const stats = try model.render(&screen, screen.back.area());

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
    pane.copy_view = .{
        .anchor = .{ .x = 1, .y = 10 },
        .cursor = .{ .x = 2, .y = 11 },
        .linewise = false,
    };

    var screen = try term.Screen.init(gpa, 4, 2);
    defer screen.deinit();
    _ = try model.render(&screen, screen.back.area());

    try std.testing.expect(!screen.back.cells[0].style.flags.inverse);
    try std.testing.expect(screen.back.cells[1].style.flags.inverse);
    try std.testing.expect(screen.back.cells[6].style.flags.inverse);
    try std.testing.expect(!screen.back.cells[7].style.flags.inverse);
    try std.testing.expectEqual(term.Screen.Position{ .x = 2, .y = 1 }, screen.cursor.?);
}

test "copy mode updates selection and cursor without full composition" {
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
    try std.testing.expect((try model.render(&screen, screen.back.area())).full);

    model.setPaneCopyView(pane_id, .{
        .anchor = null,
        .cursor = .{ .x = 2, .y = 1 },
        .linewise = false,
    });
    const cursor_only = try model.render(&screen, screen.back.area());
    try std.testing.expect(!cursor_only.full);
    try std.testing.expectEqual(@as(usize, 0), cursor_only.cells);
    try std.testing.expectEqual(term.Screen.Position{ .x = 2, .y = 1 }, screen.cursor.?);

    model.setPaneCopyView(pane_id, .{
        .anchor = .{ .x = 1, .y = 0 },
        .cursor = .{ .x = 2, .y = 0 },
        .linewise = false,
    });
    const selected = try model.render(&screen, screen.back.area());
    try std.testing.expect(!selected.full);
    try std.testing.expectEqual(@as(usize, 2), selected.cells);
    try std.testing.expect(screen.back.cells[1].style.flags.inverse);
    try std.testing.expect(screen.back.cells[2].style.flags.inverse);

    const pane = model.find(pane_id).?;
    pane.buffer.setCell(1, 0, "x", 1, .{});
    pane.markSpan(1, 1);
    const patched = try model.render(&screen, screen.back.area());
    try std.testing.expect(!patched.full);
    try std.testing.expectEqual(@as(usize, 1), patched.cells);
    try std.testing.expectEqualStrings("x", screen.back.cells[1].text());
    try std.testing.expect(screen.back.cells[1].style.flags.inverse);

    const idle = try model.render(&screen, screen.back.area());
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
        schema.TerminalSize{ .cols = 40, .rows = 7 },
        model.contentSize(@enumFromInt(1), area).?,
    );
    try std.testing.expectEqual(@as(?schema.TerminalSize, null), model.contentSize(@enumFromInt(2), area));
    var screen = try term.Screen.init(gpa, area.w, area.h);
    defer screen.deinit();
    const stats = try model.render(&screen, area);
    try std.testing.expectEqual(@as(usize, 1), stats.panes);
    try std.testing.expectEqualStrings("x", screen.back.cells[0].text());

    try std.testing.expect(model.toggleFullscreen());
    try std.testing.expect(model.contentSize(@enumFromInt(2), area) != null);
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
    try std.testing.expect(first.setForegroundName("zsh"));
    try std.testing.expect(second.setForegroundName("Claude Code"));
    first.buffer.setCell(0, 0, "x", 1, .{});
    const selected = theme.builtin(.tokyo_night);
    var screen = try term.Screen.init(gpa, 20, 4);
    defer screen.deinit();
    _ = try model.renderThemed(&screen, screen.back.area(), &selected.palette);

    try std.testing.expectEqualDeep(selected.palette.accent, screen.back.cells[10].style.fg);
    try std.testing.expectEqualDeep(ui.Color.default, screen.back.cells[21].style.bg);
    try std.testing.expectEqualStrings("1", screen.back.at(3, 0).?.text());
    try std.testing.expectEqualStrings("z", screen.back.at(5, 0).?.text());
    try std.testing.expectEqualStrings("2", screen.back.at(13, 0).?.text());
    try std.testing.expectEqualStrings("C", screen.back.at(15, 0).?.text());

    const replacement = theme.builtin(.catppuccin);
    const replaced = try model.renderThemed(&screen, screen.back.area(), &replacement.palette);
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
    _ = try model.render(&screen, screen.back.area());

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

    const first = try model.render(&screen, screen.back.area());
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
    const snapshot = try model.render(&screen, screen.back.area());
    var snapshot_writer = std.Io.Writer.fixed(&output);
    _ = try screen.flush(&snapshot_writer);

    const second = try model.render(&screen, screen.back.area());
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
    const changed = try model.render(&screen, screen.back.area());
    var changed_writer = std.Io.Writer.fixed(&output);
    const changed_flush = try screen.flush(&changed_writer);
    try std.testing.expectEqual(@as(usize, 1), changed.cells);
    try std.testing.expectEqual(@as(usize, 1), changed.damaged_cells);
    try std.testing.expectEqual(@as(usize, 1), changed_flush.scanned);
}

test "focus changes invalidate titles but stable focus stays incremental" {
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

    try std.testing.expect((try model.render(&screen, screen.back.area())).full);
    try std.testing.expect(model.focusPane(@enumFromInt(1)));
    try std.testing.expect((try model.render(&screen, screen.back.area())).full);
    try std.testing.expect(model.focusPane(@enumFromInt(1)));
    const stable = try model.render(&screen, screen.back.area());
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
