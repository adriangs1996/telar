//! Multi-pane client state and composition.

const std = @import("std");
const core = @import("telar-core");
const diff = @import("diff.zig");
const frame_apply = @import("frame.zig");
const layout_mod = @import("layout.zig");
const term = @import("term.zig");
const theme = @import("theme.zig");

const schema = core.schema;
const ui = core.ui;

pub const max_panes = layout_mod.max_panes;

const DamageRow = diff.DamageRow;

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
    applied_frame_id: u64 = 0,
    pending_frame_id: u64 = 0,
    graphics_placeholder: bool = false,

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
        };
    }

    fn deinit(pane: *Pane) void {
        pane.gpa.free(pane.damage_rows);
        pane.buffer.deinit();
    }

    fn clearDamage(pane: *Pane) void {
        for (pane.damage_rows) |*row| row.clear();
    }

    fn markSpan(pane: *Pane, start: u32, count: u32) void {
        diff.markRows(pane.damage_rows, pane.buffer.w, start, count);
    }
};

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
    pane_count: usize = 0,
    location: ?schema.TabLocation = null,
    composed: ?ui.Buffer = null,
    composition_area: ui.Rect = .{},
    composition_invalidated: bool = true,
    border_theme: ?BorderTheme = null,
    cell_width_px: u16 = 0,
    cell_height_px: u16 = 0,

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
    }

    pub fn focusedPane(model: *Model) ?*Pane {
        const pane_id = model.layout.focused() orelse return null;
        return model.find(pane_id);
    }

    pub fn find(model: *Model, pane_id: schema.PaneId) ?*Pane {
        for (&model.panes) |*slot| {
            const pane = if (slot.*) |*value| value else continue;
            if (pane.id == pane_id) return pane;
        }
        return null;
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
        const prospective = model.layout.prospectiveSplit(existing_pane, axis, area) orelse
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
        const prospective = model.layout.prospectiveSplit(focused, .horizontal, area) orelse
            return error.PaneTooSmall;
        const size = rectSize(prospective.new_content) orelse return error.PaneTooSmall;
        try model.insertPane(pane_id, location, size, false);
        errdefer _ = model.removePane(pane_id);
        try model.layout.split(focused, pane_id, .horizontal);
        model.composition_invalidated = true;
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

    pub fn focusDirection(
        model: *Model,
        direction: layout_mod.Direction,
        area: ui.Rect,
    ) ?schema.PaneId {
        const previous = model.layout.focused();
        const focused = model.layout.focusDirection(direction, area) orelse return null;
        if (previous != focused) model.composition_invalidated = true;
        return focused;
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
        model: *const Model,
        pane_id: schema.PaneId,
        area: ui.Rect,
    ) ?schema.TerminalSize {
        var storage: [max_panes]layout_mod.View = undefined;
        for (model.layout.views(area, &storage)) |view| {
            if (view.pane_id == pane_id) {
                var size = rectSize(view.content) orelse return null;
                size.cell_width_px = model.cell_width_px;
                size.cell_height_px = model.cell_height_px;
                return size;
            }
        }
        return null;
    }

    pub fn viewForPane(
        model: *const Model,
        pane_id: schema.PaneId,
        area: ui.Rect,
    ) ?layout_mod.View {
        var storage: [max_panes]layout_mod.View = undefined;
        for (model.layout.views(area, &storage)) |view|
            if (view.pane_id == pane_id) return view;
        return null;
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
            const stats = try model.composeIncremental(screen, target, area);
            model.clearPaneDamage();
            return stats;
        }

        target.clear(.{});
        screen.cursor = null;
        var stats: RenderStats = .{ .full = true };
        var storage: [max_panes]layout_mod.View = undefined;
        for (model.layout.views(area, &storage)) |view| {
            const pane = model.find(view.pane_id) orelse continue;
            stats.panes += 1;
            if (model.layout.count() > 1) drawBorder(target, view, palette);
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
                    target.setCell(
                        view.content.x + x,
                        view.content.y + y,
                        source.text(),
                        source.width,
                        source.style,
                    );
                    stats.cells += 1;
                }
            }
            if (view.focused and pane.cursor.visible and
                pane.cursor.x < view.content.w and pane.cursor.y < view.content.h)
            {
                screen.cursor = .{
                    .x = view.content.x + pane.cursor.x,
                    .y = view.content.y + pane.cursor.y,
                };
            }
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
        area: ui.Rect,
    ) !RenderStats {
        var stats: RenderStats = .{};
        screen.cursor = null;
        var storage: [max_panes]layout_mod.View = undefined;
        for (model.layout.views(area, &storage)) |view| {
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
            if (view.focused and pane.cursor.visible and
                pane.cursor.x < view.content.w and pane.cursor.y < view.content.h)
            {
                screen.cursor = .{
                    .x = view.content.x + pane.cursor.x,
                    .y = view.content.y + pane.cursor.y,
                };
            }
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
        for (&model.panes) |*slot| {
            if (slot.* == null) {
                slot.* = try Pane.init(model.gpa, pane_id, location, size, attached);
                model.pane_count += 1;
                return;
            }
        }
        unreachable;
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
    var sink: ComposeSink = .{
        .patch = .{ .screen = screen, .source_row = source_row, .base = destination_base },
        .composed_row = composed.cells[destination_base..],
    };
    return diff.syncRow(source_row, sink.composed_row, start, end, &sink);
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

fn drawBorder(buffer: *ui.Buffer, view: layout_mod.View, palette: *const theme.Palette) void {
    const style: ui.Style = if (view.focused)
        .{ .fg = palette.accent, .flags = .{ .bold = true } }
    else
        .{ .fg = palette.overlay0 };
    var title_buffer: [32]u8 = undefined;
    const text = std.fmt.bufPrint(
        &title_buffer,
        " pane {d} ",
        .{schema.id.raw(view.pane_id)},
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

test "pane borders use the selected theme without coloring pane contents" {
    const gpa = std.testing.allocator;
    var model = Model.init(gpa);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(@enumFromInt(1), location, .{ .cols = 10, .rows = 3 });
    try model.split(
        @enumFromInt(1),
        @enumFromInt(2),
        location,
        .horizontal,
        .{ .w = 20, .h = 4 },
    );
    model.find(@enumFromInt(1)).?.buffer.setCell(0, 0, "x", 1, .{});
    const selected = theme.builtin(.tokyo_night);
    var screen = try term.Screen.init(gpa, 20, 4);
    defer screen.deinit();
    _ = try model.renderThemed(&screen, screen.back.area(), &selected.palette);

    try std.testing.expectEqualDeep(selected.palette.accent, screen.back.cells[10].style.fg);
    try std.testing.expectEqualDeep(ui.Color.default, screen.back.cells[21].style.bg);

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
