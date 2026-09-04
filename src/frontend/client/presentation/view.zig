//! Visible structure and interaction state of one telar client.

const std = @import("std");
const core = @import("telar-core");
const bars = @import("../../bars/root.zig");
const agents = @import("../../agents/root.zig");
const attachments = @import("../../attachments/root.zig");
const notifications = @import("../../notifications/root.zig");
const presentation = @import("../../presentation/root.zig");
const workspace_capability = @import("../../workspace/root.zig");
const input_application = @import("../application/input/root.zig");
const client_model = @import("../model/root.zig");
const name_prompt = @import("../model/name_prompt.zig");
const goto_picker_model = @import("../model/goto_picker.zig");
const history_palette_state = @import("../model/history_palette.zig");
const suggestion_state = @import("../model/suggestion.zig");
const diff = presentation.diff;
const pointer = presentation.pointer;
const icon_graphics = @import("../../graphics/root.zig").icons;
const kitty = @import("../../graphics/root.zig").kitty;
const modal_graphics = @import("../../graphics/root.zig").modal;
const multiplexer = workspace_capability.multiplexer;
const tabs_mod = workspace_capability.tabs;
const workspace_list = workspace_capability.workspace_list;
const term = presentation.screen;
const theme_mod = @import("../../ui/root.zig").theme;
const toast_graphics = @import("../../graphics/root.zig").toast;
const ui = @import("../../ui/root.zig");
const widgets = @import("../../widgets/root.zig");

const schema = core.schema;
const empty_agent_snapshot: agents.Snapshot = .{};
const empty_history_palette: history_palette_state.State = .{};
const empty_suggestion: suggestion_state.State = .{};
const empty_notifications: notifications.Center = .{};
const empty_workspace_list: workspace_list.Snapshot = .{};
const default_bars_state: bars.State = .{};
const view_interaction = input_application.view_interaction;

pub const sidebar_width = widgets.layout.sidebar_width;
pub const minimum_sidebar_width = widgets.layout.minimum_sidebar_width;
pub const minimum_workbench_width = widgets.layout.minimum_workbench_width;
pub const Regions = widgets.layout.Regions;
pub const Action = widgets.Action;

const Hits = widgets.Hits;

pub const Dimensions = struct {
    width: u16,
    height: u16,
};

pub const Appearance = struct {
    theme: theme_mod.Theme,
    icons: ui.icons.Theme = .unicode,
};

pub const InteractionIntent = view_interaction.Intent;
pub const Interaction = view_interaction.Command;

pub const RenderStats = struct {
    scanned: usize = 0,
    damaged: usize = 0,
};

pub const RenderInput = struct {
    tabs: ?*const tabs_mod.Model = null,
    model: *const multiplexer.Model,
    compositor: ?*const multiplexer.Compositor = null,
    agents: *const agents.Snapshot = &empty_agent_snapshot,
    sidebar_animation_frame: u8 = 0,
    notifications: *const notifications.Center = &empty_notifications,
    workspaces: *const workspace_list.Snapshot = &empty_workspace_list,
    prompt: ?*name_prompt.Prompt = null,
    history: *const history_palette_state.State = &empty_history_palette,
    suggestion: *const suggestion_state.State = &empty_suggestion,
    proxy_tls_active: bool = false,
    proxy_tls_scope: schema.ProxyScope = .exact,
    proxy_system_trusted: bool = false,
    system_metrics: ?client_model.SystemMetrics = null,
    status_mode: widgets.status_bar.Mode = .normal,
    copy_mode_active: bool = false,
    bar_state: *const bars.State = &default_bars_state,
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
    sidebar_preferred_width: u16 = sidebar_width,
    sidebar_resize_active: bool = false,
    hovered: ?Action = null,
    sidebar: widgets.sidebar.State = .{},
    workspace_list_collapsed: bool = false,
    dirty: bool = true,
    interaction_revision: u64 = 0,
    sidebar_rendering: kitty.ResolvedSidebarRendering = .cells,
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
        return initWithTheme(gpa, .{ .width = width, .height = height }, theme_mod.default_theme);
    }

    /// Initializes view state with a selected color theme.
    ///
    /// ```zig
    /// var view = try State.initWithTheme(gpa, .{ .width = 80, .height = 24 }, theme);
    /// ```
    pub fn initWithTheme(gpa: std.mem.Allocator, dimensions: Dimensions, selected_theme: theme_mod.Theme) !State {
        return initWithAppearance(gpa, dimensions, .{ .theme = selected_theme });
    }

    /// Initializes view state with selected color and icon themes.
    ///
    /// ```zig
    /// var view = try State.initWithAppearance(gpa, .{ .width = 80, .height = 24 }, .{ .theme = theme, .icons = .nerd_font });
    /// ```
    pub fn initWithAppearance(gpa: std.mem.Allocator, dimensions: Dimensions, appearance: Appearance) !State {
        return .{
            .scratch = try .init(gpa, dimensions.width, dimensions.height),
            .regions = .calculate(dimensions.width, dimensions.height, .{
                .visible = true,
                .preferred_width = sidebar_width,
            }),
            .theme = appearance.theme,
            .icon_theme = appearance.icons,
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
        if (state.scratch.w != width or state.scratch.h != height) {
            try state.scratch.resize(width, height);
        }
        state.recalculateRegions(width, height);
        state.modal_overlay_area = .{};
        state.dirty = true;
    }

    pub fn workbench(state: *const State) ui.Rect {
        return state.regions.workbench;
    }

    /// Returns the revision of disposable view state changed by host input.
    /// Presenter-owned projections and rendering do not advance it.
    ///
    /// ```zig
    /// const revision = view.interactionVersion();
    /// ```
    pub fn interactionVersion(state: *const State) u64 {
        return state.interaction_revision;
    }

    fn recalculateRegions(state: *State, width: u16, height: u16) void {
        state.regions = .calculate(width, height, .{
            .visible = state.sidebar_requested,
            .preferred_width = state.sidebar_preferred_width,
        });
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
        if (state.icon_theme == selected_theme) {
            return;
        }
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
        if (state.sidebar_requested == visible) {
            return;
        }
        state.toggleSidebar();
    }

    /// Projects the complete committed sidebar geometry into disposable view
    /// state while preserving host-dependent clamping in `Regions`.
    ///
    /// ```zig
    /// view.setSidebarLayout(true, 73);
    /// ```
    pub fn setSidebarLayout(state: *State, visible: bool, preferred_width: u16) void {
        if (state.sidebar_requested == visible and state.sidebar_preferred_width == preferred_width) {
            return;
        }

        state.sidebar_requested = visible;
        state.sidebar_preferred_width = preferred_width;
        state.recalculateRegions(state.scratch.w, state.scratch.h);
        state.hovered = null;
        state.dirty = true;
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

    /// Resolves the requested sidebar mode against host graphics support.
    ///
    /// ```zig
    /// try view.configureSidebar(.automatic, .{ .support = .supported, .cell_width = 8, .cell_height = 16 });
    /// ```
    pub fn configureSidebar(state: *State, requested: kitty.SidebarRendering, configuration: kitty.Configuration) !void {
        const resolved = try requested.resolve(configuration.support);
        const toast_changed = state.kitty_toasts.configure(configuration);
        const modal_changed = state.kitty_modal.configure(configuration);
        const icons_changed = state.kitty_icons.configure(configuration);
        const attachments_changed = state.attachment_store.configure(configuration);
        if (state.sidebar_rendering != resolved or state.cell_width_px != configuration.cell_width or
            state.cell_height_px != configuration.cell_height or toast_changed or icons_changed or
            modal_changed or attachments_changed)
        {
            state.sidebar_rendering = resolved;
            state.cell_width_px = configuration.cell_width;
            state.cell_height_px = configuration.cell_height;
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

    /// Returns the space requested below the pane that owns the visible image
    /// previews.
    ///
    /// ```zig
    /// const reservation = view.attachmentReservation();
    /// ```
    pub fn attachmentReservation(state: *const State) ?workspace_capability.layout.PaneBottomReservation {
        const target = state.attachment_store.visibleTarget() orelse return null;

        return .{
            .pane_id = target.pane_id,
            .preferred_height = widgets.attachment_preview.shelf_height,
            .minimum_height = widgets.attachment_preview.shelf_minimum_height,
            .minimum_pane_height = widgets.attachment_preview.pane_minimum_height,
        };
    }

    /// Applies an already resolved attachment identity and reports whether
    /// the shelf changed client layout.
    ///
    /// ```zig
    /// const layout_changed = view.syncAttachmentTarget(target);
    /// ```
    pub fn syncAttachmentTarget(state: *State, target: ?attachments.Target) bool {
        const change = state.attachment_store.setTarget(target);
        if (!change.changed) {
            return false;
        }
        state.hovered = null;
        state.dirty = true;
        return change.layout_changed;
    }

    pub fn adoptAttachment(state: *State, capture: *attachments.Capture) !bool {
        const had_items = state.attachment_store.hasVisibleItems();
        try state.attachment_store.adopt(capture);
        const has_items = state.attachment_store.hasVisibleItems();
        const layout_changed = had_items != has_items;
        state.dirty = true;
        return layout_changed;
    }

    /// Retires one preview after its child marker deletion has been delivered.
    /// A null result means the preview was already absent.
    ///
    /// ```zig
    /// const layout_changed = view.removeAttachment(id) orelse return;
    /// ```
    pub fn removeAttachment(state: *State, id: attachments.Id) ?bool {
        const had_items = state.attachment_store.hasVisibleItems();
        if (!state.attachment_store.remove(id)) {
            return null;
        }

        const has_items = state.attachment_store.hasVisibleItems();
        state.hovered = null;
        state.recordInteraction();

        return had_items != has_items;
    }

    /// Retires all previews owned by one prompt after that prompt is sent.
    ///
    /// ```zig
    /// const layout_changed = view.removePromptAttachments(target) orelse return;
    /// ```
    pub fn removePromptAttachments(state: *State, target: attachments.Target) ?bool {
        const had_items = state.attachment_store.hasVisibleItems();
        if (state.attachment_store.removeVisible(target) == 0) {
            return null;
        }

        const has_items = state.attachment_store.hasVisibleItems();
        state.hovered = null;
        state.recordInteraction();

        return had_items != has_items;
    }

    /// Reconciles learned image markers (Claude numbers, Pi paths) after a
    /// pane frame commits. A null result means no paired marker disappeared.
    ///
    /// ```zig
    /// const layout_changed = view.reconcileAttachmentMarkers(target, screen) orelse return;
    /// ```
    pub fn reconcileAttachmentMarkers(state: *State, target: attachments.Target, screen: attachments.MarkerScreen) ?bool {
        const had_items = state.attachment_store.hasVisibleItems();
        if (state.attachment_store.reconcileMarkers(target, screen) == 0) {
            return null;
        }

        const has_items = state.attachment_store.hasVisibleItems();
        state.hovered = null;
        state.recordInteraction();

        return had_items != has_items;
    }

    pub fn hasAttachmentModal(state: *const State) bool {
        return state.attachment_store.hasModal();
    }

    pub fn closeAttachmentModal(state: *State) bool {
        if (!state.attachment_store.closeModal()) {
            return false;
        }

        state.hovered = null;
        state.recordInteraction();

        return true;
    }

    /// Applies the latest allocation-free render plan after the cell frame is
    /// already visible. A newer render simply replaces this fixed-size plan,
    /// so media work never builds a visual replay behind interactive work.
    ///
    /// ```zig
    /// _ = try view.prepareGraphics(model.notificationSnapshot(), media_idle);
    /// ```
    pub fn prepareGraphics(state: *State, snapshot: *const notifications.Center, media_idle: bool) !bool {
        if (!state.graphics_plan_dirty and
            !(media_idle and state.kitty_toasts.preparationDeferred()))
        {
            return false;
        }
        state.kitty_toasts.setMediaIdle(media_idle);
        state.kitty_toasts.prepare(.{
            .area = state.graphics_plan.toast_area,
            .center = snapshot,
            .palette = state.palette(),
            .icon_theme = state.icon_theme,
        });
        state.attachment_store.prepare(state.graphics_plan.attachments);
        state.kitty_modal.prepare(state.graphics_plan.modal_area, state.palette());
        try state.kitty_sidebar.prepare(.{
            .area = state.graphics_plan.sidebar_area,
            .focused_card = state.graphics_plan.focused_card,
            .provider_marks = state.graphics_plan.provider_marks[0..state.graphics_plan.provider_mark_count],
        }, .{ .width = state.cell_width_px, .height = state.cell_height_px });
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

    /// Reports whether prepared toast rasters exactly cover this snapshot.
    ///
    /// ```zig
    /// const covered = view.graphicalToastsCover(model.notificationSnapshot());
    /// ```
    pub fn graphicalToastsCover(state: *const State, snapshot: *const notifications.Center) bool {
        return state.kitty_toasts.covers(snapshot);
    }

    pub fn graphicalModalCovers(state: *const State, area: ui.Rect) bool {
        return state.kitty_modal.covers(area);
    }

    pub fn graphicalModalCoversPlan(state: *const State) bool {
        return state.graphicalModalCovers(state.graphics_plan.modal_area);
    }

    /// Maps one pointer event to semantic intent without mutating client
    /// application state.
    ///
    /// ```zig
    /// const interaction = view.handleMouse(mouse);
    /// ```
    pub fn handleMouse(state: *State, mouse: term.Event.Mouse) Interaction {
        var result: Interaction = .{};
        if (state.attachment_store.hasModal()) {
            result.consumed = true;
        }
        const hovered = state.hits.at(mouse.x, mouse.y);
        if (!optionalActionEql(state.hovered, hovered)) {
            state.hovered = hovered;
            state.recordInteraction();
        }
        if (hovered) |action| {
            switch (action) {
                .attachment_open, .attachment_dismiss, .attachment_shelf_hold => result.consumed = true,
                else => {},
            }
        }
        if (state.sidebar_resize_active) {
            result.consumed = true;
            switch (mouse.kind) {
                .drag => {
                    result.intent = .{ .resize_sidebar = mouse.x +| 1 };
                },
                .release => {
                    state.sidebar_resize_active = false;
                    state.recordInteraction();
                    result.intent = .{ .resize_sidebar = mouse.x +| 1 };
                },
                else => {},
            }

            return result;
        }
        if (mouse.kind == .press and hovered != null and hovered.? == .resize_sidebar and mouse.button & 0b11 == 0) {
            state.sidebar_resize_active = true;
            state.recordInteraction();
            result.consumed = true;

            return result;
        }
        if (state.regions.sidebar.contains(mouse.x, mouse.y)) {
            switch (mouse.kind) {
                .scroll_up => if (state.sidebar.scrollBy(-3, state.sidebarListHeight())) {
                    state.recordInteraction();
                },
                .scroll_down => if (state.sidebar.scrollBy(3, state.sidebarListHeight())) {
                    state.recordInteraction();
                },
                else => {},
            }
        }
        if (mouse.kind != .press) {
            return result;
        }
        const action = hovered orelse return result;
        switch (action) {
            .toggle_sidebar => result.intent = .toggle_sidebar,
            .resize_sidebar => {},
            .focus_pane => |pane_id| result.intent = .{ .focus_pane = pane_id },
            .select_tab => |tab_id| {
                switch (mouse.button & 0b11) {
                    0 => result.intent = .{ .select_tab = tab_id },
                    2 => result.intent = .{ .rename_tab = tab_id },
                    else => {},
                }
            },
            .active_workspace => {},
            .select_workspace => |workspace| result.intent = .{ .select_workspace = workspace },
            .toggle_workspace_list => result.intent = .toggle_workspace_list,
            .sidebar_focus_agent => |key| result.intent = .{ .focus_agent = key },
            .sidebar_scroll_to => |row| {
                state.sidebar.scroll = row;
                state.recordInteraction();
            },
            .notification_activate => |id| {
                result.intent = .{ .notification_activate = id };
                result.consumed = true;
            },
            .notification_dismiss => |id| {
                result.intent = .{ .notification_dismiss = id };
                result.consumed = true;
            },
            .attachment_open => |id| {
                result.consumed = true;
                if (state.attachment_store.openModal(id)) {
                    state.hovered = null;
                    state.recordInteraction();
                }
            },
            .attachment_dismiss => |id| {
                result.consumed = true;
                result.intent = .{ .attachment_dismiss = id };
            },
            .attachment_shelf_hold => result.consumed = true,
            .attachment_modal_close => {
                result.consumed = true;
                _ = state.closeAttachmentModal();
            },
            .attachment_modal_hold => result.consumed = true,
        }
        return result;
    }

    fn sidebarListHeight(state: *const State) u16 {
        return state.regions.sidebar.h -| 11;
    }

    fn recordInteraction(state: *State) void {
        state.interaction_revision +%= 1;
        state.dirty = true;
    }

    /// A rejected configuration paints one red line over the bottom row so
    /// the message survives until the next successful reload.
    fn renderDiagnosticBanner(state: *State, screen: *term.Screen, diagnostic: ?[]const u8) void {
        const message = diagnostic orelse return;
        const banner = state.regions.bottom;
        if (banner.isEmpty()) {
            return;
        }
        const colors = state.palette();
        const style: ui.Style = .{
            .fg = colors.text,
            .bg = colors.red,
            .flags = .{ .bold = true },
        };
        screen.back.fill(banner, .{ .glyph = " ", .style = style });
        const prefix_width = screen.back.writeText(banner, .{ .point = .{ .x = banner.x, .y = banner.y }, .text = "TELAR CONFIG  ", .style = style });
        _ = screen.back.writeText(banner, .{ .point = .{ .x = banner.x + prefix_width, .y = banner.y }, .text = message, .style = style });
    }

    pub fn render(state: *State, screen: *term.Screen, input: RenderInput) !RenderStats {
        screen.mouse_pointer = state.mousePointerShape(input.copy_mode_active);
        // The banner must survive every present — pane composition may have
        // repainted the bottom row — so it lands on both exit paths.
        defer state.renderDiagnosticBanner(screen, input.diagnostic);
        if (!input.force and !state.dirty and !state.attachment_store.hasModal() and
            pickerPrompt(input.prompt) == null and
            !input.notifications.hasItems() and !state.toast_overlay_drawn)
        {
            return .{};
        }
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
        var fallback_layout: workspace_capability.layout.Snapshot = .{};
        var fallback_attachment_area: ui.Rect = .{};
        const layout = if (input.compositor) |compositor|
            compositor.layoutSnapshot()
        else layout: {
            input.model.layout.snapshot(state.workbench(), &fallback_layout);
            fallback_attachment_area = fallback_layout.reserveBelowPane(state.attachmentReservation());
            break :layout &fallback_layout;
        };
        const attachment_area = if (input.compositor) |compositor|
            compositor.bottomReservationArea()
        else
            fallback_attachment_area;
        const composed = widgets.composition.render(&context, .{
            .regions = state.regions,
            .tabs = input.tabs,
            .model = input.model,
            .layout = layout,
            .rename_field = promptField(input.prompt),
            .rename_kind = promptKind(input.prompt),
            .sidebar_snapshot = input.agents,
            .sidebar_state = &state.sidebar,
            .sidebar_transparent = hybrid,
            .sidebar_rounded_focus = focused_card_color != null,
            .sidebar_animation_frame = input.sidebar_animation_frame,
            .proxy_tls_active = input.proxy_tls_active,
            .proxy_tls_scope = input.proxy_tls_scope,
            .proxy_system_trusted = input.proxy_system_trusted,
            .system_metrics = if (input.system_metrics) |metrics| .{
                .cpu_percent = metrics.cpu_percent,
                .memory_used_decigib = metrics.memory_used_decigib,
                .battery_percent = metrics.battery_percent,
            } else null,
            .status_mode = input.status_mode,
            .workspaces = input.workspaces,
            .workspace_list_collapsed = state.workspace_list_collapsed,
            .bar_state = input.bar_state,
        });
        const attachment_snapshot = state.attachment_store.snapshot();
        var attachment_plan = widgets.attachment_preview.renderShelf(
            &context,
            attachment_area,
            &attachment_snapshot,
        );
        const picker_prompt = pickerPrompt(input.prompt);
        const application_area = context.buffer.area();
        const current_modal_area = if (attachment_snapshot.modal != null)
            widgets.attachment_preview.modalArea(application_area)
        else if (picker_prompt != null)
            widgets.goto_picker.modalArea(application_area)
        else
            ui.Rect{};
        const graphical_modal = state.graphicalModalCovers(current_modal_area);
        if (input.compositor) |compositor| {
            if (!state.modal_overlay_area.isEmpty()) {
                compositor.copyArea(&state.scratch, state.modal_overlay_area.intersect(state.regions.workbench));
            }
            if (!current_modal_area.isEmpty() and
                !std.meta.eql(current_modal_area, state.modal_overlay_area))
            {
                compositor.copyArea(&state.scratch, current_modal_area.intersect(state.regions.workbench));
            }
        }
        const toast_area = widgets.toast.overlayArea(state.regions.workbench);
        const has_toasts = input.notifications.hasItems() and !toast_area.isEmpty();
        const graphical_toasts = state.kitty_toasts.covers(input.notifications);
        if (has_toasts or state.toast_overlay_drawn) {
            if (input.compositor) |compositor| {
                compositor.copyArea(&state.scratch, toast_area);
            }
            if (has_toasts) {
                if (graphical_toasts) {
                    widgets.toast.registerHits(&context, toast_area, input.notifications);
                } else {
                    widgets.toast.render(&context, toast_area, input.notifications);
                }
            }
        }
        var drawn_modal_area = widgets.attachment_preview.renderModal(&context, .{
            .application = application_area,
            .snapshot = &attachment_snapshot,
            .plan = &attachment_plan,
            .graphical_frame = graphical_modal,
        });
        var picker_cursor: ?widgets.Cursor = null;
        if (picker_prompt) |prompt| {
            if (drawn_modal_area.isEmpty()) {
                const picker_output = renderGotoPicker(&context, application_area, .{
                    .prompt = prompt,
                    .agents = input.agents,
                    .workspaces = input.workspaces,
                    .tabs = input.tabs,
                    .history = input.history,
                    .suggestion = input.suggestion,
                    .graphical_frame = graphical_modal,
                });
                drawn_modal_area = picker_output.area;
                picker_cursor = picker_output.cursor;
            }
        }
        if (hybrid) {
            var provider_marks: [widgets.sidebar.max_provider_marks]kitty.SidebarProviderPlacement = undefined;
            var provider_mark_count: usize = 0;
            for (composed.sidebar.provider_marks[0..composed.sidebar.provider_mark_count]) |mark| {
                const provider = kitty.SidebarProvider.fromAgent(mark.provider) orelse continue;
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
        stats = addStats(stats, try syncRegion(screen, &state.scratch, attachment_area));
        if (has_toasts or state.toast_overlay_drawn) {
            stats = addStats(stats, try syncRegion(screen, &state.scratch, toast_area));
        }
        if (!state.modal_overlay_area.isEmpty()) {
            stats = addStats(stats, try syncRegion(screen, &state.scratch, state.modal_overlay_area));
        }
        if (!drawn_modal_area.isEmpty() and
            !std.meta.eql(drawn_modal_area, state.modal_overlay_area))
        {
            stats = addStats(stats, try syncRegion(screen, &state.scratch, drawn_modal_area));
        }
        if (composed.cursor) |cursor| {
            screen.cursor = .{
                .x = cursor.cursor_x,
                .y = cursor.cursor_y,
            };
        }
        if (picker_cursor) |cursor| {
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

    fn mousePointerShape(state: *const State, copy_mode_active: bool) pointer.Shape {
        if (copy_mode_active) {
            return .default;
        }

        if (state.sidebar_resize_active) {
            return .horizontal_resize;
        }

        const hovered = state.hovered orelse return .default;
        return switch (hovered) {
            .resize_sidebar => .horizontal_resize,
            .toggle_sidebar,
            .select_tab,
            .select_workspace,
            .toggle_workspace_list,
            .sidebar_focus_agent,
            .sidebar_scroll_to,
            .notification_activate,
            .notification_dismiss,
            .attachment_open,
            .attachment_dismiss,
            .attachment_modal_close,
            => .pointer,
            .focus_pane, .active_workspace, .attachment_shelf_hold, .attachment_modal_hold => .default,
        };
    }
};

fn promptKind(prompt: ?*const name_prompt.Prompt) widgets.tab_rename.Kind {
    const current = prompt orelse return .rename_tab;

    return switch (current.target) {
        .rename_tab, .goto, .history, .suggest => .rename_tab,
        .create_workspace => .create_workspace,
        .rename_workspace => .rename_workspace,
        .copy_search => |direction| switch (direction) {
            .forward => .copy_search_forward,
            .backward => .copy_search_backward,
        },
    };
}

fn pickerPrompt(prompt: ?*name_prompt.Prompt) ?*name_prompt.Prompt {
    const current = prompt orelse return null;
    return switch (current.target) {
        .goto, .history, .suggest => current,
        else => null,
    };
}

fn promptField(prompt: ?*name_prompt.Prompt) ?*widgets.tab_rename.Field {
    const current = prompt orelse return null;
    return switch (current.target) {
        .goto, .history, .suggest => null,
        else => &current.field,
    };
}

const PickerSources = struct {
    prompt: *name_prompt.Prompt,
    agents: *const agents.Snapshot,
    workspaces: *const workspace_list.Snapshot,
    tabs: ?*const tabs_mod.Model,
    history: *const history_palette_state.State,
    suggestion: *const suggestion_state.State,
    graphical_frame: bool,
};

/// Computes the deterministic result set and renders the visible window with
/// the clamped selection highlighted, scrolled so the selection stays visible.
fn renderGotoPicker(context: *widgets.Context, application: ui.Rect, sources: PickerSources) widgets.goto_picker.Output {
    var results: goto_picker_model.Results = .{};
    const match_sources: goto_picker_model.Sources = .{
        .agents = sources.agents,
        .workspaces = sources.workspaces,
        .tabs = sources.tabs,
    };
    if (sources.prompt.target == .suggest) {
        return renderSuggestPalette(context, application, sources);
    }
    if (sources.prompt.target != .goto) {
        return renderHistoryPalette(context, application, sources);
    }

    goto_picker_model.collect(match_sources, sources.prompt.field.text(), &results);

    const total: u16 = results.len;
    const selected: u16 = if (total == 0) 0 else @min(sources.prompt.selection, total - 1);
    const window: u16 = @min(@as(u16, widgets.goto_picker.max_rows), total);
    const start: u16 = if (selected + 1 > window) selected + 1 - window else 0;

    var rows: [widgets.goto_picker.max_rows]widgets.goto_picker.Row = undefined;
    for (0..window) |offset| {
        const index = start + offset;
        var label: [goto_picker_model.max_label_bytes]u8 = undefined;
        const text = goto_picker_model.describe(match_sources, results.slice()[index].item, &label);
        var row: widgets.goto_picker.Row = .{ .selected = index == selected };
        const len = @min(text.len, widgets.goto_picker.max_row_bytes);
        @memcpy(row.text[0..len], text[0..len]);
        row.len = @intCast(len);
        rows[offset] = row;
    }

    return widgets.goto_picker.render(context, application, .{
        .title = "goto",
        .field = &sources.prompt.field,
        .rows = rows[0..window],
        .total = total,
        .graphical_frame = sources.graphical_frame,
    });
}

/// Renders the history palette through the same list modal, with rows taken
/// from the palette model instead of the fuzzy matcher.
fn renderHistoryPalette(context: *widgets.Context, application: ui.Rect, sources: PickerSources) widgets.goto_picker.Output {
    const entries = sources.history.slice();
    const total: u16 = @intCast(entries.len);
    const selected: u16 = if (total == 0) 0 else @min(sources.prompt.selection, total - 1);
    const window: u16 = @min(@as(u16, widgets.goto_picker.max_rows), total);
    const start: u16 = if (selected + 1 > window) selected + 1 - window else 0;

    var rows: [widgets.goto_picker.max_rows]widgets.goto_picker.Row = undefined;
    for (0..window) |offset| {
        const index = start + offset;
        const entry = &entries[index];
        var row: widgets.goto_picker.Row = .{ .selected = index == selected };
        var len: usize = @min(entry.command_len, widgets.goto_picker.max_row_bytes);
        @memcpy(row.text[0..len], entry.commandSlice()[0..len]);
        const suffix = "  [agent]";
        if (entry.author == .agent and len + suffix.len <= widgets.goto_picker.max_row_bytes) {
            @memcpy(row.text[len .. len + suffix.len], suffix);
            len += suffix.len;
        }
        row.len = @intCast(len);
        rows[offset] = row;
    }

    var hint_storage: [24]u8 = undefined;
    const hint = std.fmt.bufPrint(&hint_storage, "scope: {s}", .{sources.prompt.scope.label()}) catch "";
    return widgets.goto_picker.render(context, application, .{
        .title = "history",
        .field = &sources.prompt.field,
        .rows = rows[0..window],
        .total = total,
        .hint = hint,
        .graphical_frame = sources.graphical_frame,
    });
}

/// Renders the suggestion palette through the same list modal: one row
/// holding the suggested command, the waiting state or the failure, and a
/// footer that says what Enter does next.
fn renderSuggestPalette(context: *widgets.Context, application: ui.Rect, sources: PickerSources) widgets.goto_picker.Output {
    const state = sources.suggestion;
    const text: []const u8 = switch (state.phase) {
        .idle => "",
        .waiting => "asking the engine...",
        .ready => state.textSlice(),
        .failed => switch (state.status) {
            .ready => "the engine returned no command",
            .unavailable => "no engine configured (runtime.engine)",
            .timeout => "the engine timed out",
            .failed => "the engine could not answer",
        },
    };
    const hint: []const u8 = switch (state.phase) {
        .idle => "enter: ask",
        .waiting => "esc: cancel",
        .ready => "enter: paste",
        .failed => "enter: ask again",
    };

    var rows: [1]widgets.goto_picker.Row = undefined;
    var total: u16 = 0;
    if (text.len != 0) {
        var row: widgets.goto_picker.Row = .{ .selected = state.phase == .ready };
        const len = @min(text.len, widgets.goto_picker.max_row_bytes);
        @memcpy(row.text[0..len], text[0..len]);
        row.len = @intCast(len);
        rows[0] = row;
        total = 1;
    }

    return widgets.goto_picker.render(context, application, .{
        .title = "suggest",
        .field = &sources.prompt.field,
        .rows = rows[0..total],
        .total = total,
        .hint = hint,
        .graphical_frame = sources.graphical_frame,
    });
}

fn optionalActionEql(a: ?Action, b: ?Action) bool {
    if (a == null or b == null) {
        return a == null and b == null;
    }
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
        stats.damaged += try diff.syncRow(.{
            .source = source_row,
            .reference = screen.back.cells[row_start..][0..source.w],
            .start = area.x,
            .end = area.x + area.w,
        }, &sink);
        stats.scanned += area.w;
    }
    return stats;
}

const TestingComposition = struct {
    model: *multiplexer.Model,
    screen: *term.Screen,
    area: ui.Rect,
    palette: *const theme_mod.Palette = &theme_mod.default_theme.palette,
    bottom_reservation: ?workspace_capability.layout.PaneBottomReservation = null,
};

fn testingCompose(compositor: *multiplexer.Compositor, composition: TestingComposition) !void {
    const rendered = try compositor.render(.{
        .model = composition.model,
        .screen = composition.screen,
        .input = .{
            .area = composition.area,
            .palette = composition.palette,
            .bottom_reservation = composition.bottom_reservation,
        },
    });
    composition.model.commitPresentation(rendered.commit);
}

test "visible regions reserve top bottom sidebar and workbench" {
    const regions = Regions.calculate(120, 40, .{ .visible = true, .preferred_width = sidebar_width });
    try std.testing.expectEqual(ui.Rect{ .x = 42, .w = 78, .h = 1 }, regions.top);
    try std.testing.expectEqual(ui.Rect{ .x = 0, .y = 0, .w = 42, .h = 40 }, regions.sidebar);
    try std.testing.expectEqual(ui.Rect{ .x = 42, .y = 1, .w = 78, .h = 38 }, regions.workbench);
    try std.testing.expectEqual(ui.Rect{ .x = 42, .y = 39, .w = 78, .h = 1 }, regions.bottom);
}

test "mouse pointer distinguishes clickable chrome panes and sidebar resizing" {
    var state = try State.init(std.testing.allocator, 80, 24);
    defer state.deinit();

    state.hovered = .toggle_sidebar;
    try std.testing.expectEqual(pointer.Shape.pointer, state.mousePointerShape(false));
    try std.testing.expectEqual(pointer.Shape.default, state.mousePointerShape(true));

    state.hovered = .{ .focus_pane = @enumFromInt(7) };
    try std.testing.expectEqual(pointer.Shape.default, state.mousePointerShape(false));

    state.hovered = .resize_sidebar;
    try std.testing.expectEqual(pointer.Shape.horizontal_resize, state.mousePointerShape(false));

    state.hovered = null;
    state.sidebar_resize_active = true;
    try std.testing.expectEqual(pointer.Shape.horizontal_resize, state.mousePointerShape(false));
}

test "narrow clients hide the sidebar without forgetting user intent" {
    const regions = Regions.calculate(61, 20, .{ .visible = true, .preferred_width = sidebar_width });
    try std.testing.expect(regions.sidebar.isEmpty());
    try std.testing.expectEqual(@as(u16, 61), regions.workbench.w);
}

test "sidebar toggle changes only the disposable client layout" {
    const gpa = std.testing.allocator;
    var state = try State.init(gpa, 100, 30);
    defer state.deinit();
    try std.testing.expectEqual(@as(u16, sidebar_width), state.regions.sidebar.w);
    try std.testing.expectEqual(ui.Rect{ .x = 42, .w = 58, .h = 1 }, state.regions.top);
    try std.testing.expectEqual(ui.Rect{ .x = 42, .y = 29, .w = 58, .h = 1 }, state.regions.bottom);

    state.toggleSidebar();

    try std.testing.expectEqual(@as(u16, 0), state.regions.sidebar.w);
    try std.testing.expectEqual(@as(u16, 100), state.regions.workbench.w);
    try std.testing.expectEqual(ui.Rect{ .w = 100, .h = 1 }, state.regions.top);
    try std.testing.expectEqual(ui.Rect{ .x = 0, .y = 29, .w = 100, .h = 1 }, state.regions.bottom);
}

test "sidebar separator drag reports exact preferred widths" {
    const gpa = std.testing.allocator;
    var state = try State.init(gpa, 120, 30);
    defer state.deinit();
    var model = multiplexer.Model.init(gpa);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 58, .rows = 27 } });
    var screen = try term.Screen.init(gpa, 120, 30);
    defer screen.deinit();
    _ = try state.render(&screen, .{ .model = &model, .force = true });

    const pressed = state.handleMouse(.{
        .x = state.regions.sidebar.w - 1,
        .y = 5,
        .kind = .press,
    });
    try std.testing.expect(pressed.consumed);
    try std.testing.expect(pressed.intent == .none);
    try std.testing.expect(state.sidebar_resize_active);

    const dragged = state.handleMouse(.{ .x = 72, .y = 5, .kind = .drag });
    try std.testing.expect(dragged.consumed);
    try std.testing.expectEqualDeep(InteractionIntent{ .resize_sidebar = 73 }, dragged.intent);
    try std.testing.expect(!dragged.layout_changed);
    try std.testing.expect(state.sidebar_resize_active);

    const released = state.handleMouse(.{ .x = 70, .y = 5, .kind = .release });
    try std.testing.expect(released.consumed);
    try std.testing.expectEqualDeep(InteractionIntent{ .resize_sidebar = 71 }, released.intent);
    try std.testing.expect(!released.layout_changed);
    try std.testing.expect(!state.sidebar_resize_active);
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
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 38, .rows = 27 } });
    var screen = try term.Screen.init(std.testing.allocator, 100, 30);
    defer screen.deinit();
    _ = try state.render(&screen, .{ .model = &model, .force = true });

    try std.testing.expect(state.hits.at(3, 2) == null);
    try std.testing.expect(state.hits.at(state.regions.sidebar.w - 4, 2) == null);
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
    try model.addRoot(.{ .pane_id = first, .location = location, .size = .{ .cols = 50, .rows = 22 } });
    try model.split(.{ .existing_pane = first, .new_pane = second, .location = location, .axis = .horizontal, .area = state.workbench() });
    try std.testing.expect(model.focusPane(first));
    var screen = try term.Screen.init(gpa, 80, 24);
    defer screen.deinit();
    var compositor = multiplexer.Compositor.init(gpa);
    defer compositor.deinit();
    try testingCompose(&compositor, .{
        .model = &model,
        .screen = &screen,
        .area = state.workbench(),
    });
    _ = try state.render(&screen, .{
        .model = &model,
        .compositor = &compositor,
        .force = true,
    });
    const second_view = model.layoutSnapshot(state.workbench()).find(second).?;
    const point = term.Event.Mouse{
        .x = second_view.content.x,
        .y = second_view.content.y,
        .kind = .move,
    };
    _ = state.handleMouse(point);
    state.dirty = false;
    const revision = model.layout.currentRevision();
    const interaction_revision = state.interactionVersion();

    var click = point;
    click.kind = .press;
    const interaction = state.handleMouse(click);

    try std.testing.expectEqualDeep(InteractionIntent{ .focus_pane = second }, interaction.intent);
    try std.testing.expect(!interaction.layout_changed);
    try std.testing.expectEqual(first, model.layout.focused().?);
    try std.testing.expectEqual(revision, model.layout.currentRevision());
    try std.testing.expectEqual(interaction_revision, state.interactionVersion());
    try std.testing.expect(!state.dirty);
}

test "sidebar agent snapshots version changed hover only once" {
    const gpa = std.testing.allocator;
    var state = try State.init(gpa, 100, 30);
    defer state.deinit();
    var model = multiplexer.Model.init(gpa);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 34, .rows = 27 } });
    try model.split(.{ .existing_pane = @enumFromInt(1), .new_pane = @enumFromInt(2), .location = location, .axis = .horizontal, .area = state.workbench() });
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
    var compositor = multiplexer.Compositor.init(gpa);
    defer compositor.deinit();
    try testingCompose(&compositor, .{
        .model = &model,
        .screen = &screen,
        .area = state.workbench(),
    });
    _ = try state.render(&screen, .{
        .model = &model,
        .compositor = &compositor,
        .agents = &snapshot,
        .force = true,
    });

    const first_row = term.Event.Mouse{ .x = 4, .y = 4, .kind = .move };
    const before_hover = state.interactionVersion();
    _ = state.handleMouse(first_row);
    try std.testing.expectEqual(before_hover + 1, state.interactionVersion());
    _ = state.handleMouse(first_row);
    try std.testing.expectEqual(before_hover + 1, state.interactionVersion());
    const click = term.Event.Mouse{ .x = 4, .y = 4, .kind = .press };
    const interaction = state.handleMouse(click);
    try std.testing.expectEqualDeep(InteractionIntent{ .focus_agent = agent_entries[0].key }, interaction.intent);
    try std.testing.expectEqual(before_hover + 1, state.interactionVersion());
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(2)), model.layout.focused().?);
}

test "focused agent image preview reserves space below its pane and opens a modal layer" {
    const gpa = std.testing.allocator;
    var state = try State.init(gpa, 100, 30);
    defer state.deinit();
    var model = multiplexer.Model.init(gpa);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const first_pane: schema.PaneId = @enumFromInt(1);
    const target_pane: schema.PaneId = @enumFromInt(2);
    try model.addRoot(.{ .pane_id = first_pane, .location = location, .size = .{
        .cols = state.workbench().w,
        .rows = state.workbench().h,
    } });
    try model.split(.{ .existing_pane = first_pane, .new_pane = target_pane, .location = location, .axis = .horizontal, .area = state.workbench() });
    const agent_entries = [_]agents.AgentInput{.{
        .key = .{ .pane_id = target_pane, .pane_generation = 4 },
        .location = location,
        .pane_index = 2,
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
    try std.testing.expectEqual(@as(u16, 28), state.workbench().h);

    var screen = try term.Screen.init(gpa, 100, 30);
    defer screen.deinit();
    var compositor = multiplexer.Compositor.init(gpa);
    defer compositor.deinit();
    try testingCompose(&compositor, .{
        .model = &model,
        .screen = &screen,
        .area = state.workbench(),
        .bottom_reservation = state.attachmentReservation(),
    });
    _ = try state.render(&screen, .{
        .model = &model,
        .compositor = &compositor,
        .agents = &snapshot,
        .force = true,
    });
    const shelf = compositor.bottomReservationArea();
    const projected = compositor.layoutSnapshot();
    const first_view = projected.find(first_pane).?;
    const target_view = projected.find(target_pane).?;
    try std.testing.expectEqual(widgets.attachment_preview.shelf_height, shelf.h);
    try std.testing.expectEqual(target_view.outer.x, shelf.x);
    try std.testing.expectEqual(target_view.outer.w, shelf.w);
    try std.testing.expectEqual(target_view.outer.y + target_view.outer.h, shelf.y);
    try std.testing.expect(first_view.outer.h > target_view.outer.h);
    try std.testing.expect(shelf.w < state.workbench().w);
    const shelf_move = state.handleMouse(.{
        .x = shelf.x + shelf.w - 1,
        .y = shelf.y,
        .kind = .move,
    });
    try std.testing.expect(shelf_move.consumed);
    const sidebar_before_modal = screen.back.at(20, 4).?.*;

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
    });
    try std.testing.expect(opened.consumed);
    try std.testing.expect(state.hasAttachmentModal());

    _ = try state.render(&screen, .{
        .model = &model,
        .compositor = &compositor,
        .agents = &snapshot,
    });
    try std.testing.expectEqual(ui.Rect{ .x = 10, .y = 3, .w = 80, .h = 24 }, state.graphics_plan.modal_area);
    try std.testing.expect(!sidebar_before_modal.eqlPublic(screen.back.at(20, 4).?));

    const modal_scroll = state.handleMouse(.{
        .x = state.regions.workbench.x,
        .y = state.regions.workbench.y,
        .kind = .scroll_down,
    });
    try std.testing.expect(modal_scroll.consumed);
    try std.testing.expect(state.closeAttachmentModal());

    _ = try state.render(&screen, .{
        .model = &model,
        .compositor = &compositor,
        .agents = &snapshot,
    });
    try std.testing.expect(sidebar_before_modal.eqlPublic(screen.back.at(20, 4).?));
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
    try first_model.addRoot(.{ .pane_id = first_pane, .location = first_location, .size = .{ .cols = 34, .rows = 27 } });
    try first_model.split(.{ .existing_pane = first_pane, .new_pane = second_pane, .location = first_location, .axis = .horizontal, .area = state.workbench() });
    try first_model.split(.{ .existing_pane = second_pane, .new_pane = shell_pane, .location = first_location, .axis = .vertical, .area = state.workbench() });
    try std.testing.expect(first_model.focusPane(first_pane));

    var second_model = multiplexer.Model.init(gpa);
    defer second_model.deinit();
    try second_model.addRoot(.{ .pane_id = workspace_pane, .location = second_location, .size = .{ .cols = 38, .rows = 27 } });

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
    try state.configureSidebar(.kitty_hybrid, .{ .support = .supported, .cell_width = 10, .cell_height = 20 });
    var model = multiplexer.Model.init(std.testing.allocator);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 30, .rows = 20 } });
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
    _ = try state.prepareGraphics(&empty_notifications, true);
    try std.testing.expect(state.kittySidebar().focused_card != null);
    try std.testing.expectEqualDeep(
        Action{ .sidebar_focus_agent = agent_entries[0].key },
        state.hits.at(4, 4).?,
    );
    const interaction_revision = state.interactionVersion();
    const interaction = state.handleMouse(.{ .x = 4, .y = 4, .kind = .press });
    try std.testing.expectEqual(interaction_revision + 1, state.interactionVersion());
    try std.testing.expectEqualDeep(InteractionIntent{ .focus_agent = agent_entries[0].key }, interaction.intent);
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(1)), model.layout.focused().?);
    try std.testing.expect(state.kittySidebar().damaged());
}

test "Nerd Font theme publishes embedded icon marks over cell fallbacks" {
    var state = try State.initWithAppearance(
        std.testing.allocator,
        .{ .width = 100, .height = 30 },
        .{ .theme = theme_mod.default_theme, .icons = .nerd_font },
    );
    defer state.deinit();
    try state.configureSidebar(.automatic, .{ .support = .supported, .cell_width = 10, .cell_height = 20 });
    var model = multiplexer.Model.init(std.testing.allocator);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 38, .rows = 28 } });
    var screen = try term.Screen.init(std.testing.allocator, 100, 30);
    defer screen.deinit();

    _ = try state.render(&screen, .{ .model = &model, .force = true });
    const logo_mark = for (state.graphics_plan.icons.slice()) |mark| {
        if (mark.icon == .telar_mark) {
            break mark;
        }
    } else null;
    try std.testing.expect(logo_mark != null);
    try std.testing.expectEqualStrings(
        " ",
        screen.back.at(logo_mark.?.area.x, logo_mark.?.area.y).?.text(),
    );
    try std.testing.expect(state.graphics_plan.icons.len != 0);
    _ = try state.prepareGraphics(&empty_notifications, true);
    try std.testing.expect(state.kittyIcons().retainedBytes() != 0);
    try std.testing.expect(state.kittyIcons().damaged());
}

test "Nerd Font theme falls back to Unicode without Kitty Graphics" {
    var state = try State.initWithAppearance(
        std.testing.allocator,
        .{ .width = 100, .height = 30 },
        .{ .theme = theme_mod.default_theme, .icons = .nerd_font },
    );
    defer state.deinit();
    try state.configureSidebar(.automatic, .{ .support = .unsupported, .cell_width = 10, .cell_height = 20 });
    var model = multiplexer.Model.init(std.testing.allocator);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 38, .rows = 28 } });
    var screen = try term.Screen.init(std.testing.allocator, 100, 30);
    defer screen.deinit();

    _ = try state.render(&screen, .{ .model = &model, .force = true });
    const logo = for (state.hits.registered()) |entry| {
        if (std.meta.activeTag(entry.action) == .toggle_sidebar) {
            break entry.rect;
        }
    } else null;
    try std.testing.expect(logo != null);
    try std.testing.expectEqualStrings(
        "\u{25a3}",
        screen.back.at(logo.?.x + 1, logo.?.y).?.text(),
    );
    try std.testing.expectEqual(@as(u8, 0), state.graphics_plan.icons.len);
}

test "cell rendering leaves toast rasterization to the media pass" {
    const gpa = std.testing.allocator;
    var state = try State.init(gpa, 120, 30);
    defer state.deinit();
    try state.configureSidebar(.cells, .{ .support = .supported, .cell_width = 22, .cell_height = 58 });
    var model = multiplexer.Model.init(gpa);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{
        .cols = state.workbench().w,
        .rows = state.workbench().h,
    } });
    var center: notifications.Center = .{};
    _ = center.push(0, .{ .title = "Ready", .message = "Open result" });
    var screen = try term.Screen.init(gpa, 120, 30);
    defer screen.deinit();
    var compositor = multiplexer.Compositor.init(gpa);
    defer compositor.deinit();
    try testingCompose(&compositor, .{
        .model = &model,
        .screen = &screen,
        .area = state.workbench(),
    });
    _ = try state.render(&screen, .{
        .model = &model,
        .compositor = &compositor,
        .notifications = &center,
        .force = true,
    });

    try std.testing.expectEqual(@as(usize, 0), state.kittyToasts().retainedBytes());
    _ = try state.prepareGraphics(&center, false);
    try std.testing.expectEqual(@as(usize, 0), state.kittyToasts().retainedBytes());
    try std.testing.expect(state.kittyToasts().preparationDeferred());

    // The same fixed plan is retried after the idle boundary; it does not need
    // another cell composition to make progress.
    _ = try state.prepareGraphics(&center, true);
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
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 50, .rows = 22 } });
    var screen = try term.Screen.init(gpa, 80, 24);
    defer screen.deinit();
    var compositor = multiplexer.Compositor.init(gpa);
    defer compositor.deinit();
    try testingCompose(&compositor, .{
        .model = &model,
        .screen = &screen,
        .area = state.workbench(),
    });
    _ = try state.render(&screen, .{
        .model = &model,
        .compositor = &compositor,
        .force = true,
    });

    const top_start = state.regions.top.x;
    try std.testing.expectEqualDeep(state.palette().panel_bg, screen.back.cells[top_start].style.bg);
    try std.testing.expectEqualDeep(state.palette().accent, screen.back.cells[top_start].style.fg);
    try std.testing.expect(!screen.back.cells[top_start].style.flags.inverse);
    try std.testing.expectEqual(theme_mod.Builtin.vesper, state.theme.base);
}

test "configuration diagnostics stay inside the bottom bar" {
    const gpa = std.testing.allocator;
    var state = try State.init(gpa, 80, 24);
    defer state.deinit();
    var model = multiplexer.Model.init(gpa);
    defer model.deinit();
    var screen = try term.Screen.init(gpa, 80, 24);
    defer screen.deinit();

    _ = try state.render(&screen, .{
        .model = &model,
        .force = true,
        .diagnostic = "invalid config",
    });

    const contracted = state.regions.bottom;
    try std.testing.expect(contracted.x > 0);
    try std.testing.expectEqualDeep(state.palette().panel_bg, screen.back.at(0, contracted.y).?.style.bg);
    try std.testing.expectEqualDeep(state.palette().red, screen.back.at(contracted.x, contracted.y).?.style.bg);
    try std.testing.expectEqualStrings("T", screen.back.at(contracted.x, contracted.y).?.text());

    state.toggleSidebar();
    _ = try state.render(&screen, .{
        .model = &model,
        .diagnostic = "invalid config",
    });

    const expanded = state.regions.bottom;
    try std.testing.expectEqual(@as(u16, 0), expanded.x);
    try std.testing.expectEqualDeep(state.palette().red, screen.back.at(0, expanded.y).?.style.bg);
    try std.testing.expectEqualStrings("T", screen.back.at(0, expanded.y).?.text());
}

test "terminal theme leaves client chrome backgrounds to the host terminal" {
    const gpa = std.testing.allocator;
    var state = try State.initWithTheme(gpa, .{ .width = 80, .height = 24 }, theme_mod.builtin(.terminal));
    defer state.deinit();
    var model = multiplexer.Model.init(gpa);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 50, .rows = 22 } });
    var screen = try term.Screen.init(gpa, 80, 24);
    defer screen.deinit();
    var compositor = multiplexer.Compositor.init(gpa);
    defer compositor.deinit();
    try testingCompose(&compositor, .{
        .model = &model,
        .screen = &screen,
        .area = state.workbench(),
        .palette = state.palette(),
    });
    _ = try state.render(&screen, .{
        .model = &model,
        .compositor = &compositor,
        .force = true,
    });

    try std.testing.expectEqualDeep(ui.Color.default, screen.back.cells[0].style.bg);
    // The sidebar column stays on the host terminal's background.
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
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{
        .cols = state.workbench().w,
        .rows = state.workbench().h,
    } });
    const overlay = widgets.toast.overlayArea(state.workbench());
    var center: notifications.Center = .{};
    const notification_id = center.push(100, .{
        .level = .success,
        .title = "Ready",
        .message = "Open tab",
        .target = .{ .select_tab = location.tab_id },
    });
    const first_frame_ns = std.time.ns_per_s / 60;
    _ = center.advance(100 + first_frame_ns);
    const visible_width = center.itemAt(0).?.animatedWidth(overlay.w);
    const click_x = overlay.x + overlay.w - visible_width;
    const click_y = overlay.y;
    model.find(@enumFromInt(1)).?.buffer.setCell(
        .{ .x = click_x - state.workbench().x, .y = click_y - state.workbench().y },
        .{ .text = "u" },
    );
    var screen = try term.Screen.init(gpa, 120, 30);
    defer screen.deinit();
    var compositor = multiplexer.Compositor.init(gpa);
    defer compositor.deinit();
    try testingCompose(&compositor, .{
        .model = &model,
        .screen = &screen,
        .area = state.workbench(),
    });
    _ = try state.render(&screen, .{
        .model = &model,
        .compositor = &compositor,
        .notifications = &center,
    });

    const interaction = state.handleMouse(.{
        .x = click_x,
        .y = click_y,
        .kind = .press,
    });
    try std.testing.expectEqualDeep(
        InteractionIntent{ .notification_activate = notification_id },
        interaction.intent,
    );
    const target = center.activate(notification_id, 200).?;
    try std.testing.expectEqual(location.tab_id, target.select_tab);
    try std.testing.expect(center.advance(200 + notifications.transition_duration_ns));
    try std.testing.expect(!center.hasItems());
    _ = try state.render(&screen, .{
        .model = &model,
        .compositor = &compositor,
        .notifications = &center,
    });

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
    try tabs.bootstrap(.{ .pane_id = @enumFromInt(1), .location = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(4),
    }, .size = .{ .cols = 50, .rows = 22 } });
    _ = try tabs.addCreated(.{
        .location = .{ .workspace = workspace, .tab_id = @enumFromInt(9) },
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 50, .rows = 22 });
    var screen = try term.Screen.init(gpa, 80, 24);
    defer screen.deinit();
    const model = &tabs.active().?.model;
    var compositor = multiplexer.Compositor.init(gpa);
    defer compositor.deinit();
    try testingCompose(&compositor, .{
        .model = model,
        .screen = &screen,
        .area = state.workbench(),
    });
    _ = try state.render(&screen, .{
        .tabs = &tabs,
        .model = model,
        .compositor = &compositor,
        .force = true,
    });

    // Tabs anchor to the right edge: " 1:main ", one empty cell and
    // " 2:logs " occupy the last seventeen columns of the bottom row.
    const click = term.Event.Mouse{ .x = 65, .y = 23, .kind = .press };
    const interaction = state.handleMouse(click);
    try std.testing.expectEqualDeep(
        InteractionIntent{ .select_tab = @enumFromInt(4) },
        interaction.intent,
    );
    try std.testing.expect(state.hits.at(71, 23) == null);
    try std.testing.expectEqualDeep(
        InteractionIntent{ .select_tab = @enumFromInt(9) },
        state.handleMouse(.{ .x = 72, .y = 23, .kind = .press }).intent,
    );

    // A right click only reports the intent: entering the rename prompt is
    // a mode change the client owns.
    const rename = state.handleMouse(.{
        .x = 65,
        .y = 23,
        .kind = .press,
        .button = 2,
    });
    try std.testing.expectEqualDeep(
        InteractionIntent{ .rename_tab = @enumFromInt(4) },
        rename.intent,
    );
}

test "tab bar marks the tab whose pane is fullscreen" {
    const gpa = std.testing.allocator;
    var state = try State.init(gpa, 100, 30);
    defer state.deinit();
    var tabs = tabs_mod.Model.init(gpa);
    defer tabs.deinit();
    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const logs: schema.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(9) };
    try tabs.bootstrap(.{ .pane_id = @enumFromInt(1), .location = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(4),
    }, .size = .{ .cols = 50, .rows = 22 } });
    _ = try tabs.addCreated(.{
        .location = logs,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 50, .rows = 22 });
    // Creating "logs" made it the active tab; its root pane is pane 2.
    const model = &tabs.active().?.model;
    try model.split(.{ .existing_pane = @enumFromInt(2), .new_pane = @enumFromInt(3), .location = logs, .axis = .horizontal, .area = state.workbench() });
    try std.testing.expect(model.toggleFullscreen());
    var screen = try term.Screen.init(gpa, 100, 30);
    defer screen.deinit();
    var compositor = multiplexer.Compositor.init(gpa);
    defer compositor.deinit();
    try testingCompose(&compositor, .{
        .model = model,
        .screen = &screen,
        .area = state.workbench(),
    });
    _ = try state.render(&screen, .{
        .tabs = &tabs,
        .model = model,
        .compositor = &compositor,
        .force = true,
    });

    // " 1:main ", one empty cell and " 2:logs ⛶ " fill the last nineteen
    // columns; the marker sits inside the second tab's click target.
    const bottom_row: usize = 29 * 100;
    try std.testing.expectEqualStrings(" ", screen.back.cells[bottom_row + 89].text());
    try std.testing.expectEqualStrings("\u{26f6}", screen.back.cells[bottom_row + 98].text());
    try std.testing.expect(state.hits.at(89, 29) == null);
    try std.testing.expectEqualDeep(
        InteractionIntent{ .select_tab = @enumFromInt(9) },
        state.handleMouse(.{ .x = 98, .y = 29, .kind = .press }).intent,
    );

    // The inactive tab sits one surface above the bar; the gap keeps the bar.
    const palette = &state.theme.palette;
    try std.testing.expectEqualDeep(palette.surface0, screen.back.cells[bottom_row + 81].style.bg);
    try std.testing.expectEqualDeep(palette.panel_bg, screen.back.cells[bottom_row + 89].style.bg);
    try std.testing.expectEqualDeep(palette.accent, screen.back.cells[bottom_row + 98].style.bg);
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
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 38, .rows = 27 } });
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
    const sidebar_toggle = state.handleMouse(.{
        .x = state.regions.top.x,
        .y = 0,
        .kind = .press,
    });
    try std.testing.expect(sidebar_toggle.intent == .toggle_sidebar);
    try std.testing.expectEqual(sidebar_requested, state.sidebar_requested);

    // Locate hits on the top row instead of pinning glyph widths. While the
    // list fits, nothing on the row collapses it.
    var workspace_x: ?u16 = null;
    var x: u16 = 0;
    while (x < 100) : (x += 1) {
        const action = state.hits.at(x, 0) orelse continue;
        switch (std.meta.activeTag(action)) {
            .select_workspace => workspace_x = workspace_x orelse x,
            .toggle_workspace_list => return error.TestUnexpectedResult,
            else => {},
        }
    }

    const interaction = state.handleMouse(.{
        .x = workspace_x.?,
        .y = 0,
        .kind = .press,
    });
    try std.testing.expectEqualDeep(
        InteractionIntent{ .select_workspace = @enumFromInt(2) },
        interaction.intent,
    );

    // Once collapsed, the counter is the one mouse target that expands it.
    state.workspace_list_collapsed = true;
    _ = try state.render(&screen, .{
        .model = &model,
        .workspaces = &workspaces,
        .force = true,
    });
    var counter_x: ?u16 = null;
    x = 0;
    while (x < 100) : (x += 1) {
        const action = state.hits.at(x, 0) orelse continue;
        if (std.meta.activeTag(action) == .toggle_workspace_list) {
            counter_x = x;
            break;
        }
    }

    const workspace_list_toggle = state.handleMouse(.{
        .x = counter_x.?,
        .y = 0,
        .kind = .press,
    });
    try std.testing.expect(workspace_list_toggle.intent == .toggle_workspace_list);
    try std.testing.expect(state.workspace_list_collapsed);
}
