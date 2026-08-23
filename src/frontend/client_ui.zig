//! Visible structure and interaction state of one telar client.

const std = @import("std");
const core = @import("telar-core");
const diff = @import("diff.zig");
const edit = @import("edit.zig");
const kitty = @import("kitty.zig");
const multiplexer = @import("multiplexer.zig");
const tabs_mod = @import("tabs.zig");
const term = @import("term.zig");
const theme_mod = @import("theme.zig");
const ui = @import("ui.zig");

const schema = core.schema;

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
    select_tab: schema.TabId,
    active_workspace,
    active_worktree,
};

const Hits = ui.Hits(Action, 128);

const SidebarSemantic = struct {
    area: ui.Rect,
    rows: [multiplexer.max_panes]Row = undefined,
    row_count: usize = 0,
    focused_row: ?u16 = null,

    const Row = struct {
        area: ui.Rect,
        pane_id: schema.PaneId,
        focused: bool,
        hovered: bool,
    };
};

const CellSidebarRenderer = struct {
    fn render(state: *State, semantic: *const SidebarSemantic, transparent: bool) void {
        const area = semantic.area;
        if (area.isEmpty()) return;
        const palette = state.palette();
        const background: ui.Color = if (transparent) .default else palette.panel_bg;
        const faint: ui.Style = .{ .fg = palette.overlay0, .bg = background };
        const heading: ui.Style = .{
            .fg = palette.accent,
            .bg = background,
            .flags = .{ .bold = true },
        };
        state.scratch.fill(area, " ", .{ .fg = palette.text, .bg = background });
        _ = state.scratch.writeText(area, area.x + 1, area.y, "TELAR", heading);
        if (!transparent and area.w > 1) {
            const edge_x = area.x + area.w - 1;
            var y = area.y;
            while (y < area.y + area.h) : (y += 1)
                state.scratch.setCell(edge_x, y, "│", 1, faint);
        }
        if (area.h <= 2) return;
        _ = state.scratch.writeText(area, area.x + 1, area.y + 2, "PANES", faint);
        for (semantic.rows[0..semantic.row_count]) |row| {
            const style: ui.Style = if (row.focused)
                .{ .fg = palette.text, .bg = if (transparent) .default else palette.surface0, .flags = .{ .bold = true } }
            else if (row.hovered)
                .{ .fg = palette.text, .bg = if (transparent) .default else palette.surface1, .flags = .{ .underline = .single } }
            else
                .{ .fg = palette.subtext0, .bg = background };
            state.scratch.fill(row.area, " ", style);
            var label_buffer: [48]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buffer, "  pane {d}", .{schema.id.raw(row.pane_id)}) catch "  pane";
            _ = state.scratch.writeTruncated(row.area, row.area.x, row.area.y, label, row.area.w, style);
        }
    }
};

pub const Interaction = struct {
    redraw: bool = false,
    layout_changed: bool = false,
    select_tab: ?schema.TabId = null,
};

pub const RenderStats = struct {
    scanned: usize = 0,
    damaged: usize = 0,
};

pub const RenameInput = union(enum) {
    editing,
    cancelled,
    submitted: []const u8,
};

const TabRename = struct {
    tab_id: schema.TabId,
    field: edit.Field(schema.max_tab_label_bytes),
    pasting: bool = false,
};

pub const State = struct {
    scratch: ui.Buffer,
    regions: Regions,
    theme: theme_mod.Theme,
    hits: Hits = .{},
    sidebar_requested: bool = true,
    hovered: ?Action = null,
    tab_rename: ?TabRename = null,
    dirty: bool = true,
    sidebar_rendering: kitty.ResolvedSidebarRendering = .cells,
    kitty_sidebar: kitty.KittySidebarRenderer,
    cell_width_px: u16 = 0,
    cell_height_px: u16 = 0,

    pub fn init(gpa: std.mem.Allocator, width: u16, height: u16) !State {
        return initWithTheme(gpa, width, height, theme_mod.default_theme);
    }

    pub fn initWithTheme(
        gpa: std.mem.Allocator,
        width: u16,
        height: u16,
        selected_theme: theme_mod.Theme,
    ) !State {
        return .{
            .scratch = try .init(gpa, width, height),
            .regions = .calculate(width, height, true),
            .theme = selected_theme,
            .kitty_sidebar = .init(gpa),
        };
    }

    pub fn deinit(state: *State) void {
        state.scratch.deinit();
        state.kitty_sidebar.deinit();
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

    pub fn palette(state: *const State) *const theme_mod.Palette {
        return &state.theme.palette;
    }

    pub fn setTheme(state: *State, selected_theme: theme_mod.Theme) void {
        state.theme = selected_theme;
        state.hovered = null;
        state.dirty = true;
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

    pub fn configureSidebar(
        state: *State,
        requested: kitty.SidebarRendering,
        support: kitty.Support,
        cell_width: u16,
        cell_height: u16,
    ) !void {
        const resolved = try requested.resolve(support);
        if (state.sidebar_rendering != resolved or state.cell_width_px != cell_width or
            state.cell_height_px != cell_height)
        {
            state.sidebar_rendering = resolved;
            state.cell_width_px = cell_width;
            state.cell_height_px = cell_height;
            state.dirty = true;
        }
    }

    pub fn kittySidebar(state: *State) *kitty.KittySidebarRenderer {
        return &state.kitty_sidebar;
    }

    pub fn beginTabRename(state: *State, tab_id: schema.TabId, label: []const u8) void {
        state.tab_rename = .{ .tab_id = tab_id, .field = .init(label) };
        state.hovered = null;
        state.dirty = true;
    }

    pub fn renamedTab(state: *const State) ?schema.TabId {
        return if (state.tab_rename) |rename| rename.tab_id else null;
    }

    pub fn handleRenameInput(state: *State, bytes: []const u8) RenameInput {
        const rename = if (state.tab_rename) |*value| value else return .editing;
        var offset: usize = 0;
        while (offset < bytes.len) {
            const parsed = term.parse(bytes[offset..]) orelse {
                if (rename.pasting) rename.field.insert(bytes[offset..]);
                break;
            };
            // A zero-length incomplete can never complete inside this chunk:
            // the router only hands over raw pending bytes after its own
            // timeout, so the tail is stale terminal noise. Dropping it is the
            // only move that guarantees the offset advances.
            if (parsed.len == 0) break;
            offset += parsed.len;
            switch (parsed.event) {
                .paste_start => rename.pasting = true,
                .paste_end => rename.pasting = false,
                .key => |key| switch (key.code) {
                    .enter => {
                        if (rename.pasting) {
                            rename.field.insert(" ");
                            continue;
                        }
                        if (rename.field.text().len == 0) return .editing;
                        state.dirty = true;
                        return .{ .submitted = rename.field.text() };
                    },
                    .escape => {
                        state.tab_rename = null;
                        state.dirty = true;
                        return .cancelled;
                    },
                    .backspace => rename.field.backspace(),
                    .delete => rename.field.delete(),
                    .left => rename.field.moveLeft(key.mods.shift),
                    .right => rename.field.moveRight(key.mods.shift),
                    .home => rename.field.home(key.mods.shift),
                    .end => rename.field.end(key.mods.shift),
                    .char => |char| if (!key.mods.ctrl and !key.mods.alt)
                        rename.field.insert(char.slice()),
                    else => {},
                },
                .mouse, .terminal_response, .incomplete => {},
            }
        }
        state.dirty = true;
        return .editing;
    }

    pub fn finishTabRename(state: *State) void {
        state.tab_rename = null;
        state.dirty = true;
    }

    pub fn handleMouse(
        state: *State,
        tabs: ?*tabs_mod.Model,
        model: *multiplexer.Model,
        mouse: term.Event.Mouse,
    ) Interaction {
        var result: Interaction = .{};
        if (state.tab_rename != null) return result;
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
            .select_tab => |tab_id| if (tabs != null and tabs.?.indexOf(tab_id) != null) {
                result.select_tab = tab_id;
            },
            .active_workspace, .active_worktree => {},
        }
        return result;
    }

    pub fn render(
        state: *State,
        screen: *term.Screen,
        tabs: ?*const tabs_mod.Model,
        model: *multiplexer.Model,
        force: bool,
    ) !RenderStats {
        if (!force and !state.dirty) return .{};
        state.hits.clear();
        state.scratch.clear(.{});
        drawTop(state, model);
        const sidebar = buildSidebarSemantic(state, model);
        const hybrid = state.sidebar_rendering == .kitty_hybrid or
            state.sidebar_rendering == .kitty_full;
        CellSidebarRenderer.render(state, &sidebar, hybrid);
        if (hybrid) try state.kitty_sidebar.prepare(
            sidebar.area,
            state.palette(),
            sidebar.focused_row,
            state.cell_width_px,
            state.cell_height_px,
        ) else try state.kitty_sidebar.prepare(.{}, state.palette(), null, 0, 0);
        drawBottom(state, tabs, model);
        registerWorkbench(state, model);

        var stats: RenderStats = .{};
        stats = addStats(stats, try syncRegion(screen, &state.scratch, state.regions.top));
        stats = addStats(stats, try syncRegion(screen, &state.scratch, state.regions.sidebar));
        stats = addStats(stats, try syncRegion(screen, &state.scratch, state.regions.bottom));
        if (state.tab_rename) |*rename| {
            const prefix = " rename tab: ";
            const available = state.regions.bottom.w -| ui.measure(prefix) -| 1;
            const field_view = rename.field.view(available);
            screen.cursor = .{
                .x = state.regions.bottom.x + ui.measure(prefix) + field_view.cursor,
                .y = state.regions.bottom.y,
            };
        }
        state.dirty = false;
        return stats;
    }
};

fn drawTop(state: *State, model: *const multiplexer.Model) void {
    const area = state.regions.top;
    if (area.isEmpty()) return;
    const palette = state.palette();
    const bar_style: ui.Style = .{ .fg = palette.text, .bg = palette.panel_bg };
    state.scratch.fill(area, " ", bar_style);

    const toggle: ui.Rect = .{ .x = area.x, .y = area.y, .w = @min(area.w, 4), .h = 1 };
    state.hits.add(toggle, .toggle_sidebar);
    const toggle_style: ui.Style = if (isHovered(state, .toggle_sidebar))
        .{
            .fg = palette.accent,
            .bg = palette.surface1,
            .flags = .{ .bold = true, .underline = .single },
        }
    else
        .{ .fg = palette.accent, .bg = palette.panel_bg, .flags = .{ .bold = true } };
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

fn buildSidebarSemantic(state: *State, model: *const multiplexer.Model) SidebarSemantic {
    const area = state.regions.sidebar;
    var semantic: SidebarSemantic = .{ .area = area };
    if (area.isEmpty() or area.h <= 2) return semantic;

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
        semantic.rows[semantic.row_count] = .{
            .area = row_area,
            .pane_id = pane.id,
            .focused = focused,
            .hovered = isHovered(state, action),
        };
        semantic.row_count += 1;
        if (focused) semantic.focused_row = row;
        row += 1;
    }
    return semantic;
}

fn drawBottom(
    state: *State,
    tabs: ?*const tabs_mod.Model,
    model: *const multiplexer.Model,
) void {
    const area = state.regions.bottom;
    if (area.isEmpty()) return;
    const palette = state.palette();
    const bar_style: ui.Style = .{ .fg = palette.subtext0, .bg = palette.panel_bg };
    state.scratch.fill(area, " ", bar_style);

    if (state.tab_rename) |*rename| {
        const prefix = " rename tab: ";
        _ = state.scratch.writeText(area, area.x, area.y, prefix, .{
            .fg = palette.accent,
            .bg = palette.panel_bg,
            .flags = .{ .bold = true },
        });
        const field_x = area.x + ui.measure(prefix);
        const field_area: ui.Rect = .{
            .x = field_x,
            .y = area.y,
            .w = area.w -| (field_x - area.x),
            .h = 1,
        };
        const field_view = rename.field.view(field_area.w);
        _ = state.scratch.writeTruncated(
            field_area,
            field_x,
            area.y,
            field_view.text,
            field_area.w,
            .{
                .fg = palette.text,
                .bg = palette.surface0,
                .flags = .{ .bold = true },
            },
        );
        return;
    }

    var x = state.regions.tabs.x;
    if (tabs) |collection| {
        var first_visible = collection.active_index;
        var used = tabDisplayWidth(
            collection.items[first_visible].?.labelSlice(),
            first_visible,
            state.regions.tabs.w,
        );
        while (first_visible > 0) {
            const candidate = first_visible - 1;
            const width = tabDisplayWidth(
                collection.items[candidate].?.labelSlice(),
                candidate,
                state.regions.tabs.w,
            );
            if (width > state.regions.tabs.w -| used) break;
            first_visible = candidate;
            used += width;
        }
        for (collection.items[first_visible..collection.count], first_visible..) |slot, index| {
            const tab_value = slot.?;
            var tab_buffer: [schema.max_tab_label_bytes + 16]u8 = undefined;
            const tab_label = std.fmt.bufPrint(&tab_buffer, " {d}:{s} ", .{
                index + 1,
                tab_value.labelSlice(),
            }) catch " tab ";
            const remaining = state.regions.tabs.x + state.regions.tabs.w -| x;
            if (remaining == 0) break;
            const tab_width = @min(ui.measure(tab_label), remaining);
            const tab_rect: ui.Rect = .{ .x = x, .y = area.y, .w = tab_width, .h = 1 };
            const action: Action = .{ .select_tab = tab_value.location.tab_id };
            state.hits.add(tab_rect, action);
            const active = index == collection.active_index;
            const style: ui.Style = if (active)
                .{
                    .fg = palette.surface_dim,
                    .bg = palette.accent,
                    .flags = .{ .bold = true },
                }
            else if (isHovered(state, action))
                .{
                    .fg = palette.text,
                    .bg = palette.surface0,
                    .flags = .{ .underline = .single },
                }
            else
                bar_style;
            _ = state.scratch.writeTruncated(tab_rect, x, area.y, tab_label, tab_width, style);
            x += tab_width;
        }
    } else if (model.location) |location| {
        var tab_buffer: [32]u8 = undefined;
        const tab_label = std.fmt.bufPrint(&tab_buffer, " tab {d} ", .{
            schema.id.raw(location.tab_id),
        }) catch " tab ";
        const tab_width = @min(ui.measure(tab_label), state.regions.tabs.w);
        const tab_rect: ui.Rect = .{ .x = x, .y = area.y, .w = tab_width, .h = 1 };
        _ = state.scratch.writeTruncated(tab_rect, x, area.y, tab_label, tab_width, .{
            .fg = palette.surface_dim,
            .bg = palette.accent,
            .flags = .{ .bold = true },
        });
    }

    var status_buffer: [48]u8 = undefined;
    const status = std.fmt.bufPrint(&status_buffer, "{d} pane{s}  local", .{
        model.pane_count,
        if (model.pane_count == 1) "" else "s",
    }) catch "local";
    _ = state.scratch.writeRight(state.regions.status, area.y, status, bar_style);
}

fn decimalDigits(value: usize) u16 {
    var remaining = value;
    var digits: u16 = 1;
    while (remaining >= 10) : (digits += 1) remaining /= 10;
    return digits;
}

fn tabDisplayWidth(label: []const u8, index: usize, available: u16) u16 {
    return @min(ui.measure(label) + decimalDigits(index + 1) + 3, available);
}

fn registerWorkbench(state: *State, model: *const multiplexer.Model) void {
    var views: [multiplexer.max_panes]@import("layout.zig").View = undefined;
    for (model.layout.views(state.regions.workbench, &views)) |view|
        state.hits.add(view.outer, .{ .focus_pane = view.pane_id });
}

fn locationLabels(
    location: ?schema.TabLocation,
    workspace_buffer: []u8,
    worktree_buffer: []u8,
) struct { []const u8, []const u8 } {
    const value = location orelse return .{ " workspace - ", " worktree - " };
    return switch (value.workspace) {
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
    const palette = state.palette();
    return if (isHovered(state, action))
        .{
            .fg = palette.text,
            .bg = palette.surface0,
            .flags = .{ .bold = true, .underline = .single },
        }
    else
        .{ .fg = palette.subtext0, .bg = palette.panel_bg };
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
        const source_row = source.cells[row_start..][0..source.w];
        var sink: term.PatchSink = .{
            .screen = screen,
            .source_row = source_row,
            .base = row_start,
        };
        stats.damaged += try diff.syncRow(
            source_row,
            screen.back.cells[row_start..][0..source.w],
            area.x,
            area.x + area.w,
            &sink,
        );
        stats.scanned += area.w;
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
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
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
    _ = try state.render(&screen, null, &model, true);

    const first_row = term.Event.Mouse{ .x = 2, .y = 4, .kind = .move };
    try std.testing.expect(state.handleMouse(null, &model, first_row).redraw);
    try std.testing.expect(!state.handleMouse(null, &model, first_row).redraw);
    const click = term.Event.Mouse{ .x = 2, .y = 4, .kind = .press };
    _ = state.handleMouse(null, &model, click);
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(1)), model.layout.focused().?);
}

test "hybrid sidebar preserves semantic pane hit testing" {
    var state = try State.init(std.testing.allocator, 100, 30);
    defer state.deinit();
    try state.configureSidebar(.kitty_hybrid, .supported, 10, 20);
    var model = multiplexer.Model.init(std.testing.allocator);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(@enumFromInt(1), location, .{ .cols = 30, .rows = 20 });
    var screen = try term.Screen.init(std.testing.allocator, 100, 30);
    defer screen.deinit();
    _ = try state.render(&screen, null, &model, true);
    try std.testing.expectEqualDeep(Action{ .focus_pane = @enumFromInt(1) }, state.hits.at(2, 4).?);
    const interaction = state.handleMouse(null, &model, .{ .x = 2, .y = 4, .kind = .press });
    try std.testing.expect(interaction.redraw == false or model.layout.focused() == @as(schema.PaneId, @enumFromInt(1)));
    try std.testing.expect(state.kittySidebar().damaged());
}

test "client chrome uses Vesper by default" {
    const gpa = std.testing.allocator;
    var state = try State.init(gpa, 80, 24);
    defer state.deinit();
    var model = multiplexer.Model.init(gpa);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(@enumFromInt(1), location, .{ .cols = 50, .rows = 22 });
    var screen = try term.Screen.init(gpa, 80, 24);
    defer screen.deinit();
    _ = try model.render(&screen, state.workbench());
    _ = try state.render(&screen, null, &model, true);

    try std.testing.expectEqualDeep(state.palette().panel_bg, screen.back.cells[0].style.bg);
    try std.testing.expectEqualDeep(state.palette().accent, screen.back.cells[0].style.fg);
    try std.testing.expect(!screen.back.cells[0].style.flags.inverse);
    try std.testing.expectEqual(theme_mod.Builtin.vesper, state.theme.base);
}

test "terminal theme leaves client chrome backgrounds to the host terminal" {
    const gpa = std.testing.allocator;
    var state = try State.initWithTheme(gpa, 80, 24, theme_mod.builtin(.terminal));
    defer state.deinit();
    var model = multiplexer.Model.init(gpa);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(@enumFromInt(1), location, .{ .cols = 50, .rows = 22 });
    var screen = try term.Screen.init(gpa, 80, 24);
    defer screen.deinit();
    _ = try model.renderThemed(&screen, state.workbench(), state.palette());
    _ = try state.render(&screen, null, &model, true);

    try std.testing.expectEqualDeep(ui.Color.default, screen.back.cells[0].style.bg);
    try std.testing.expectEqualDeep(
        ui.Color.default,
        screen.back.cells[@as(usize, 23) * 80 + 79].style.bg,
    );
}

test "changing themes invalidates client chrome" {
    var state = try State.init(std.testing.allocator, 80, 24);
    defer state.deinit();
    state.dirty = false;
    state.hovered = .active_workspace;

    state.setTheme(theme_mod.builtin(.catppuccin));

    try std.testing.expect(state.dirty);
    try std.testing.expect(state.hovered == null);
    try std.testing.expectEqual(theme_mod.Builtin.catppuccin, state.theme.base);
}

test "tab bar renders ordered labels and clicks carry runtime ids" {
    const gpa = std.testing.allocator;
    var state = try State.init(gpa, 80, 24);
    defer state.deinit();
    var tabs = tabs_mod.Model.init(gpa);
    defer tabs.deinit();
    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    try tabs.bootstrap(@enumFromInt(1), .{
        .workspace = workspace,
        .tab_id = @enumFromInt(4),
    }, .{ .cols = 50, .rows = 22 });
    _ = try tabs.addCreated(.{
        .request_id = @enumFromInt(2),
        .location = .{ .workspace = workspace, .tab_id = @enumFromInt(9) },
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 50, .rows = 22 });
    var screen = try term.Screen.init(gpa, 80, 24);
    defer screen.deinit();
    const model = &tabs.active().?.model;
    _ = try model.render(&screen, state.workbench());
    _ = try state.render(&screen, &tabs, model, true);

    const click = term.Event.Mouse{ .x = 1, .y = 23, .kind = .press };
    const interaction = state.handleMouse(&tabs, model, click);
    try std.testing.expectEqual(@as(schema.TabId, @enumFromInt(4)), interaction.select_tab.?);
}

test "rename input consumes an unparseable tail instead of spinning" {
    // Regression: the keybind router forwards raw pending bytes after its
    // escape timeout ("\x1b[123" is its own tested behavior), and `term.parse`
    // reports those as incomplete with zero length. The rename loop never
    // advanced past a zero-length parse, so the client span forever.
    var state = try State.init(std.testing.allocator, 80, 24);
    defer state.deinit();
    state.beginTabRename(@enumFromInt(3), "logs");
    try std.testing.expect(state.handleRenameInput("\x1b[123") == .editing);
    // The field is untouched and editing continues normally afterwards.
    const submitted = state.handleRenameInput("!\r");
    try std.testing.expect(submitted == .submitted);
    try std.testing.expectEqualStrings("logs!", submitted.submitted);
}

test "tab rename edits clusters and submits a non-empty label" {
    var state = try State.init(std.testing.allocator, 80, 24);
    defer state.deinit();
    state.beginTabRename(@enumFromInt(3), "logs");
    try std.testing.expect(state.handleRenameInput("\x7f") == .editing);
    const submitted = state.handleRenameInput("í\r");
    try std.testing.expect(submitted == .submitted);
    try std.testing.expectEqualStrings("logí", submitted.submitted);
}
