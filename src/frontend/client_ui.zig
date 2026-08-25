//! Visible structure and interaction state of one telar client.

const std = @import("std");
const core = @import("telar-core");
const diff = @import("diff.zig");
const kitty = @import("kitty.zig");
const multiplexer = @import("multiplexer.zig");
const tabs_mod = @import("tabs.zig");
const term = @import("term.zig");
const theme_mod = @import("theme.zig");
const ui = @import("ui.zig");
const widgets = @import("widgets/root.zig");

const schema = core.schema;

pub const sidebar_width = widgets.layout.sidebar_width;
pub const minimum_sidebar_width = widgets.layout.minimum_sidebar_width;
pub const minimum_workbench_width = widgets.layout.minimum_workbench_width;
pub const Regions = widgets.layout.Regions;
pub const Action = widgets.Action;

const Hits = widgets.Hits;

pub const Interaction = struct {
    redraw: bool = false,
    layout_changed: bool = false,
    select_tab: ?schema.TabId = null,
    sidebar_intent: ?SidebarIntent = null,
};

pub const SidebarIntent = union(enum) {
    new_task,
    command_palette,
    run_task_action: widgets.sidebar.TaskKey,
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
    field: widgets.tab_rename.Field,
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
    sidebar_snapshot: widgets.sidebar.Snapshot = .{},
    sidebar: widgets.sidebar.State = .{},
    dirty: bool = true,
    sidebar_rendering: kitty.ResolvedSidebarRendering = .cells,
    proxy_tls_active: bool = false,
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
        if (state.regions.sidebar.isEmpty()) state.sidebar.search_active = false;
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
        state.sidebar.search_active = false;
        state.hovered = null;
        state.dirty = true;
    }

    pub fn setSidebarVisible(state: *State, visible: bool) void {
        if (state.sidebar_requested == visible) return;
        state.toggleSidebar();
    }

    pub fn invalidate(state: *State) void {
        state.dirty = true;
    }

    pub fn setProxyTlsActive(state: *State, active: bool) void {
        if (state.proxy_tls_active == active) return;
        state.proxy_tls_active = active;
        state.dirty = true;
    }

    pub fn replaceSidebarSnapshot(
        state: *State,
        input: widgets.sidebar.SnapshotInput,
    ) !bool {
        if (!try state.sidebar_snapshot.replace(input)) return false;
        if (state.sidebar.selected_task) |key| {
            if (state.sidebar_snapshot.find(key) == null) state.sidebar.selected_task = null;
        }
        if (state.sidebar.selected_task == null) {
            if (state.sidebar_snapshot.firstInTab(state.sidebar.selected_tab)) |task|
                state.sidebar.selected_task = task.key;
        }
        state.sidebar.scroll = 0;
        state.dirty = true;
        return true;
    }

    pub fn sidebarCapturesKeyboard(state: *const State) bool {
        return state.sidebar.capturesKeyboard();
    }

    pub fn handleSidebarKey(state: *State, key: term.Event.Key) bool {
        if (!state.sidebar.handleKey(key)) return false;
        state.dirty = true;
        return true;
    }

    pub fn pasteIntoSidebar(state: *State, bytes: []const u8) bool {
        if (!state.sidebar.paste(bytes)) return false;
        state.dirty = true;
        return true;
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
        state.sidebar.search_active = false;
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
        if (state.regions.sidebar.contains(mouse.x, mouse.y)) switch (mouse.kind) {
            .scroll_up => if (state.sidebar.scrollBy(-3, state.sidebarListHeight())) {
                state.dirty = true;
                result.redraw = true;
            },
            .scroll_down => if (state.sidebar.scrollBy(3, state.sidebarListHeight())) {
                state.dirty = true;
                result.redraw = true;
            },
            else => {},
        };
        if (mouse.kind != .press) return result;
        const action = hovered orelse return result;
        if (std.meta.activeTag(action) != .sidebar_focus_search and state.sidebar.search_active) {
            state.sidebar.search_active = false;
            state.dirty = true;
            result.redraw = true;
        }
        switch (action) {
            .toggle_sidebar => {
                state.toggleSidebar();
                result.redraw = true;
                result.layout_changed = true;
            },
            .focus_pane => |pane_id| {
                const previous = model.layout.focused();
                if (model.focusPane(pane_id)) {
                    result.layout_changed = model.layout.isFullscreen() and
                        previous != model.layout.focused();
                    state.dirty = true;
                    result.redraw = true;
                }
            },
            .select_tab => |tab_id| if (tabs != null and tabs.?.indexOf(tab_id) != null) {
                switch (mouse.button & 0b11) {
                    0 => result.select_tab = tab_id,
                    2 => {
                        const tab = tabs.?.find(tab_id).?;
                        state.beginTabRename(tab_id, tab.labelSlice());
                        result.redraw = true;
                    },
                    else => {},
                }
            },
            .active_workspace, .active_worktree => {},
            .sidebar_focus_search => {
                state.sidebar.search_active = true;
                state.dirty = true;
                result.redraw = true;
            },
            .sidebar_new_task => result.sidebar_intent = .new_task,
            .sidebar_command_palette => result.sidebar_intent = .command_palette,
            .sidebar_select_tab => |tab| {
                state.sidebar.selected_tab = tab;
                state.sidebar.selected_task = if (state.sidebar_snapshot.firstInTab(tab)) |task|
                    task.key
                else
                    null;
                state.sidebar.scroll = 0;
                state.dirty = true;
                result.redraw = true;
            },
            .sidebar_toggle_scope => {
                state.sidebar.scope_open = !state.sidebar.scope_open;
                state.dirty = true;
                result.redraw = true;
            },
            .sidebar_select_task => |key| {
                state.sidebar.selected_task = key;
                if (state.sidebar_snapshot.find(key)) |task| {
                    if (task.pane_id) |pane_id| {
                        const previous = model.layout.focused();
                        _ = model.focusPane(pane_id);
                        result.layout_changed = model.layout.isFullscreen() and
                            previous != model.layout.focused();
                    }
                }
                state.dirty = true;
                result.redraw = true;
            },
            .sidebar_run_task_action => |key| {
                state.sidebar.selected_task = key;
                result.sidebar_intent = .{ .run_task_action = key };
                state.dirty = true;
                result.redraw = true;
            },
            .sidebar_scroll_to => |row| {
                state.sidebar.scroll = row;
                state.dirty = true;
                result.redraw = true;
            },
        }
        return result;
    }

    fn sidebarListHeight(state: *const State) u16 {
        return state.regions.sidebar.h -| 11;
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
        const hybrid = state.sidebar_rendering == .kitty_hybrid or
            state.sidebar_rendering == .kitty_full;
        var context: widgets.Context = .{
            .buffer = &state.scratch,
            .hits = &state.hits,
            .palette = state.palette(),
            .hovered = state.hovered,
        };
        const composed = widgets.composition.render(&context, .{
            .regions = state.regions,
            .tabs = tabs,
            .model = model,
            .rename_field = if (state.tab_rename) |*rename| &rename.field else null,
            .sidebar_snapshot = &state.sidebar_snapshot,
            .sidebar_state = &state.sidebar,
            .sidebar_transparent = hybrid,
            .proxy_tls_active = state.proxy_tls_active,
        });
        if (hybrid) {
            var provider_marks: [widgets.sidebar.max_provider_marks]kitty.SidebarProviderPlacement = undefined;
            var provider_mark_count: usize = 0;
            for (composed.sidebar.provider_marks[0..composed.sidebar.provider_mark_count]) |mark| {
                const provider: kitty.SidebarProvider = switch (mark.provider) {
                    .claude => .claude,
                    else => continue,
                };
                provider_marks[provider_mark_count] = .{ .area = mark.area, .provider = provider };
                provider_mark_count += 1;
            }
            var controls: [widgets.sidebar.max_controls]kitty.SidebarControlPlacement = undefined;
            for (composed.sidebar.controls[0..composed.sidebar.control_count], 0..) |control, index| {
                controls[index] = .{
                    .area = control.area,
                    .kind = switch (control.kind) {
                        .neutral => .neutral,
                        .primary => .primary,
                    },
                };
            }
            try state.kitty_sidebar.prepare(
                composed.sidebar.area,
                state.palette(),
                composed.sidebar.selected_card,
                provider_marks[0..provider_mark_count],
                controls[0..composed.sidebar.control_count],
                state.cell_width_px,
                state.cell_height_px,
            );
        } else try state.kitty_sidebar.prepare(.{}, state.palette(), null, &.{}, &.{}, 0, 0);

        var stats: RenderStats = .{};
        stats = addStats(stats, try syncRegion(screen, &state.scratch, state.regions.top));
        stats = addStats(stats, try syncRegion(screen, &state.scratch, state.regions.sidebar));
        stats = addStats(stats, try syncRegion(screen, &state.scratch, state.regions.bottom));
        if (composed.cursor) |cursor| {
            screen.cursor = .{
                .x = cursor.cursor_x,
                .y = cursor.cursor_y,
            };
        }
        state.dirty = false;
        return stats;
    }
};

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
    try std.testing.expectEqual(ui.Rect{ .x = 0, .y = 1, .w = 62, .h = 38 }, regions.sidebar);
    try std.testing.expectEqual(ui.Rect{ .x = 62, .y = 1, .w = 58, .h = 38 }, regions.workbench);
    try std.testing.expectEqual(ui.Rect{ .x = 0, .y = 39, .w = 120, .h = 1 }, regions.bottom);
}

test "narrow clients hide the sidebar without forgetting user intent" {
    const regions = Regions.calculate(61, 20, true);
    try std.testing.expect(regions.sidebar.isEmpty());
    try std.testing.expectEqual(@as(u16, 61), regions.workbench.w);
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

test "hiding or suppressing the sidebar releases its search editor" {
    var state = try State.init(std.testing.allocator, 100, 30);
    defer state.deinit();
    state.sidebar.search_active = true;
    state.toggleSidebar();
    try std.testing.expect(!state.sidebarCapturesKeyboard());

    state.toggleSidebar();
    state.sidebar.search_active = true;
    try state.resize(61, 30);
    try std.testing.expect(state.regions.sidebar.isEmpty());
    try std.testing.expect(!state.sidebarCapturesKeyboard());
}

test "empty production sidebar exposes search and deferred creation intent" {
    var state = try State.init(std.testing.allocator, 100, 30);
    defer state.deinit();
    var model = multiplexer.Model.init(std.testing.allocator);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(@enumFromInt(1), location, .{ .cols = 38, .rows = 27 });
    var screen = try term.Screen.init(std.testing.allocator, 100, 30);
    defer screen.deinit();
    _ = try state.render(&screen, null, &model, true);

    const search = state.handleMouse(null, &model, .{ .x = 3, .y = 2, .kind = .press });
    try std.testing.expect(search.redraw);
    try std.testing.expect(state.sidebarCapturesKeyboard());
    try std.testing.expect(state.handleSidebarKey(.{ .code = .{ .char = .init("a") } }));
    try std.testing.expectEqualStrings("a", state.sidebar.search.text());

    const create = state.handleMouse(null, &model, .{ .x = 58, .y = 2, .kind = .press });
    try std.testing.expectEqualDeep(SidebarIntent.new_task, create.sidebar_intent.?);
    try std.testing.expect(!state.sidebarCapturesKeyboard());
}

test "sidebar task snapshots focus linked panes and stable hover requests no extra frame" {
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
    try std.testing.expect(model.toggleFullscreen());
    const tasks = [_]widgets.sidebar.TaskInput{.{
        .key = .{ .id = 10, .generation = 1 },
        .pane_id = @enumFromInt(1),
        .title = "Fix auth token refresh",
        .section = .needs_you,
    }};
    try std.testing.expect(try state.replaceSidebarSnapshot(.{ .revision = 1, .tasks = &tasks }));
    var screen = try term.Screen.init(gpa, 100, 30);
    defer screen.deinit();
    _ = try model.render(&screen, state.workbench());
    _ = try state.render(&screen, null, &model, true);

    const first_row = term.Event.Mouse{ .x = 4, .y = 11, .kind = .move };
    try std.testing.expect(state.handleMouse(null, &model, first_row).redraw);
    try std.testing.expect(!state.handleMouse(null, &model, first_row).redraw);
    const click = term.Event.Mouse{ .x = 4, .y = 11, .kind = .press };
    const interaction = state.handleMouse(null, &model, click);
    try std.testing.expect(interaction.layout_changed);
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(1)), model.layout.focused().?);
}

test "hybrid sidebar preserves task hit testing and cell fallback actions" {
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
    const tasks = [_]widgets.sidebar.TaskInput{.{
        .key = .{ .id = 12, .generation = 4 },
        .pane_id = @enumFromInt(1),
        .title = "Review booking copy",
        .tool = "claude/sonnet",
        .section = .ready,
        .provider = .claude,
        .action = .review,
    }};
    _ = try state.replaceSidebarSnapshot(.{ .revision = 1, .tasks = &tasks });
    state.sidebar.selected_task = tasks[0].key;
    var screen = try term.Screen.init(std.testing.allocator, 100, 30);
    defer screen.deinit();
    _ = try state.render(&screen, null, &model, true);
    try std.testing.expectEqualDeep(
        Action{ .sidebar_select_task = tasks[0].key },
        state.hits.at(4, 11).?,
    );
    const interaction = state.handleMouse(null, &model, .{ .x = 4, .y = 11, .kind = .press });
    try std.testing.expect(interaction.redraw);
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(1)), model.layout.focused().?);
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

    const rename = state.handleMouse(&tabs, model, .{
        .x = 1,
        .y = 23,
        .kind = .press,
        .button = 2,
    });
    try std.testing.expect(rename.redraw);
    try std.testing.expect(rename.select_tab == null);
    try std.testing.expectEqual(@as(schema.TabId, @enumFromInt(4)), state.renamedTab().?);
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
