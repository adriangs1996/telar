const State = @This();
const ui = @import("../../ui/root.zig");
const source_namespace = @import("view.zig");
const theme_mod = @import("../../ui/root.zig").theme;
const core = @import("telar-core");
const widgets = @import("../../widgets/root.zig");
const kitty = @import("../../graphics/root.zig").kitty;
const icon_graphics = @import("../../graphics/root.zig").icons;
const toast_graphics = @import("../../graphics/root.zig").toast;
const modal_graphics = @import("../../graphics/root.zig").modal;
const pill_graphics = @import("../../graphics/root.zig").pill;
const attachments = @import("../../attachments/root.zig");
const GraphicsPlan = @import("GraphicsPlan.zig");
const std = @import("std");
const Dimensions = @import("Dimensions.zig");
const Appearance = @import("Appearance.zig");
const workspace_capability = @import("../../workspace/root.zig");
const notifications = @import("telar-client").notifications;
const RenderInput = @import("RenderInput.zig");
const RenderStats = @import("RenderStats.zig");
scratch: ui.Buffer,
regions: source_namespace.Regions,
geometry_state: @import("telar-client").workspace.geometry.State,
theme: theme_mod.Theme,
icon_theme: ui.icons.Theme,
hits: source_namespace.Hits = .{},
sidebar_requested: bool = true,
sidebar_preferred_width: u16 = source_namespace.sidebar_width,
sidebar_resize_active: bool = false,
hovered: ?source_namespace.Action = null,
pointer_position: ?core.ui.Point = null,
// Last projected content bounds distinguish border crossings without
// invalidating chrome for every mouse move within the same pane.
pointer_content: ui.Rect = .{},
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
kitty_pill: pill_graphics.Renderer,
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
    const regions: source_namespace.Regions = .calculate(dimensions.width, dimensions.height, .{
        .visible = true,
        .preferred_width = source_namespace.sidebar_width,
    });

    return .{
        .scratch = try .init(gpa, dimensions.width, dimensions.height),
        .regions = regions,
        .geometry_state = .{ .current = .{ .area = regions.workbench, .revision = 1 } },
        .theme = appearance.theme,
        .icon_theme = appearance.icons,
        .kitty_sidebar = .init(gpa),
        .kitty_icons = .init(gpa),
        .kitty_toasts = .init(gpa),
        .kitty_modal = .init(gpa),
        .kitty_pill = .init(gpa),
        .attachment_store = .init(gpa),
    };
}

pub fn deinit(self: *State) void {
    self.scratch.deinit();
    self.kitty_sidebar.deinit();
    self.kitty_icons.deinit();
    self.kitty_toasts.deinit();
    self.kitty_modal.deinit();
    self.kitty_pill.deinit();
    self.attachment_store.deinit();
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
    return state.geometry().area;
}

/// Example: `const region = view.geometry();`.
pub fn geometry(state: *const State) @import("telar-client").workspace.geometry.Region {
    return state.geometry_state.current;
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
    state.geometry_state.update(state.regions.workbench);
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

pub fn toggleSidebar(state: *State) void {
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
    const had_pointer = state.pointer_position != null;
    state.pointer_position = null;
    state.pointer_content = .{};

    if (state.hovered == null and !had_pointer) {
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
    const pill_changed = state.kitty_pill.configure(configuration);
    const icons_changed = state.kitty_icons.configure(configuration);
    const attachments_changed = @import("../../attachments/root.zig").delivery.configure(&state.attachment_store, configuration);
    if (state.sidebar_rendering != resolved or state.cell_width_px != configuration.cell_width or
        state.cell_height_px != configuration.cell_height or toast_changed or icons_changed or
        modal_changed or pill_changed or attachments_changed)
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

pub fn kittyPill(state: *State) *pill_graphics.Renderer {
    return &state.kitty_pill;
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
    @import("../../attachments/root.zig").delivery.prepare(&state.attachment_store, state.graphics_plan.attachments);
    state.kitty_modal.prepare(state.graphics_plan.modal_area, state.palette());
    state.kitty_pill.prepare(&state.graphics_plan.pill_labels, state.palette());
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

/// Checks text coverage, allowing the previous focus during image replacement.
/// Example: `const covered = view.graphicalPillCoversPlan();`.
pub fn graphicalPillCoversPlan(state: *const State) bool {
    return state.kitty_pill.coversText(&state.graphics_plan.pill_labels, state.palette());
}

/// Maps one pointer event to semantic intent without mutating client
/// application state.
///
/// ```zig
/// const interaction = view.handleMouse(mouse);
/// ```
pub fn handleMouse(state: *State, mouse: source_namespace.term.Event.Mouse) source_namespace.Interaction {
    var result: source_namespace.Interaction = .{};
    if (state.attachment_store.hasModal()) {
        result.consumed = true;
    }
    const crossed_content = if (state.pointer_position) |previous|
        state.pointer_content.contains(previous.x, previous.y) != state.pointer_content.contains(mouse.x, mouse.y)
    else
        false;
    state.pointer_position = .{ .x = mouse.x, .y = mouse.y };
    const hovered = state.hits.at(mouse.x, mouse.y);

    if (!source_namespace.optionalActionEql(state.hovered, hovered) or crossed_content) {
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
fn renderDiagnosticBanner(state: *State, screen: *source_namespace.term.Screen, diagnostic: ?[]const u8) void {
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

pub fn render(state: *State, screen: *source_namespace.term.Screen, input: RenderInput) !RenderStats {
    // Resolve against rebuilt hits on chrome/layout changes, and against
    // current pane metadata even when cell/chrome rendering is a no-op.
    defer screen.mouse_pointer = state.mousePointerShape(input);
    // The banner must survive every present — pane composition may have
    // repainted the bottom row — so it lands on both exit paths.
    defer state.renderDiagnosticBanner(screen, input.diagnostic);
    if (!input.force and !state.dirty and !state.attachment_store.hasModal() and
        source_namespace.pickerPrompt(input.prompt) == null and
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
    const previous_pill_area = state.graphics_plan.pill_labels.area.intersect(state.scratch.area());
    const label_plan = if (input.compositor) |compositor| compositor.fullscreenLabels() else &source_namespace.empty_pane_labels;
    const label_area = label_plan.area;
    if (input.compositor) |compositor| {
        compositor.copyArea(&state.scratch, previous_pill_area);
        compositor.copyArea(&state.scratch, label_area);
    }

    const composed = widgets.composition.render(&context, .{
        .regions = state.regions,
        .tabs = input.tabs,
        .model = input.model,
        .layout = layout,
        .rename_field = source_namespace.promptField(input.prompt),
        .rename_kind = source_namespace.promptKind(input.prompt),
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
    const picker_prompt = source_namespace.pickerPrompt(input.prompt);
    const application_area = context.buffer.area();
    const current_modal_area = if (attachment_snapshot.modal != null)
        widgets.attachment_preview.modalArea(application_area)
    else if (picker_prompt) |prompt|
        if (prompt.target() == .history)
            widgets.history_browser.modalArea(application_area, .{ .count = input.history.len, .inspecting = prompt.inspecting() })
        else
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
    const pill_occluded = !label_area.intersect(current_modal_area).isEmpty() or
        (has_toasts and !label_area.intersect(toast_area).isEmpty());
    const pill_plan = if (pill_occluded) &source_namespace.empty_pane_labels else label_plan;
    state.kitty_pill.observe(pill_plan, state.palette());
    if (state.kitty_pill.coversText(pill_plan, state.palette())) {
        for (pill_plan.slice()) |label| {
            const area: ui.Rect = .{ .x = pill_plan.area.x + label.offset, .y = pill_plan.area.y, .w = label.width, .h = 1 };
            state.scratch.fill(area, .{ .glyph = " ", .style = .{} });
        }
    }

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
            const picker_output = source_namespace.renderGotoPicker(&context, application_area, .{
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
    state.graphics_plan.pill_labels = pill_plan.*;
    state.graphics_plan_dirty = true;

    var stats: RenderStats = .{};
    stats = source_namespace.addStats(stats, try source_namespace.syncRegion(screen, &state.scratch, state.regions.top));
    stats = source_namespace.addStats(stats, try source_namespace.syncRegion(screen, &state.scratch, state.regions.sidebar));
    stats = source_namespace.addStats(stats, try source_namespace.syncRegion(screen, &state.scratch, state.regions.bottom));
    stats = source_namespace.addStats(stats, try source_namespace.syncRegion(screen, &state.scratch, attachment_area));
    stats = source_namespace.addStats(stats, try source_namespace.syncRegion(screen, &state.scratch, previous_pill_area));
    stats = source_namespace.addStats(stats, try source_namespace.syncRegion(screen, &state.scratch, label_area));
    if (has_toasts or state.toast_overlay_drawn) {
        stats = source_namespace.addStats(stats, try source_namespace.syncRegion(screen, &state.scratch, toast_area));
    }
    if (!state.modal_overlay_area.isEmpty()) {
        stats = source_namespace.addStats(stats, try source_namespace.syncRegion(screen, &state.scratch, state.modal_overlay_area));
    }
    if (!drawn_modal_area.isEmpty() and
        !std.meta.eql(drawn_modal_area, state.modal_overlay_area))
    {
        stats = source_namespace.addStats(stats, try source_namespace.syncRegion(screen, &state.scratch, drawn_modal_area));
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

pub fn mousePointerShape(state: *State, input: RenderInput) source_namespace.pointer.Shape {
    state.pointer_content = .{};

    if (input.copy_mode_active or input.prompt != null) {
        return .default;
    }

    if (state.sidebar_resize_active) {
        return .ew_resize;
    }

    const position = state.pointer_position orelse return .default;
    const hovered = state.hits.at(position.x, position.y) orelse return .default;
    return switch (hovered) {
        .resize_sidebar => .ew_resize,
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
        .focus_pane => |pane_id| state.panePointerShape(input, pane_id),
        .active_workspace, .attachment_shelf_hold, .attachment_modal_hold => .default,
    };
}

fn panePointerShape(state: *State, input: RenderInput, pane_id: source_namespace.schema.PaneId) source_namespace.pointer.Shape {
    if (state.attachment_store.hasModal()) {
        return .default;
    }

    const pane = input.model.findConst(pane_id) orelse return .default;
    if (!pane.attached) {
        return .default;
    }

    var fallback: workspace_capability.layout.Snapshot = .{};
    const layout = if (input.compositor) |compositor|
        compositor.layoutSnapshot()
    else layout: {
        input.model.layout.snapshot(state.workbench(), &fallback);
        _ = fallback.reserveBelowPane(state.attachmentReservation());
        break :layout &fallback;
    };
    const view = layout.find(pane_id) orelse return .default;
    state.pointer_content = view.content;
    const position = state.pointer_position orelse return .default;
    if (!view.content.contains(position.x, position.y)) {
        return .default;
    }

    return pane.pointer_shape;
}
