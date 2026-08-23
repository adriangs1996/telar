//! Visible structure and interaction state of one telar client.

const std = @import("std");
const core = @import("telar-core");
const multiplexer = @import("multiplexer.zig");
const term = @import("term.zig");
const ui = @import("ui.zig");

const schema = core.schema.v2;

pub const sidebar_width: u16 = 30;
pub const minimum_workbench_width: u16 = 20;

pub const Regions = struct {
    full: ui.Rect,
    top: ui.Rect,
    body: ui.Rect,
    sidebar: ui.Rect,
    workbench: ui.Rect,
    bottom: ui.Rect,
    tabs: ui.Rect,
    status: ui.Rect,

    pub fn calculate(width: u16, height: u16, sidebar_requested: bool) Regions {
        const full: ui.Rect = .{ .w = width, .h = height };
        const top_height: u16 = @intFromBool(height != 0);
        const bottom_height: u16 = @intFromBool(height >= 2);
        const top, const below_top = full.splitTop(top_height);
        const body, const bottom = below_top.splitBottom(bottom_height);

        const can_show_sidebar = sidebar_requested and
            body.w >= minimum_workbench_width + 12;
        const requested_width = @min(sidebar_width, body.w -| minimum_workbench_width);
        const actual_width: u16 = if (can_show_sidebar) requested_width else 0;
        const sidebar, const workbench = body.splitLeft(actual_width);

        const status_width = @min(@as(u16, 24), bottom.w / 2);
        const tabs_width = bottom.w - status_width;
        const tabs, const status = bottom.splitLeft(tabs_width);
        return .{
            .full = full,
            .top = top,
            .body = body,
            .sidebar = sidebar,
            .workbench = workbench,
            .bottom = bottom,
            .tabs = tabs,
            .status = status,
        };
    }
};

pub const Action = union(enum) {
    toggle_sidebar,
    focus_pane: schema.PaneId,
    select_tab: u8,
    active_workspace,
    active_worktree,
};

const Hits = ui.Hits(Action, 128);

pub const Interaction = struct {
    redraw: bool = false,
    layout_changed: bool = false,
};

pub const RenderStats = struct {
    scanned: usize = 0,
    damaged: usize = 0,
};

pub const State = struct {
    scratch: ui.Buffer,
    regions: Regions,
    hits: Hits = .{},
    sidebar_requested: bool = true,
    hovered: ?Action = null,
    active_tab: u8 = 0,
    dirty: bool = true,

    pub fn init(gpa: std.mem.Allocator, width: u16, height: u16) !State {
        return .{
            .scratch = try .init(gpa, width, height),
            .regions = .calculate(width, height, true),
        };
    }

    pub fn deinit(state: *State) void {
        state.scratch.deinit();
    }

    pub fn resize(state: *State, width: u16, height: u16) !void {
        if (state.scratch.w != width or state.scratch.h != height)
            try state.scratch.resize(width, height);
        state.regions = .calculate(width, height, state.sidebar_requested);
        state.dirty = true;
    }

    pub fn workbench(state: *const State) ui.Rect {
        return state.regions.workbench;
    }

    pub fn toggleSidebar(state: *State) void {
        state.sidebar_requested = !state.sidebar_requested;
        state.regions = .calculate(
            state.scratch.w,
            state.scratch.h,
            state.sidebar_requested,
        );
        state.hovered = null;
        state.dirty = true;
    }

    pub fn invalidate(state: *State) void {
        state.dirty = true;
    }

    pub fn handleMouse(
        state: *State,
        model: *multiplexer.Model,
        mouse: term.Event.Mouse,
    ) Interaction {
        var result: Interaction = .{};
        const hovered = state.hits.at(mouse.x, mouse.y);
        if (!optionalActionEql(state.hovered, hovered)) {
            state.hovered = hovered;
            state.dirty = true;
            result.redraw = true;
        }
        if (mouse.kind != .press) return result;
        const action = hovered orelse return result;
        switch (action) {
            .toggle_sidebar => {
                state.toggleSidebar();
                result.redraw = true;
                result.layout_changed = true;
            },
            .focus_pane => |pane_id| {
                if (model.focusPane(pane_id)) {
                    state.dirty = true;
                    result.redraw = true;
                }
            },
            .select_tab => |tab| {
                if (state.active_tab != tab) {
                    state.active_tab = tab;
                    state.dirty = true;
                    result.redraw = true;
                }
            },
            .active_workspace, .active_worktree => {},
        }
        return result;
    }

    pub fn render(
        state: *State,
        screen: *term.Screen,
        model: *multiplexer.Model,
        force: bool,
    ) !RenderStats {
        if (!force and !state.dirty) return .{};
        state.hits.clear();
        state.scratch.clear(.{});
        drawTop(state, model);
        drawSidebar(state, model);
        drawBottom(state, model);
        registerWorkbench(state, model);

        var stats: RenderStats = .{};
        stats = addStats(stats, try syncRegion(screen, &state.scratch, state.regions.top));
        stats = addStats(stats, try syncRegion(screen, &state.scratch, state.regions.sidebar));
        stats = addStats(stats, try syncRegion(screen, &state.scratch, state.regions.bottom));
        state.dirty = false;
        return stats;
    }
};

fn drawTop(state: *State, model: *const multiplexer.Model) void {
    const area = state.regions.top;
    if (area.isEmpty()) return;
    const bar_style: ui.Style = .{ .flags = .{ .inverse = true } };
    state.scratch.fill(area, " ", bar_style);

    const toggle: ui.Rect = .{ .x = area.x, .y = area.y, .w = @min(area.w, 4), .h = 1 };
    state.hits.add(toggle, .toggle_sidebar);
    const toggle_style: ui.Style = if (isHovered(state, .toggle_sidebar))
        .{ .flags = .{ .bold = true, .inverse = true, .underline = .single } }
    else
        bar_style;
    _ = state.scratch.writeText(toggle, toggle.x, toggle.y, if (state.regions.sidebar.w == 0) "[>]" else "[<]", toggle_style);

    var workspace_buffer: [48]u8 = undefined;
    var worktree_buffer: [48]u8 = undefined;
    const workspace, const worktree = locationLabels(
        model.location,
        &workspace_buffer,
        &worktree_buffer,
    );
    var x: u16 = toggle.x + toggle.w + 1;
    const workspace_width = @min(ui.measure(workspace) + 2, area.w -| x);
    const workspace_rect: ui.Rect = .{ .x = x, .y = area.y, .w = workspace_width, .h = 1 };
    state.hits.add(workspace_rect, .active_workspace);
    _ = state.scratch.writeTruncated(workspace_rect, x, area.y, workspace, workspace_width, hoveredBarStyle(state, .active_workspace));
    x += workspace_width + @intFromBool(workspace_width != 0);

    const worktree_width = area.w -| x;
    const worktree_rect: ui.Rect = .{ .x = x, .y = area.y, .w = worktree_width, .h = 1 };
    state.hits.add(worktree_rect, .active_worktree);
    _ = state.scratch.writeTruncated(worktree_rect, x, area.y, worktree, worktree_width, hoveredBarStyle(state, .active_worktree));
}

fn drawSidebar(state: *State, model: *const multiplexer.Model) void {
    const area = state.regions.sidebar;
    if (area.isEmpty()) return;
    const faint: ui.Style = .{ .flags = .{ .faint = true } };
    const heading: ui.Style = .{ .flags = .{ .bold = true } };
    state.scratch.fill(area, " ", .{});

    _ = state.scratch.writeText(area, area.x + 1, area.y, "TELAR", heading);
    if (area.w > 1) {
        const edge_x = area.x + area.w - 1;
        var y = area.y;
        while (y < area.y + area.h) : (y += 1)
            state.scratch.setCell(edge_x, y, "│", 1, faint);
    }
    if (area.h <= 2) return;
    _ = state.scratch.writeText(area, area.x + 1, area.y + 2, "PANES", faint);

    var row: u16 = area.y + 3;
    for (&model.panes) |*slot| {
        const pane = if (slot.*) |*value| value else continue;
        if (row >= area.y + area.h) break;
        const row_area: ui.Rect = .{
            .x = area.x,
            .y = row,
            .w = area.w -| 1,
            .h = 1,
        };
        const action: Action = .{ .focus_pane = pane.id };
        state.hits.add(row_area, action);
        const focused = model.layout.focused() == pane.id;
        const style: ui.Style = if (focused)
            .{ .flags = .{ .bold = true, .inverse = true } }
        else if (isHovered(state, action))
            .{ .flags = .{ .underline = .single } }
        else
            .{};
        if (focused or isHovered(state, action)) state.scratch.fill(row_area, " ", style);
        var label_buffer: [48]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buffer, "  pane {d}", .{schema.id.raw(pane.id)}) catch "  pane";
        _ = state.scratch.writeTruncated(row_area, row_area.x, row, label, row_area.w, style);
        row += 1;
    }
}

fn drawBottom(state: *State, model: *const multiplexer.Model) void {
    const area = state.regions.bottom;
    if (area.isEmpty()) return;
    const bar_style: ui.Style = .{ .flags = .{ .inverse = true } };
    state.scratch.fill(area, " ", bar_style);

    // One layout tab exists today. Keeping it distinct from panes matters:
    // tabs will own pane layouts, so treating every pane as a tab now would
    // bake the wrong relationship into mouse actions and persisted UI state.
    const tab_label = " 1:main ";
    const tab_width = @min(ui.measure(tab_label), state.regions.tabs.w);
    const tab: ui.Rect = .{
        .x = state.regions.tabs.x,
        .y = area.y,
        .w = tab_width,
        .h = 1,
    };
    const tab_action: Action = .{ .select_tab = 0 };
    state.hits.add(tab, tab_action);
    const tab_style: ui.Style = if (state.active_tab == 0 or isHovered(state, tab_action))
        .{ .flags = .{ .bold = true, .inverse = true, .underline = .single } }
    else
        bar_style;
    _ = state.scratch.writeTruncated(tab, tab.x, tab.y, tab_label, tab.w, tab_style);

    var status_buffer: [48]u8 = undefined;
    const status = std.fmt.bufPrint(&status_buffer, "{d} pane{s}  local", .{
        model.pane_count,
        if (model.pane_count == 1) "" else "s",
    }) catch "local";
    _ = state.scratch.writeRight(state.regions.status, area.y, status, bar_style);
}

fn registerWorkbench(state: *State, model: *const multiplexer.Model) void {
    var views: [multiplexer.max_panes]@import("layout.zig").View = undefined;
    for (model.layout.views(state.regions.workbench, &views)) |view|
        state.hits.add(view.outer, .{ .focus_pane = view.pane_id });
}

fn locationLabels(
    location: ?schema.PaneLocation,
    workspace_buffer: []u8,
    worktree_buffer: []u8,
) struct { []const u8, []const u8 } {
    const value = location orelse return .{ " workspace - ", " worktree - " };
    return switch (value) {
        .workspace => |workspace| .{
            std.fmt.bufPrint(workspace_buffer, " workspace {d} ", .{schema.id.raw(workspace)}) catch " workspace ",
            " worktree - ",
        },
        .worktree => |worktree| .{
            " workspace - ",
            std.fmt.bufPrint(worktree_buffer, " worktree {d} ", .{schema.id.raw(worktree)}) catch " worktree ",
        },
    };
}

fn hoveredBarStyle(state: *const State, action: Action) ui.Style {
    return if (isHovered(state, action))
        .{ .flags = .{ .bold = true, .inverse = true, .underline = .single } }
    else
        .{ .flags = .{ .inverse = true } };
}

fn isHovered(state: *const State, action: Action) bool {
    const hovered = state.hovered orelse return false;
    return std.meta.eql(hovered, action);
}

fn optionalActionEql(a: ?Action, b: ?Action) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.meta.eql(a.?, b.?);
}

fn addStats(a: RenderStats, b: RenderStats) RenderStats {
    return .{ .scanned = a.scanned + b.scanned, .damaged = a.damaged + b.damaged };
}

fn syncRegion(screen: *term.Screen, source: *const ui.Buffer, area: ui.Rect) !RenderStats {
    var stats: RenderStats = .{};
    var y = area.y;
    while (y < area.y + area.h) : (y += 1) {
        const row_start = @as(usize, y) * source.w;
        var x = area.x;
        while (x < area.x + area.w) {
            stats.scanned += 1;
            const index = row_start + x;
            if (source.cells[index].eqlPublic(&screen.back.cells[index])) {
                x += 1;
                continue;
            }
            const run_start = x;
            x += 1;
            while (x < area.x + area.w) : (x += 1) {
                stats.scanned += 1;
                const next = row_start + x;
                if (source.cells[next].eqlPublic(&screen.back.cells[next])) break;
            }
            const count: u16 = x - run_start;
            const destination = try screen.patchCells(@intCast(row_start + run_start), count);
            @memcpy(destination, source.cells[row_start + run_start ..][0..count]);
            stats.damaged += count;
        }
    }
    return stats;
}

test "visible regions reserve top bottom sidebar and workbench" {
    const regions = Regions.calculate(120, 40, true);
    try std.testing.expectEqual(ui.Rect{ .w = 120, .h = 1 }, regions.top);
    try std.testing.expectEqual(ui.Rect{ .x = 0, .y = 1, .w = 30, .h = 38 }, regions.sidebar);
    try std.testing.expectEqual(ui.Rect{ .x = 30, .y = 1, .w = 90, .h = 38 }, regions.workbench);
    try std.testing.expectEqual(ui.Rect{ .x = 0, .y = 39, .w = 120, .h = 1 }, regions.bottom);
}

test "narrow clients hide the sidebar without forgetting user intent" {
    const regions = Regions.calculate(31, 20, true);
    try std.testing.expect(regions.sidebar.isEmpty());
    try std.testing.expectEqual(@as(u16, 31), regions.workbench.w);
}

test "sidebar toggle changes only the disposable client layout" {
    const gpa = std.testing.allocator;
    var state = try State.init(gpa, 100, 30);
    defer state.deinit();
    try std.testing.expectEqual(@as(u16, sidebar_width), state.regions.sidebar.w);
    state.toggleSidebar();
    try std.testing.expectEqual(@as(u16, 0), state.regions.sidebar.w);
    try std.testing.expectEqual(@as(u16, 100), state.regions.workbench.w);
}

test "sidebar rows focus panes and stable hover requests no extra frame" {
    const gpa = std.testing.allocator;
    var state = try State.init(gpa, 100, 30);
    defer state.deinit();
    var model = multiplexer.Model.init(gpa);
    defer model.deinit();
    const location: schema.PaneLocation = .{ .workspace = @enumFromInt(1) };
    try model.addRoot(@enumFromInt(1), location, .{ .cols = 34, .rows = 27 });
    try model.split(
        @enumFromInt(1),
        @enumFromInt(2),
        location,
        .horizontal,
        state.workbench(),
    );
    var screen = try term.Screen.init(gpa, 100, 30);
    defer screen.deinit();
    _ = try model.render(&screen, state.workbench());
    _ = try state.render(&screen, &model, true);

    const first_row = term.Event.Mouse{ .x = 2, .y = 4, .kind = .move };
    try std.testing.expect(state.handleMouse(&model, first_row).redraw);
    try std.testing.expect(!state.handleMouse(&model, first_row).redraw);
    const click = term.Event.Mouse{ .x = 2, .y = 4, .kind = .press };
    _ = state.handleMouse(&model, click);
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(1)), model.layout.focused().?);
}

test "client bars preserve the terminal palette" {
    const gpa = std.testing.allocator;
    var state = try State.init(gpa, 80, 24);
    defer state.deinit();
    var model = multiplexer.Model.init(gpa);
    defer model.deinit();
    const location: schema.PaneLocation = .{ .workspace = @enumFromInt(1) };
    try model.addRoot(@enumFromInt(1), location, .{ .cols = 50, .rows = 22 });
    var screen = try term.Screen.init(gpa, 80, 24);
    defer screen.deinit();
    _ = try model.render(&screen, state.workbench());
    _ = try state.render(&screen, &model, true);

    try std.testing.expect(screen.back.cells[0].style.bg == .default);
    try std.testing.expect(screen.back.cells[0].style.fg == .default);
    try std.testing.expect(screen.back.cells[0].style.flags.inverse);
}
