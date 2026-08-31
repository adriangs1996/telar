//! Visible structure and interaction state of one telar client.

const std = @import("std");
const core = @import("telar-core");
const agents = @import("../agents/root.zig");
const attachments = @import("../attachments/root.zig");
const presentation = @import("../presentation/root.zig");
const workspace_capability = @import("../workspace/root.zig");
const client_model = @import("model.zig");
const name_prompt = @import("name_prompt.zig");
const diff = presentation.diff;
const icon_graphics = @import("../graphics/root.zig").icons;
const kitty = @import("../graphics/root.zig").kitty;
const modal_graphics = @import("../graphics/root.zig").modal;
const multiplexer = workspace_capability.multiplexer;
const tabs_mod = workspace_capability.tabs;
const workspace_list = workspace_capability.workspace_list;
const term = presentation.screen;
const theme_mod = @import("../ui/root.zig").theme;
const toast_graphics = @import("../graphics/root.zig").toast;
const ui = @import("../ui/root.zig");
const widgets = @import("../widgets/root.zig");

const schema = core.schema;
const empty_agent_snapshot: agents.Snapshot = .{};
const empty_workspace_list: workspace_list.Snapshot = .{};

pub const sidebar_width = widgets.layout.sidebar_width;
pub const minimum_sidebar_width = widgets.layout.minimum_sidebar_width;
pub const minimum_workbench_width = widgets.layout.minimum_workbench_width;
pub const Regions = widgets.layout.Regions;
pub const Action = widgets.Action;

const Hits = widgets.Hits;

pub const Interaction = struct {
    redraw: bool = false,
    layout_changed: bool = false,
    consumed: bool = false,
    toggle_sidebar: bool = false,
    toggle_workspace_list: bool = false,
    focus_pane: ?schema.PaneId = null,
    select_tab: ?schema.TabId = null,
    select_workspace: ?schema.WorkspaceId = null,
    focus_agent: ?agents.AgentKey = null,
    /// Intent only: the client model owns prompt creation; the view never
    /// enters the editor on its own.
    rename_tab: ?schema.TabId = null,
    notification_target: ?widgets.notification.Target = null,
};

pub const RenderStats = struct {
    scanned: usize = 0,
    damaged: usize = 0,
};

pub const RenderInput = struct {
    tabs: ?*const tabs_mod.Model = null,
    model: *multiplexer.Model,
    agents: *const agents.Snapshot = &empty_agent_snapshot,
    workspaces: *const workspace_list.Snapshot = &empty_workspace_list,
    prompt: ?*name_prompt.Prompt = null,
    proxy_tls_active: bool = false,
    system_metrics: ?client_model.SystemMetrics = null,
    status_mode: widgets.status_bar.Mode = .normal,
    force: bool = false,
    diagnostic: ?[]const u8 = null,
};

const GraphicsPlan = struct {
    toast_area: ui.Rect = .{},
    sidebar_area: ui.Rect = .{},
    focused_card: ?kitty.SidebarFocus = null,
    provider_marks: [widgets.sidebar.max_provider_marks]kitty.SidebarProviderPlacement = undefined,
    provider_mark_count: u8 = 0,
    icons: ui.icons.Plan = .{},
    attachments: attachments.Plan = .{},
    modal_area: ui.Rect = .{},
};

pub const State = struct {
    scratch: ui.Buffer,
    regions: Regions,
    theme: theme_mod.Theme,
    icon_theme: ui.icons.Theme,
    hits: Hits = .{},
    sidebar_requested: bool = true,
    hovered: ?Action = null,
    sidebar: widgets.sidebar.State = .{},
    sidebar_animation_frame: u8 = 0,
    workspace_list_collapsed: bool = false,
    dirty: bool = true,
    sidebar_rendering: kitty.ResolvedSidebarRendering = .cells,
    notifications: widgets.notification.Center = .{},
    toast_overlay_drawn: bool = false,
    kitty_sidebar: kitty.KittySidebarRenderer,
    kitty_icons: icon_graphics.Renderer,
    kitty_toasts: toast_graphics.Renderer,
    kitty_modal: modal_graphics.Renderer,
    attachment_store: attachments.Store,
    graphics_plan: GraphicsPlan = .{},
    graphics_plan_dirty: bool = false,
    cell_width_px: u16 = 0,
    cell_height_px: u16 = 0,
    modal_overlay_area: ui.Rect = .{},

    pub fn init(gpa: std.mem.Allocator, width: u16, height: u16) !State {
        return initWithTheme(gpa, width, height, theme_mod.default_theme);
    }

    pub fn initWithTheme(
        gpa: std.mem.Allocator,
        width: u16,
        height: u16,
        selected_theme: theme_mod.Theme,
    ) !State {
        return initWithAppearance(gpa, width, height, selected_theme, .unicode);
    }

    pub fn initWithAppearance(
        gpa: std.mem.Allocator,
        width: u16,
        height: u16,
        selected_theme: theme_mod.Theme,
        selected_icons: ui.icons.Theme,
    ) !State {
        return .{
            .scratch = try .init(gpa, width, height),
            .regions = .calculate(width, height, true),
            .theme = selected_theme,
            .icon_theme = selected_icons,
            .kitty_sidebar = .init(gpa),
            .kitty_icons = .init(gpa),
            .kitty_toasts = .init(gpa),
            .kitty_modal = .init(gpa),
            .attachment_store = .init(gpa),
        };
    }

    pub fn deinit(state: *State) void {
        state.scratch.deinit();
        state.kitty_sidebar.deinit();
        state.kitty_icons.deinit();
        state.kitty_toasts.deinit();
        state.kitty_modal.deinit();
        state.attachment_store.deinit();
    }

    pub fn resize(state: *State, width: u16, height: u16) !void {
        if (state.scratch.w != width or state.scratch.h != height)
            try state.scratch.resize(width, height);
        state.recalculateRegions(width, height);
        state.modal_overlay_area = .{};
        state.dirty = true;
    }

    pub fn workbench(state: *const State) ui.Rect {
        return state.regions.workbench;
    }

    fn recalculateRegions(state: *State, width: u16, height: u16) void {
        state.regions = .calculate(width, height, state.sidebar_requested);
        state.regions.reserveAttachments(state.attachment_store.hasVisibleItems());
    }

    pub fn palette(state: *const State) *const theme_mod.Palette {
        return &state.theme.palette;
    }

    pub fn setTheme(state: *State, selected_theme: theme_mod.Theme) void {
        state.theme = selected_theme;
        state.hovered = null;
        state.dirty = true;
    }

    pub fn setIconTheme(state: *State, selected_theme: ui.icons.Theme) void {
        if (state.icon_theme == selected_theme) return;
        state.icon_theme = selected_theme;
        state.dirty = true;
    }

    fn toggleSidebar(state: *State) void {
        state.sidebar_requested = !state.sidebar_requested;
        state.recalculateRegions(state.scratch.w, state.scratch.h);
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

    /// Clears stale pointer hover when a modal input surface changes routing.
    ///
    /// ```zig
    /// view.clearHover();
    /// ```
    pub fn clearHover(state: *State) void {
        if (state.hovered == null) {
            return;
        }

        state.hovered = null;
        state.dirty = true;
    }

    pub fn notify(
        state: *State,
        now_ns: u64,
        input: widgets.notification.Input,
    ) widgets.notification.Id {
        state.dirty = true;
        return state.notifications.push(now_ns, input);
    }

    pub fn nextNotificationDeadline(
        state: *const State,
        now_ns: u64,
        frame_interval_ns: u64,
    ) ?u64 {
        return state.notifications.nextDeadline(now_ns, frame_interval_ns);
    }

    pub fn advanceNotifications(state: *State, now_ns: u64) bool {
        if (!state.notifications.advance(now_ns)) return false;
        state.dirty = true;
        return true;
    }

    /// Projects the committed workspace-list preference into client chrome.
    ///
    /// ```zig
    /// view.setWorkspaceListCollapsed(model.workspaceListCollapsed());
    /// ```
    pub fn setWorkspaceListCollapsed(state: *State, collapsed: bool) void {
        if (state.workspace_list_collapsed == collapsed) {
            return;
        }

        state.workspace_list_collapsed = collapsed;
        state.hovered = null;
        state.dirty = true;
    }

    /// Resets transient sidebar position when the presenter observes a new
    /// semantic agent revision.
    ///
    /// ```zig
    /// view.resetSidebarScroll();
    /// ```
    pub fn resetSidebarScroll(state: *State) void {
        state.sidebar.scroll = 0;
    }

    /// Advances time-driven sidebar presentation state. The client model
    /// decides whether a working agent warrants an animation tick.
    ///
    /// ```zig
    /// _ = view.advanceSidebarAnimation();
    /// ```
    pub fn advanceSidebarAnimation(state: *State) bool {
        state.sidebar_animation_frame +%= 1;
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
        const toast_changed = state.kitty_toasts.configure(support, cell_width, cell_height);
        const modal_changed = state.kitty_modal.configure(support, cell_width, cell_height);
        const icons_changed = state.kitty_icons.configure(support, cell_width, cell_height);
        const attachments_changed = state.attachment_store.configure(
            support,
            cell_width,
            cell_height,
        );
        if (state.sidebar_rendering != resolved or state.cell_width_px != cell_width or
            state.cell_height_px != cell_height or toast_changed or icons_changed or
            modal_changed or attachments_changed)
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

    pub fn kittyToasts(state: *State) *toast_graphics.Renderer {
        return &state.kitty_toasts;
    }

    pub fn kittyModal(state: *State) *modal_graphics.Renderer {
        return &state.kitty_modal;
    }

    pub fn kittyIcons(state: *State) *icon_graphics.Renderer {
        return &state.kitty_icons;
    }

    pub fn kittyAttachments(state: *State) *attachments.Store {
        return &state.attachment_store;
    }

    /// Applies an already resolved attachment identity and reports whether
    /// the shelf changed client layout.
    ///
    /// ```zig
    /// const layout_changed = view.syncAttachmentTarget(target);
    /// ```
    pub fn syncAttachmentTarget(state: *State, target: ?attachments.Target) bool {
        const change = state.attachment_store.setTarget(target);
        if (!change.changed) return false;
        if (change.layout_changed)
            state.recalculateRegions(state.scratch.w, state.scratch.h);
        state.hovered = null;
        state.dirty = true;
        return change.layout_changed;
    }

    pub fn adoptAttachment(state: *State, capture: *attachments.Capture) !bool {
        const had_items = state.attachment_store.hasVisibleItems();
        try state.attachment_store.adopt(capture);
        const has_items = state.attachment_store.hasVisibleItems();
        const layout_changed = had_items != has_items;
        if (layout_changed) state.recalculateRegions(state.scratch.w, state.scratch.h);
        state.dirty = true;
        return layout_changed;
    }

    pub fn hasAttachmentModal(state: *const State) bool {
        return state.attachment_store.hasModal();
    }

    pub fn closeAttachmentModal(state: *State) bool {
        if (!state.attachment_store.closeModal()) return false;
        state.hovered = null;
        state.dirty = true;
        return true;
    }

    /// Applies the latest allocation-free render plan after the cell frame is
    /// already visible. A newer render simply replaces this fixed-size plan,
    /// so media work never builds a visual replay behind interactive work.
    pub fn prepareGraphics(state: *State, media_idle: bool) !bool {
        if (!state.graphics_plan_dirty and
            !(media_idle and state.kitty_toasts.preparationDeferred())) return false;
        state.kitty_toasts.setMediaIdle(media_idle);
        state.kitty_toasts.prepareThemed(
            state.graphics_plan.toast_area,
            &state.notifications,
            state.palette(),
            state.icon_theme,
        );
        state.attachment_store.prepare(state.graphics_plan.attachments);
        state.kitty_modal.prepare(state.graphics_plan.modal_area, state.palette());
        try state.kitty_sidebar.prepare(
            state.graphics_plan.sidebar_area,
            state.graphics_plan.focused_card,
            state.graphics_plan.provider_marks[0..state.graphics_plan.provider_mark_count],
            state.cell_width_px,
            state.cell_height_px,
        );
        var icon_fallback_changed = false;
        state.kitty_icons.prepare(state.graphics_plan.icons.slice()) catch {
            state.kitty_icons.disable();
            state.dirty = true;
            icon_fallback_changed = true;
        };
        state.graphics_plan_dirty = false;
        return icon_fallback_changed;
    }

    pub fn graphicsPreparationPending(state: *const State) bool {
        return state.graphics_plan_dirty;
    }

    pub fn graphicalToastsCover(state: *const State) bool {
        return state.kitty_toasts.covers(&state.notifications);
    }

    pub fn graphicalModalCovers(state: *const State, area: ui.Rect) bool {
        return state.kitty_modal.covers(area);
    }

    pub fn graphicalModalCoversPlan(state: *const State) bool {
        return state.graphicalModalCovers(state.graphics_plan.modal_area);
    }

    pub fn handleMouse(state: *State, mouse: term.Event.Mouse, now_ns: u64) Interaction {
        var result: Interaction = .{};
        if (state.attachment_store.hasModal()) result.consumed = true;
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
        switch (action) {
            .toggle_sidebar => result.toggle_sidebar = true,
            .focus_pane => |pane_id| result.focus_pane = pane_id,
            .select_tab => |tab_id| {
                switch (mouse.button & 0b11) {
                    0 => result.select_tab = tab_id,
                    2 => result.rename_tab = tab_id,
                    else => {},
                }
            },
            .active_workspace => {},
            .select_workspace => |workspace| result.select_workspace = workspace,
            .toggle_workspace_list => result.toggle_workspace_list = true,
            .sidebar_focus_agent => |key| result.focus_agent = key,
            .sidebar_scroll_to => |row| {
                state.sidebar.scroll = row;
                state.dirty = true;
                result.redraw = true;
            },
            .notification_activate => |id| {
                result.notification_target = state.notifications.activate(id, now_ns);
                if (result.notification_target != null) {
                    state.dirty = true;
                    result.redraw = true;
                }
            },
            .notification_dismiss => |id| if (state.notifications.dismiss(id, now_ns)) {
                result.notification_target = .none;
                state.dirty = true;
                result.redraw = true;
            },
            .attachment_open => |id| {
                result.consumed = true;
                if (state.attachment_store.openModal(id)) {
                    state.hovered = null;
                    state.dirty = true;
                    result.redraw = true;
                }
            },
            .attachment_dismiss => |id| {
                result.consumed = true;
                const had_items = state.attachment_store.hasVisibleItems();
                if (state.attachment_store.remove(id)) {
                    const has_items = state.attachment_store.hasVisibleItems();
                    result.layout_changed = had_items != has_items;
                    if (result.layout_changed)
                        state.recalculateRegions(state.scratch.w, state.scratch.h);
                    state.hovered = null;
                    state.dirty = true;
                    result.redraw = true;
                }
            },
            .attachment_modal_close => {
                result.consumed = true;
                if (state.closeAttachmentModal()) result.redraw = true;
            },
            .attachment_modal_hold => result.consumed = true,
        }
        return result;
    }

    fn sidebarListHeight(state: *const State) u16 {
        return state.regions.sidebar.h -| 11;
    }

    /// A rejected configuration paints one red line over the bottom row so
    /// the message survives until the next successful reload.
    fn renderDiagnosticBanner(state: *State, screen: *term.Screen, diagnostic: ?[]const u8) void {
        const message = diagnostic orelse return;
        if (screen.back.h == 0) return;
        const colors = state.palette();
        const banner: ui.Rect = .{
            .y = screen.back.h - 1,
            .w = screen.back.w,
            .h = 1,
        };
        const style: ui.Style = .{
            .fg = colors.text,
            .bg = colors.red,
            .flags = .{ .bold = true },
        };
        screen.back.fill(banner, " ", style);
        const prefix_width = screen.back.writeText(banner, 0, banner.y, "TELAR CONFIG  ", style);
        _ = screen.back.writeText(banner, prefix_width, banner.y, message, style);
    }

    pub fn render(state: *State, screen: *term.Screen, input: RenderInput) !RenderStats {
        // The banner must survive every present — pane composition may have
        // repainted the bottom row — so it lands on both exit paths.
        defer state.renderDiagnosticBanner(screen, input.diagnostic);
        if (!input.force and !state.dirty and !state.attachment_store.hasModal() and
            !state.notifications.hasItems() and !state.toast_overlay_drawn)
            return .{};
        state.hits.clear();
        state.scratch.clear(.{});
        state.graphics_plan.icons.reset();
        const hybrid = state.sidebar_rendering == .kitty_hybrid or
            state.sidebar_rendering == .kitty_full;
        const focused_card_color: ?[3]u8 = if (hybrid) switch (state.palette().surface0) {
            .rgb => |value| value,
            .default, .indexed => null,
        } else null;
        var context: widgets.Context = .{
            .buffer = &state.scratch,
            .hits = &state.hits,
            .palette = state.palette(),
            .hovered = state.hovered,
            .icon_theme = state.icon_theme,
            .icon_plan = if (input.diagnostic == null and state.kitty_icons.available())
                &state.graphics_plan.icons
            else
                null,
        };
        const composed = widgets.composition.render(&context, .{
            .regions = state.regions,
            .tabs = input.tabs,
            .model = input.model,
            .rename_field = if (input.prompt) |prompt| &prompt.field else null,
            .rename_kind = promptKind(input.prompt),
            .sidebar_snapshot = input.agents,
            .sidebar_state = &state.sidebar,
            .sidebar_transparent = hybrid,
            .sidebar_rounded_focus = focused_card_color != null,
            .sidebar_animation_frame = state.sidebar_animation_frame,
            .proxy_tls_active = input.proxy_tls_active,
            .system_metrics = if (input.system_metrics) |metrics| .{
                .cpu_percent = metrics.cpu_percent,
                .memory_used_decigib = metrics.memory_used_decigib,
                .battery_percent = metrics.battery_percent,
            } else null,
            .status_mode = input.status_mode,
            .workspaces = input.workspaces,
            .workspace_list_collapsed = state.workspace_list_collapsed,
        });
        const attachment_snapshot = state.attachment_store.snapshot();
        var attachment_plan = widgets.attachment_preview.renderShelf(
            &context,
            state.regions.attachments,
            &attachment_snapshot,
        );
        const current_modal_area = if (attachment_snapshot.modal != null)
            widgets.attachment_preview.modalArea(state.regions.workbench)
        else
            ui.Rect{};
        const graphical_modal = state.graphicalModalCovers(current_modal_area);
        if (!state.modal_overlay_area.isEmpty())
            input.model.copyComposedArea(&state.scratch, state.modal_overlay_area);
        if (!current_modal_area.isEmpty() and
            !std.meta.eql(current_modal_area, state.modal_overlay_area))
            input.model.copyComposedArea(&state.scratch, current_modal_area);
        const toast_area = widgets.toast.overlayArea(state.regions.workbench);
        const has_toasts = state.notifications.hasItems() and !toast_area.isEmpty();
        const graphical_toasts = state.kitty_toasts.covers(&state.notifications);
        if (has_toasts or state.toast_overlay_drawn) {
            input.model.copyComposedArea(&state.scratch, toast_area);
            if (has_toasts) {
                if (graphical_toasts)
                    widgets.toast.registerHits(&context, toast_area, &state.notifications)
                else
                    widgets.toast.render(&context, toast_area, &state.notifications);
            }
        }
        const drawn_modal_area = widgets.attachment_preview.renderModal(
            &context,
            state.regions.workbench,
            &attachment_snapshot,
            &attachment_plan,
            graphical_modal,
        );
        if (hybrid) {
            var provider_marks: [widgets.sidebar.max_provider_marks]kitty.SidebarProviderPlacement = undefined;
            var provider_mark_count: usize = 0;
            for (composed.sidebar.provider_marks[0..composed.sidebar.provider_mark_count]) |mark| {
                const provider: kitty.SidebarProvider = switch (mark.provider) {
                    .claude => .claude,
                    .codex => .codex,
                    else => continue,
                };
                provider_marks[provider_mark_count] = .{ .area = mark.area, .provider = provider };
                provider_mark_count += 1;
            }
            state.graphics_plan.sidebar_area = composed.sidebar.area;
            state.graphics_plan.focused_card = if (composed.sidebar.focused_card) |area|
                if (focused_card_color) |color| .{ .area = area, .color = color } else null
            else
                null;
            @memcpy(
                state.graphics_plan.provider_marks[0..provider_mark_count],
                provider_marks[0..provider_mark_count],
            );
            state.graphics_plan.provider_mark_count = @intCast(provider_mark_count);
        } else {
            state.graphics_plan.sidebar_area = .{};
            state.graphics_plan.focused_card = null;
            state.graphics_plan.provider_mark_count = 0;
        }
        state.graphics_plan.toast_area = toast_area;
        state.graphics_plan.attachments = attachment_plan;
        state.graphics_plan.modal_area = drawn_modal_area;
        state.graphics_plan_dirty = true;

        var stats: RenderStats = .{};
        stats = addStats(stats, try syncRegion(screen, &state.scratch, state.regions.top));
        stats = addStats(stats, try syncRegion(screen, &state.scratch, state.regions.sidebar));
        stats = addStats(stats, try syncRegion(screen, &state.scratch, state.regions.bottom));
        stats = addStats(stats, try syncRegion(screen, &state.scratch, state.regions.attachments));
        if (has_toasts or state.toast_overlay_drawn)
            stats = addStats(stats, try syncRegion(screen, &state.scratch, toast_area));
        if (!state.modal_overlay_area.isEmpty())
            stats = addStats(stats, try syncRegion(screen, &state.scratch, state.modal_overlay_area));
        if (!drawn_modal_area.isEmpty() and
            !std.meta.eql(drawn_modal_area, state.modal_overlay_area))
            stats = addStats(stats, try syncRegion(screen, &state.scratch, drawn_modal_area));
        if (composed.cursor) |cursor| {
            screen.cursor = .{
                .x = cursor.cursor_x,
                .y = cursor.cursor_y,
            };
        }
        state.dirty = false;
        state.toast_overlay_drawn = has_toasts;
        state.modal_overlay_area = drawn_modal_area;
        return stats;
    }
};

fn promptKind(prompt: ?*const name_prompt.Prompt) widgets.tab_rename.Kind {
    const current = prompt orelse return .rename_tab;

    return switch (current.target) {
        .rename_tab => .rename_tab,
        .create_workspace => .create_workspace,
        .rename_workspace => .rename_workspace,
    };
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

test "empty production sidebar has no task controls" {
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
    _ = try state.render(&screen, .{ .model = &model, .force = true });

    try std.testing.expect(state.hits.at(3, 2) == null);
    try std.testing.expect(state.hits.at(58, 2) == null);
}

test "workbench clicks return focus intent without mutating pane layout" {
    const gpa = std.testing.allocator;
    var state = try State.init(gpa, 80, 24);
    defer state.deinit();
    var model = multiplexer.Model.init(gpa);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const first: schema.PaneId = @enumFromInt(1);
    const second: schema.PaneId = @enumFromInt(2);
    try model.addRoot(first, location, .{ .cols = 50, .rows = 22 });
    try model.split(first, second, location, .horizontal, state.workbench());
    try std.testing.expect(model.focusPane(first));
    var screen = try term.Screen.init(gpa, 80, 24);
    defer screen.deinit();
    _ = try model.render(&screen, state.workbench());
    _ = try state.render(&screen, .{ .model = &model, .force = true });
    const second_view = model.layoutSnapshot(state.workbench()).find(second).?;
    const point = term.Event.Mouse{
        .x = second_view.content.x,
        .y = second_view.content.y,
        .kind = .move,
    };
    _ = state.handleMouse(point, 0);
    state.dirty = false;
    const revision = model.layout.currentRevision();

    var click = point;
    click.kind = .press;
    const interaction = state.handleMouse(click, 0);

    try std.testing.expectEqual(second, interaction.focus_pane.?);
    try std.testing.expect(!interaction.redraw);
    try std.testing.expect(!interaction.layout_changed);
    try std.testing.expectEqual(first, model.layout.focused().?);
    try std.testing.expectEqual(revision, model.layout.currentRevision());
    try std.testing.expect(!state.dirty);
}

test "sidebar agent snapshots focus linked panes and stable hover requests no extra frame" {
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
    const agent_entries = [_]agents.AgentInput{.{
        .key = .{ .pane_id = @enumFromInt(1), .pane_generation = 1 },
        .location = location,
        .pane_index = 1,
        .provider = .codex,
        .status = .blocked,
    }};
    var snapshot: agents.Snapshot = .{};
    _ = try snapshot.replace(.{ .revision = 1, .agents = &agent_entries });
    var screen = try term.Screen.init(gpa, 100, 30);
    defer screen.deinit();
    _ = try model.render(&screen, state.workbench());
    _ = try state.render(&screen, .{ .model = &model, .agents = &snapshot, .force = true });

    const first_row = term.Event.Mouse{ .x = 4, .y = 4, .kind = .move };
    try std.testing.expect(state.handleMouse(first_row, 0).redraw);
    try std.testing.expect(!state.handleMouse(first_row, 0).redraw);
    const click = term.Event.Mouse{ .x = 4, .y = 4, .kind = .press };
    const interaction = state.handleMouse(click, 0);
    try std.testing.expectEqualDeep(agent_entries[0].key, interaction.focus_agent.?);
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(2)), model.layout.focused().?);
}

test "focused agent image preview reserves a shelf and opens a modal layer" {
    const gpa = std.testing.allocator;
    var state = try State.init(gpa, 100, 30);
    defer state.deinit();
    var model = multiplexer.Model.init(gpa);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.addRoot(pane_id, location, .{ .cols = 38, .rows = 27 });
    const agent_entries = [_]agents.AgentInput{.{
        .key = .{ .pane_id = pane_id, .pane_generation = 4 },
        .location = location,
        .pane_index = 1,
        .provider = .codex,
        .status = .ready,
    }};
    var snapshot: agents.Snapshot = .{};
    _ = try snapshot.replace(.{ .revision = 1, .agents = &agent_entries });
    const target: attachments.Target = .{
        .pane_id = agent_entries[0].key.pane_id,
        .pane_generation = agent_entries[0].key.pane_generation,
    };
    try std.testing.expect(!state.syncAttachmentTarget(target));
    const capture = try gpa.create(attachments.Capture);
    capture.* = .{
        .request = .{ .target = target, .sequence = 1 },
        .png = try gpa.dupe(u8, "png"),
        .width = 1,
        .height = 1,
    };
    try std.testing.expect(try state.adoptAttachment(capture));
    try std.testing.expectEqual(widgets.layout.attachment_shelf_height, state.regions.attachments.h);

    var screen = try term.Screen.init(gpa, 100, 30);
    defer screen.deinit();
    _ = try model.render(&screen, state.workbench());
    _ = try state.render(&screen, .{ .model = &model, .agents = &snapshot, .force = true });
    var open_point: ?struct { x: u16, y: u16 } = null;
    for (state.hits.registered()) |entry| switch (entry.action) {
        .attachment_open => {
            open_point = .{ .x = entry.rect.x + 1, .y = entry.rect.y + 1 };
            break;
        },
        else => {},
    };
    const point = open_point orelse return error.MissingAttachmentHit;
    const opened = state.handleMouse(.{
        .x = point.x,
        .y = point.y,
        .kind = .press,
    }, 0);
    try std.testing.expect(opened.consumed);
    try std.testing.expect(state.hasAttachmentModal());

    _ = try state.render(&screen, .{ .model = &model, .agents = &snapshot });
    const modal_scroll = state.handleMouse(.{
        .x = state.regions.workbench.x,
        .y = state.regions.workbench.y,
        .kind = .scroll_down,
    }, 0);
    try std.testing.expect(modal_scroll.consumed);
}

test "sidebar highlight follows pane focus and the rendered workspace" {
    const gpa = std.testing.allocator;
    var state = try State.init(gpa, 100, 30);
    defer state.deinit();
    const first_location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const second_location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = @enumFromInt(1),
    };
    const first_pane: schema.PaneId = @enumFromInt(1);
    const second_pane: schema.PaneId = @enumFromInt(2);
    const shell_pane: schema.PaneId = @enumFromInt(3);
    const workspace_pane: schema.PaneId = @enumFromInt(4);

    var first_model = multiplexer.Model.init(gpa);
    defer first_model.deinit();
    try first_model.addRoot(first_pane, first_location, .{ .cols = 34, .rows = 27 });
    try first_model.split(
        first_pane,
        second_pane,
        first_location,
        .horizontal,
        state.workbench(),
    );
    try first_model.split(
        second_pane,
        shell_pane,
        first_location,
        .vertical,
        state.workbench(),
    );
    try std.testing.expect(first_model.focusPane(first_pane));

    var second_model = multiplexer.Model.init(gpa);
    defer second_model.deinit();
    try second_model.addRoot(workspace_pane, second_location, .{ .cols = 38, .rows = 27 });

    const agent_entries = [_]agents.AgentInput{
        .{
            .key = .{ .pane_id = first_pane, .pane_generation = 1 },
            .location = first_location,
            .pane_index = 1,
            .provider = .codex,
            .status = .ready,
        },
        .{
            .key = .{ .pane_id = second_pane, .pane_generation = 1 },
            .location = first_location,
            .pane_index = 2,
            .provider = .claude,
            .status = .ready,
        },
        .{
            .key = .{ .pane_id = workspace_pane, .pane_generation = 1 },
            .location = second_location,
            .pane_index = 1,
            .provider = .codex,
            .status = .ready,
        },
    };
    var snapshot: agents.Snapshot = .{};
    _ = try snapshot.replace(.{ .revision = 1, .agents = &agent_entries });
    var screen = try term.Screen.init(gpa, 100, 30);
    defer screen.deinit();
    const palette = state.palette();

    _ = try state.render(&screen, .{ .model = &first_model, .agents = &snapshot, .force = true });
    try std.testing.expectEqualDeep(palette.surface0, screen.back.at(10, 4).?.style.bg);
    try std.testing.expectEqualDeep(palette.panel_bg, screen.back.at(10, 7).?.style.bg);

    try std.testing.expect(first_model.focusPane(second_pane));
    state.invalidate();
    _ = try state.render(&screen, .{ .model = &first_model, .agents = &snapshot });
    try std.testing.expectEqualDeep(palette.panel_bg, screen.back.at(10, 4).?.style.bg);
    try std.testing.expectEqualDeep(palette.surface0, screen.back.at(10, 7).?.style.bg);

    try std.testing.expect(first_model.focusPane(shell_pane));
    state.invalidate();
    _ = try state.render(&screen, .{ .model = &first_model, .agents = &snapshot });
    try std.testing.expectEqualDeep(palette.panel_bg, screen.back.at(10, 4).?.style.bg);
    try std.testing.expectEqualDeep(palette.panel_bg, screen.back.at(10, 7).?.style.bg);

    state.invalidate();
    _ = try state.render(&screen, .{ .model = &second_model, .agents = &snapshot });
    try std.testing.expectEqualDeep(palette.panel_bg, screen.back.at(10, 4).?.style.bg);
    try std.testing.expectEqualDeep(palette.panel_bg, screen.back.at(10, 7).?.style.bg);
    try std.testing.expectEqualDeep(palette.surface0, screen.back.at(10, 10).?.style.bg);
}

test "hybrid sidebar preserves agent hit testing and cell fallback navigation" {
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
    const agent_entries = [_]agents.AgentInput{.{
        .key = .{ .pane_id = @enumFromInt(1), .pane_generation = 4 },
        .location = location,
        .pane_index = 1,
        .provider = .claude,
        .status = .ready,
    }};
    var snapshot: agents.Snapshot = .{};
    _ = try snapshot.replace(.{ .revision = 1, .agents = &agent_entries });
    var screen = try term.Screen.init(std.testing.allocator, 100, 30);
    defer screen.deinit();
    _ = try state.render(&screen, .{ .model = &model, .agents = &snapshot, .force = true });
    _ = try state.prepareGraphics(true);
    try std.testing.expect(state.kittySidebar().focused_card != null);
    try std.testing.expectEqualDeep(
        Action{ .sidebar_focus_agent = agent_entries[0].key },
        state.hits.at(4, 4).?,
    );
    const interaction = state.handleMouse(.{ .x = 4, .y = 4, .kind = .press }, 0);
    try std.testing.expect(interaction.redraw);
    try std.testing.expectEqualDeep(agent_entries[0].key, interaction.focus_agent.?);
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(1)), model.layout.focused().?);
    try std.testing.expect(state.kittySidebar().damaged());
}

test "Nerd Font theme publishes embedded icon marks over cell fallbacks" {
    var state = try State.initWithAppearance(
        std.testing.allocator,
        100,
        30,
        theme_mod.default_theme,
        .nerd_font,
    );
    defer state.deinit();
    try state.configureSidebar(.automatic, .supported, 10, 20);
    var model = multiplexer.Model.init(std.testing.allocator);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(@enumFromInt(1), location, .{ .cols = 38, .rows = 28 });
    var screen = try term.Screen.init(std.testing.allocator, 100, 30);
    defer screen.deinit();

    _ = try state.render(&screen, .{ .model = &model, .force = true });
    const workspace_mark = for (state.graphics_plan.icons.slice()) |mark| {
        if (mark.icon == .workspace_menu) break mark;
    } else null;
    try std.testing.expect(workspace_mark != null);
    try std.testing.expectEqualStrings(
        "W",
        screen.back.at(workspace_mark.?.area.x, workspace_mark.?.area.y).?.text(),
    );
    try std.testing.expect(state.graphics_plan.icons.len != 0);
    _ = try state.prepareGraphics(true);
    try std.testing.expect(state.kittyIcons().retainedBytes() != 0);
    try std.testing.expect(state.kittyIcons().damaged());
}

test "Nerd Font theme falls back to Unicode without Kitty Graphics" {
    var state = try State.initWithAppearance(
        std.testing.allocator,
        100,
        30,
        theme_mod.default_theme,
        .nerd_font,
    );
    defer state.deinit();
    try state.configureSidebar(.automatic, .unsupported, 10, 20);
    var model = multiplexer.Model.init(std.testing.allocator);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(@enumFromInt(1), location, .{ .cols = 38, .rows = 28 });
    var screen = try term.Screen.init(std.testing.allocator, 100, 30);
    defer screen.deinit();

    _ = try state.render(&screen, .{ .model = &model, .force = true });
    const marker = for (state.hits.registered()) |entry| {
        if (std.meta.activeTag(entry.action) == .toggle_workspace_list) break entry.rect;
    } else null;
    try std.testing.expect(marker != null);
    try std.testing.expectEqualStrings(
        "\u{2756}",
        screen.back.at(marker.?.x + 1, marker.?.y).?.text(),
    );
    try std.testing.expectEqual(@as(u8, 0), state.graphics_plan.icons.len);
}

test "cell rendering leaves toast rasterization to the media pass" {
    const gpa = std.testing.allocator;
    var state = try State.init(gpa, 120, 30);
    defer state.deinit();
    try state.configureSidebar(.cells, .supported, 22, 58);
    var model = multiplexer.Model.init(gpa);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(@enumFromInt(1), location, .{ .cols = 58, .rows = 28 });
    _ = state.notify(0, .{ .title = "Ready", .message = "Open result" });
    var screen = try term.Screen.init(gpa, 120, 30);
    defer screen.deinit();
    _ = try model.render(&screen, state.workbench());
    _ = try state.render(&screen, .{ .model = &model, .force = true });

    try std.testing.expectEqual(@as(usize, 0), state.kittyToasts().retainedBytes());
    _ = try state.prepareGraphics(false);
    try std.testing.expectEqual(@as(usize, 0), state.kittyToasts().retainedBytes());
    try std.testing.expect(state.kittyToasts().preparationDeferred());

    // The same fixed plan is retried after the idle boundary; it does not need
    // another cell composition to make progress.
    _ = try state.prepareGraphics(true);
    try std.testing.expect(
        state.kittyToasts().retainedBytes() > kitty.transmission_budget_per_frame,
    );
    try std.testing.expect(state.kittyToasts().transmissionPending());
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
    _ = try state.render(&screen, .{ .model = &model, .force = true });

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
    _ = try state.render(&screen, .{ .model = &model, .force = true });

    try std.testing.expectEqualDeep(ui.Color.default, screen.back.cells[0].style.bg);
    // The bottom-left corner is the status region, which stays on the host
    // terminal's background; the bottom-right corner now holds the active tab.
    try std.testing.expectEqualDeep(
        ui.Color.default,
        screen.back.cells[@as(usize, 23) * 80].style.bg,
    );
}

test "clickable toast restores pane cells after its exit animation" {
    const gpa = std.testing.allocator;
    var state = try State.init(gpa, 120, 30);
    defer state.deinit();
    var model = multiplexer.Model.init(gpa);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(7),
    };
    try model.addRoot(@enumFromInt(1), location, .{ .cols = 58, .rows = 28 });
    const overlay = widgets.toast.overlayArea(state.workbench());
    _ = state.notify(100, .{
        .level = .success,
        .title = "Ready",
        .message = "Open tab",
        .target = .{ .select_tab = location.tab_id },
    });
    const first_frame_ns = std.time.ns_per_s / 60;
    _ = state.advanceNotifications(100 + first_frame_ns);
    const visible_width = state.notifications.itemAt(0).?.animatedWidth(overlay.w);
    const click_x = overlay.x + overlay.w - visible_width;
    const click_y = overlay.y;
    model.find(@enumFromInt(1)).?.buffer.setCell(
        click_x - state.workbench().x,
        click_y - state.workbench().y,
        "u",
        1,
        .{},
    );
    var screen = try term.Screen.init(gpa, 120, 30);
    defer screen.deinit();
    _ = try model.render(&screen, state.workbench());
    _ = try state.render(&screen, .{ .model = &model });

    const interaction = state.handleMouse(.{
        .x = click_x,
        .y = click_y,
        .kind = .press,
    }, 200);
    try std.testing.expectEqual(location.tab_id, interaction.notification_target.?.select_tab);
    try std.testing.expect(
        state.advanceNotifications(200 + widgets.notification.transition_duration_ns),
    );
    try std.testing.expect(!state.notifications.hasItems());
    _ = try state.render(&screen, .{ .model = &model });

    const restored = screen.back.cells[@as(usize, click_y) * screen.back.w + click_x];
    try std.testing.expectEqualStrings("u", restored.text());
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
        .location = .{ .workspace = workspace, .tab_id = @enumFromInt(9) },
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 50, .rows = 22 });
    var screen = try term.Screen.init(gpa, 80, 24);
    defer screen.deinit();
    const model = &tabs.active().?.model;
    _ = try model.render(&screen, state.workbench());
    _ = try state.render(&screen, .{ .tabs = &tabs, .model = model, .force = true });

    // Tabs anchor to the right edge: " 1:main " and " 2:logs " occupy the
    // last sixteen columns of the bottom row.
    const click = term.Event.Mouse{ .x = 65, .y = 23, .kind = .press };
    const interaction = state.handleMouse(click, 0);
    try std.testing.expectEqual(@as(schema.TabId, @enumFromInt(4)), interaction.select_tab.?);

    // A right click only reports the intent: entering the rename prompt is
    // a mode change the client owns.
    const rename = state.handleMouse(.{
        .x = 65,
        .y = 23,
        .kind = .press,
        .button = 2,
    }, 0);
    try std.testing.expect(rename.select_tab == null);
    try std.testing.expectEqual(@as(schema.TabId, @enumFromInt(4)), rename.rename_tab.?);
}

test "the top bar lists open workspaces and clicking one requests a switch" {
    const gpa = std.testing.allocator;
    var state = try State.init(gpa, 100, 30);
    defer state.deinit();
    var model = multiplexer.Model.init(gpa);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(@enumFromInt(1), location, .{ .cols = 38, .rows = 27 });
    var workspaces: workspace_list.Snapshot = .{};
    const entries = [_]workspace_list.EntryInput{
        .{ .workspace = @enumFromInt(1), .name = "telar", .path = "/w/telar", .tab_count = 1 },
        .{ .workspace = @enumFromInt(2), .name = "api", .path = "/w/api", .tab_count = 1 },
    };
    try std.testing.expect(try workspaces.replace(.{
        .revision = 1,
        .entries = &entries,
    }));
    var screen = try term.Screen.init(gpa, 100, 30);
    defer screen.deinit();
    _ = try state.render(&screen, .{
        .model = &model,
        .workspaces = &workspaces,
        .force = true,
    });

    const sidebar_requested = state.sidebar_requested;
    const sidebar_toggle = state.handleMouse(.{ .x = 0, .y = 0, .kind = .press }, 0);
    try std.testing.expect(sidebar_toggle.toggle_sidebar);
    try std.testing.expectEqual(sidebar_requested, state.sidebar_requested);

    // Locate hits on the top row instead of pinning glyph widths.
    var workspace_x: ?u16 = null;
    var marker_x: ?u16 = null;
    var x: u16 = 0;
    while (x < 100) : (x += 1) {
        const action = state.hits.at(x, 0) orelse continue;
        switch (std.meta.activeTag(action)) {
            .select_workspace => workspace_x = workspace_x orelse x,
            .toggle_workspace_list => marker_x = marker_x orelse x,
            else => {},
        }
    }

    const interaction = state.handleMouse(.{
        .x = workspace_x.?,
        .y = 0,
        .kind = .press,
    }, 0);
    try std.testing.expectEqual(
        @as(schema.WorkspaceId, @enumFromInt(2)),
        interaction.select_workspace.?,
    );

    const workspace_list_toggle = state.handleMouse(.{
        .x = marker_x.?,
        .y = 0,
        .kind = .press,
    }, 0);
    try std.testing.expect(workspace_list_toggle.toggle_workspace_list);
    try std.testing.expect(!state.workspace_list_collapsed);
}
