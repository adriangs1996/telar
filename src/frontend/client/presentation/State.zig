const keyinput = @import("keyinput");
const cellgrid = @import("cellgrid");
const core = @import("telar-core");
const SidebarRendererInput = @import("../../graphics/SidebarRendererInput.zig");
const client = @import("telar-client");
const data = @import("model");
const context_support = @import("../../widgets/context_support.zig");
const WidgetsState = @import("../../widgets/State.zig");
const KittySidebarRenderer = @import("../../graphics/KittySidebarRenderer.zig");
const IconsRenderer = @import("../../graphics/IconsRenderer.zig");
const ToastRenderer = @import("../../graphics/ToastRenderer.zig");
const ModalRenderer = @import("../../graphics/ModalRenderer.zig");
const PillRenderer = @import("../../graphics/PillRenderer.zig");
const delivery_module = @import("../../attachments/delivery.zig");
const SidebarFocus = @import("../../graphics/SidebarFocus.zig");
const Plan = @import("../../ui/Plan.zig");
const PresentationPlan = @import("../../presentation/Plan.zig");
const std = @import("std");
const attachment_preview_module = @import("../../widgets/attachment_preview.zig");
const view_ops = @import("view.zig");
const Screen = @import("../../presentation/terminal_screen.zig").Screen;
const RenderInput = @import("RenderInput.zig");
const RenderStats = @import("RenderStats.zig");
const Context = @import("../../widgets/Context.zig");
const composition_module = @import("../../widgets/composition.zig");
const history_browser_module = @import("../../widgets/history_browser.zig");
const goto_picker_module = @import("../../widgets/goto_picker.zig");
const path_picker_module = @import("../../widgets/path_picker.zig");
const toast_module = @import("../../widgets/toast.zig");
const Cursor = @import("../../widgets/Cursor.zig");
const SidebarProviderPlacement = @import("../../graphics/SidebarProviderPlacement.zig");
const kitty_sidebar_module = @import("../../graphics/kitty_sidebar.zig");
const TabDrag = @import("TabDrag.zig");
const State = @This();

scratch: cellgrid.Buffer,
regions: data.GridRegions,
theme: data.ColorTheme,
icon_theme: data.icons.Theme,
hits: context_support.Hits = .{},
tab_drag: TabDrag = .{},
sidebar_requested: bool = true,
sidebar_preferred_width: u16 = data.sidebar.default_width,
sidebar_resize_active: bool = false,
hovered: ?context_support.Action = null,
pointer_position: ?cellgrid.Point = null,
// Last projected content bounds distinguish border crossings without
// invalidating chrome for every mouse move within the same pane.
pointer_content: cellgrid.Rect = .{},
sidebar: WidgetsState = .{},
workspace_list_collapsed: bool = false,
dirty: bool = true,
interaction_revision: u64 = 0,
sidebar_rendering: data.ResolvedSidebarRendering = .cells,
toast_overlay_drawn: bool = false,
kitty_sidebar: KittySidebarRenderer,
kitty_icons: IconsRenderer,
kitty_toasts: ToastRenderer,
kitty_modal: ModalRenderer,
kitty_pill: PillRenderer,
attachment_store: delivery_module.Store,
graphics_plan: GraphicsPlan = .{},
graphics_plan_dirty: bool = false,
cell_width_px: u16 = 0,
cell_height_px: u16 = 0,
modal_overlay_area: cellgrid.Rect = .{},

pub fn init(gpa: std.mem.Allocator, width: u16, height: u16) !State {
    return initWithTheme(gpa, .{ .width = width, .height = height }, data.theme_support.default_theme);
}

/// Initializes view state with a selected color theme.
///
/// ```zig
/// var view = try State.initWithTheme(gpa, .{ .width = 80, .height = 24 }, theme);
/// ```
pub fn initWithTheme(gpa: std.mem.Allocator, dimensions: Dimensions, selected_theme: data.ColorTheme) !State {
    return initWithAppearance(gpa, dimensions, .{ .theme = selected_theme });
}

/// Initializes view state with selected color and icon themes.
///
/// ```zig
/// var view = try State.initWithAppearance(gpa, .{ .width = 80, .height = 24 }, .{ .theme = theme, .icons = .nerd_font });
/// ```
pub fn initWithAppearance(gpa: std.mem.Allocator, dimensions: Dimensions, appearance: Appearance) !State {
    const regions: data.GridRegions = .calculate(dimensions.width, dimensions.height, true, data.sidebar.default_width);

    return .{
        .scratch = try .init(gpa, dimensions.width, dimensions.height),
        .regions = regions,
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

pub fn resize(self: *State, width: u16, height: u16) !void {
    self.tab_drag.gesture.cancel();
    self.tab_drag.hits.clear();
    if (self.scratch.w != width or self.scratch.h != height) {
        try self.scratch.resize(width, height);
    }
    self.recalculateRegions(width, height);
    self.modal_overlay_area = .{};
    self.dirty = true;
}

pub fn workbench(self: *const State) cellgrid.Rect {
    return self.regions.workbench;
}

/// Returns the revision of disposable view state changed by host input.
/// Presenter-owned projections and rendering do not advance it.
///
/// ```zig
/// const revision = view.interactionVersion();
/// ```
pub fn interactionVersion(self: *const State) u64 {
    return self.interaction_revision;
}

fn recalculateRegions(self: *State, width: u16, height: u16) void {
    self.regions = .calculate(width, height, self.sidebar_requested, self.sidebar_preferred_width);
}

pub fn palette(self: *const State) *const data.Palette {
    return &self.theme.palette;
}

pub fn setTheme(self: *State, selected_theme: data.ColorTheme) void {
    self.theme = selected_theme;
    self.hovered = null;
    self.dirty = true;
}

pub fn setIconTheme(self: *State, selected_theme: data.icons.Theme) void {
    if (self.icon_theme == selected_theme) {
        return;
    }
    self.icon_theme = selected_theme;
    self.dirty = true;
}

pub fn toggleSidebar(self: *State) void {
    self.sidebar_requested = !self.sidebar_requested;
    self.recalculateRegions(self.scratch.w, self.scratch.h);
    self.hovered = null;
    self.dirty = true;
}

pub fn setSidebarVisible(self: *State, visible: bool) void {
    if (self.sidebar_requested == visible) {
        return;
    }
    self.toggleSidebar();
}

/// Projects the complete committed sidebar geometry into disposable view
/// state while preserving host-dependent clamping in `Regions`.
///
/// ```zig
/// view.setSidebarLayout(true, 73);
/// ```
pub fn setSidebarLayout(self: *State, visible: bool, preferred_width: u16) void {
    if (self.sidebar_requested == visible and self.sidebar_preferred_width == preferred_width) {
        return;
    }

    self.sidebar_requested = visible;
    self.sidebar_preferred_width = preferred_width;
    self.recalculateRegions(self.scratch.w, self.scratch.h);
    self.hovered = null;
    self.dirty = true;
}

pub fn invalidate(self: *State) void {
    self.dirty = true;
}

/// Clears stale pointer hover when a modal input surface changes routing.
///
/// ```zig
/// view.clearHover();
/// ```
pub fn clearHover(self: *State) void {
    self.tab_drag.gesture.cancel();
    const had_pointer = self.pointer_position != null;
    self.pointer_position = null;
    self.pointer_content = .{};

    if (self.hovered == null and !had_pointer) {
        return;
    }

    self.hovered = null;
    self.dirty = true;
}

/// Projects the committed workspace-list preference into client chrome.
///
/// ```zig
/// view.setWorkspaceListCollapsed(model.workspace_list_collapsed);
/// ```
pub fn setWorkspaceListCollapsed(self: *State, collapsed: bool) void {
    if (self.workspace_list_collapsed == collapsed) {
        return;
    }

    self.workspace_list_collapsed = collapsed;
    self.hovered = null;
    self.dirty = true;
}

/// Resets transient sidebar position when the presenter observes a new
/// semantic agent revision.
///
/// ```zig
/// view.resetSidebarScroll();
/// ```
pub fn resetSidebarScroll(self: *State) void {
    self.sidebar.scroll = 0;
}

/// Resolves the requested sidebar mode against host graphics support.
///
/// ```zig
/// try view.configureSidebar(.automatic, .{ .support = .supported, .cell_width = 8, .cell_height = 16 });
/// ```
pub fn configureSidebar(self: *State, requested: data.SidebarRendering, configuration: SidebarRendererInput) !void {
    const resolved = try requested.resolve(configuration.support);
    const toast_changed = self.kitty_toasts.configure(configuration);
    const modal_changed = self.kitty_modal.configure(configuration);
    const pill_changed = self.kitty_pill.configure(configuration);
    const icons_changed = self.kitty_icons.configure(configuration);
    const attachments_changed = delivery_module.configure(&self.attachment_store, configuration);
    if (self.sidebar_rendering != resolved or self.cell_width_px != configuration.cell_width or
        self.cell_height_px != configuration.cell_height or toast_changed or icons_changed or
        modal_changed or pill_changed or attachments_changed)
    {
        self.sidebar_rendering = resolved;
        self.cell_width_px = configuration.cell_width;
        self.cell_height_px = configuration.cell_height;
        self.dirty = true;
    }
}

pub fn kittySidebar(self: *State) *KittySidebarRenderer {
    return &self.kitty_sidebar;
}

pub fn kittyToasts(self: *State) *ToastRenderer {
    return &self.kitty_toasts;
}

pub fn kittyModal(self: *State) *ModalRenderer {
    return &self.kitty_modal;
}

pub fn kittyPill(self: *State) *PillRenderer {
    return &self.kitty_pill;
}

pub fn kittyIcons(self: *State) *IconsRenderer {
    return &self.kitty_icons;
}

pub fn kittyAttachments(self: *State) *delivery_module.Store {
    return &self.attachment_store;
}

/// Returns the space requested below the pane that owns the visible image
/// previews.
///
/// ```zig
/// const reservation = view.attachmentReservation();
/// ```
pub fn attachmentReservation(self: *const State) ?data.PaneBottomReservation {
    const target = self.attachment_store.visibleTarget() orelse return null;

    return .{
        .pane_id = target.pane_id,
        .preferred_height = attachment_preview_module.shelf_height,
        .minimum_height = attachment_preview_module.shelf_minimum_height,
        .minimum_pane_height = attachment_preview_module.pane_minimum_height,
    };
}

/// Applies an already resolved attachment identity and reports whether
/// the shelf changed client layout.
///
/// ```zig
/// const layout_changed = view.syncAttachmentTarget(target);
/// ```
pub fn syncAttachmentTarget(self: *State, target: ?data.AttachmentTarget) bool {
    const change = self.attachment_store.setTarget(target);
    if (!change.changed) {
        return false;
    }
    self.hovered = null;
    self.dirty = true;
    return change.layout_changed;
}

pub fn adoptAttachment(self: *State, capture: *data.Capture) !bool {
    const had_items = self.attachment_store.hasVisibleItems();
    try self.attachment_store.adopt(capture);
    const has_items = self.attachment_store.hasVisibleItems();
    const layout_changed = had_items != has_items;
    self.dirty = true;
    return layout_changed;
}

/// Retires one preview after its child marker deletion has been delivered.
/// A null result means the preview was already absent.
///
/// ```zig
/// const layout_changed = view.removeAttachment(id) orelse return;
/// ```
pub fn removeAttachment(self: *State, id: data.AttachmentId) ?bool {
    const had_items = self.attachment_store.hasVisibleItems();
    if (!self.attachment_store.remove(id)) {
        return null;
    }

    const has_items = self.attachment_store.hasVisibleItems();
    self.hovered = null;
    self.recordInteraction();

    return had_items != has_items;
}

/// Retires all previews owned by one prompt after that prompt is sent.
///
/// ```zig
/// const layout_changed = view.removePromptAttachments(target) orelse return;
/// ```
pub fn removePromptAttachments(self: *State, target: data.AttachmentTarget) ?bool {
    const had_items = self.attachment_store.hasVisibleItems();
    if (self.attachment_store.removeVisible(target) == 0) {
        return null;
    }

    const has_items = self.attachment_store.hasVisibleItems();
    self.hovered = null;
    self.recordInteraction();

    return had_items != has_items;
}

/// Reconciles learned image markers (Claude numbers, Pi paths) after a
/// pane frame commits. A null result means no paired marker disappeared.
///
/// ```zig
/// const layout_changed = view.reconcileAttachmentMarkers(target, screen) orelse return;
/// ```
pub fn reconcileAttachmentMarkers(self: *State, target: data.AttachmentTarget, screen: client.MarkerScreen) ?bool {
    const had_items = self.attachment_store.hasVisibleItems();
    if (self.attachment_store.reconcileMarkers(target, screen) == 0) {
        return null;
    }

    const has_items = self.attachment_store.hasVisibleItems();
    self.hovered = null;
    self.recordInteraction();

    return had_items != has_items;
}

pub fn hasAttachmentModal(self: *const State) bool {
    return self.attachment_store.hasModal();
}

pub fn closeAttachmentModal(self: *State) bool {
    if (!self.attachment_store.closeModal()) {
        return false;
    }

    self.hovered = null;
    self.recordInteraction();

    return true;
}

/// Applies the latest allocation-free render plan after the cell frame is
/// already visible. A newer render simply replaces this fixed-size plan,
/// so media work never builds a visual replay behind interactive work.
///
/// ```zig
/// _ = try view.prepareGraphics(&model.notification_center, media_idle);
/// ```
pub fn prepareGraphics(self: *State, snapshot: *const data.Center, media_idle: bool) !bool {
    if (!self.graphics_plan_dirty and
        !(media_idle and self.kitty_toasts.preparationDeferred()))
    {
        return false;
    }
    self.kitty_toasts.setMediaIdle(media_idle);
    self.kitty_toasts.prepare(.{
        .area = self.graphics_plan.toast_area,
        .center = snapshot,
        .palette = self.palette(),
        .icon_theme = self.icon_theme,
    });
    delivery_module.prepare(&self.attachment_store, self.graphics_plan.attachments);
    self.kitty_modal.prepare(self.graphics_plan.modal_area, self.palette());
    self.kitty_pill.prepare(&self.graphics_plan.pill_labels, self.palette());
    try self.kitty_sidebar.prepare(.{
        .area = self.graphics_plan.sidebar_area,
        .focused_card = self.graphics_plan.focused_card,
        .provider_marks = self.graphics_plan.provider_marks[0..self.graphics_plan.provider_mark_count],
        .provider_foreground = self.palette().text.rgbChannels() orelse self.theme.terminal.foreground,
    }, .{ .width = self.cell_width_px, .height = self.cell_height_px });
    var icon_fallback_changed = false;
    self.kitty_icons.prepare(self.graphics_plan.icons.slice()) catch {
        self.kitty_icons.disable();
        self.dirty = true;
        icon_fallback_changed = true;
    };
    self.graphics_plan_dirty = false;
    return icon_fallback_changed;
}

pub fn graphicsPreparationPending(self: *const State) bool {
    return self.graphics_plan_dirty;
}

/// Reports whether prepared toast rasters exactly cover this snapshot.
///
/// ```zig
/// const covered = view.graphicalToastsCover(&model.notification_center);
/// ```
pub fn graphicalToastsCover(self: *const State, snapshot: *const data.Center) bool {
    return self.kitty_toasts.covers(snapshot);
}

pub fn graphicalModalCovers(self: *const State, area: cellgrid.Rect) bool {
    return self.kitty_modal.covers(area);
}

pub fn graphicalModalCoversPlan(self: *const State) bool {
    return self.graphicalModalCovers(self.graphics_plan.modal_area);
}

/// Checks text coverage, allowing the previous focus during image replacement.
/// Example: `const covered = view.graphicalPillCoversPlan();`.
pub fn graphicalPillCoversPlan(self: *const State) bool {
    return self.kitty_pill.coversText(&self.graphics_plan.pill_labels, self.palette());
}

/// Maps one pointer event to semantic intent without mutating client
/// application state.
///
/// ```zig
/// const interaction = view.handleMouse(mouse);
/// ```
pub fn handleMouse(self: *State, mouse: keyinput.Mouse) client.ViewInteractionCommand {
    var result: client.ViewInteractionCommand = .{};
    if (self.attachment_store.hasModal()) {
        result.consumed = true;
    }
    const crossed_content = if (self.pointer_position) |previous|
        self.pointer_content.contains(previous.x, previous.y) != self.pointer_content.contains(mouse.x, mouse.y)
    else
        false;
    self.pointer_position = .{ .x = mouse.x, .y = mouse.y };
    const hovered = self.hits.at(mouse.x, mouse.y);

    if (!view_ops.optionalActionEql(self.hovered, hovered) or crossed_content) {
        self.hovered = hovered;
        self.recordInteraction();
    }
    if (hovered) |action| {
        switch (action) {
            .attachment_open, .attachment_dismiss, .attachment_shelf_hold => result.consumed = true,
            else => {},
        }
    }
    if (self.sidebar_resize_active) {
        result.consumed = true;
        switch (mouse.kind) {
            .drag => {
                result.intent = .{ .resize_sidebar = mouse.x +| 1 };
            },
            .release => {
                self.sidebar_resize_active = false;
                self.recordInteraction();
                result.intent = .{ .resize_sidebar = mouse.x +| 1 };
            },
            else => {},
        }

        return result;
    }
    if (mouse.kind == .press and hovered != null and hovered.? == .resize_sidebar and mouse.button & 0b11 == 0) {
        self.sidebar_resize_active = true;
        self.recordInteraction();
        result.consumed = true;

        return result;
    }
    if (self.regions.sidebar.contains(mouse.x, mouse.y)) {
        switch (mouse.kind) {
            .scroll_up => if (self.sidebar.scrollBy(-3, self.sidebarListHeight())) {
                self.recordInteraction();
            },
            .scroll_down => if (self.sidebar.scrollBy(3, self.sidebarListHeight())) {
                self.recordInteraction();
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
            self.sidebar.scroll = row;
            self.recordInteraction();
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
            if (self.attachment_store.openModal(id)) {
                self.hovered = null;
                self.recordInteraction();
            }
        },
        .attachment_dismiss => |id| {
            result.consumed = true;
            result.intent = .{ .attachment_dismiss = id };
        },
        .attachment_shelf_hold => result.consumed = true,
        .attachment_modal_close => {
            result.consumed = true;
            _ = self.closeAttachmentModal();
        },
        .attachment_modal_hold => result.consumed = true,
    }
    return result;
}

fn sidebarListHeight(self: *const State) u16 {
    return self.regions.sidebar.h -| 11;
}

fn recordInteraction(self: *State) void {
    self.interaction_revision +%= 1;
    self.dirty = true;
}

/// A rejected configuration paints one red line over the bottom row so
/// the message survives until the next successful reload.
fn renderDiagnosticBanner(self: *State, screen: *Screen, diagnostic: ?[]const u8) void {
    const message = diagnostic orelse return;
    const banner = self.regions.bottom;
    if (banner.isEmpty()) {
        return;
    }
    const colors = self.palette();
    const style: cellgrid.Style = .{
        .fg = colors.text,
        .bg = colors.red,
        .flags = .{ .bold = true },
    };
    screen.back.fill(banner, .{ .glyph = " ", .style = style });
    const prefix_width = screen.back.writeText(banner, .{ .point = .{ .x = banner.x, .y = banner.y }, .text = "TELAR CONFIG  ", .style = style });
    _ = screen.back.writeText(banner, .{ .point = .{ .x = banner.x + prefix_width, .y = banner.y }, .text = message, .style = style });
}

pub fn render(self: *State, screen: *Screen, input: RenderInput) !RenderStats {
    defer self.renderTabInsertion(screen);
    // Resolve against rebuilt hits on chrome/layout changes, and against
    // current pane metadata even when cell/chrome rendering is a no-op.
    defer screen.mouse_pointer = self.mousePointerShape(input);
    // The banner must survive every present — pane composition may have
    // repainted the bottom row — so it lands on both exit paths.
    defer self.renderDiagnosticBanner(screen, input.diagnostic);
    if (!input.force and !self.dirty and !self.attachment_store.hasModal() and
        view_ops.pickerPrompt(input.prompt) == null and
        !input.notifications.hasItems() and !self.toast_overlay_drawn)
    {
        return .{};
    }
    self.hits.clear();
    self.scratch.clear(.{});
    self.graphics_plan.icons.reset();
    const hybrid = self.sidebar_rendering == .kitty_hybrid or
        self.sidebar_rendering == .kitty_full;
    const focused_card_color: ?[3]u8 = if (hybrid) self.palette().surface0.rgbChannels() else null;
    var context: Context = .{
        .buffer = &self.scratch,
        .hits = &self.hits,
        .palette = self.palette(),
        .hovered = self.hovered,
        .icon_theme = self.icon_theme,
        .icon_plan = if (input.diagnostic == null and self.kitty_icons.available())
            &self.graphics_plan.icons
        else
            null,
    };
    var fallback_layout: data.LayoutSnapshot = .{};
    var fallback_attachment_area: cellgrid.Rect = .{};
    const layout = if (input.compositor) |compositor|
        compositor.layoutSnapshot()
    else layout: {
        input.model.tabs.layout[input.tab].snapshot(self.workbench(), &fallback_layout);
        fallback_attachment_area = fallback_layout.reserveBelowPane(self.attachmentReservation());
        break :layout &fallback_layout;
    };
    const attachment_area = if (input.compositor) |compositor|
        compositor.bottomReservationArea()
    else
        fallback_attachment_area;
    const previous_pill_area = self.graphics_plan.pill_labels.area.intersect(self.scratch.area());
    const label_plan = if (input.compositor) |compositor| compositor.fullscreenLabels() else &view_ops.empty_pane_labels;
    const label_area = label_plan.area;
    if (input.compositor) |compositor| {
        compositor.copyArea(&self.scratch, previous_pill_area);
        compositor.copyArea(&self.scratch, label_area);
    }

    const composed = composition_module.render(&context, .{
        .regions = self.regions,
        .model = input.model,
        .tab = input.tab,
        .layout = layout,
        .rename_field = view_ops.promptField(input.prompt),
        .rename_kind = view_ops.promptKind(input.prompt),
        .prompt = input.prompt,
        .path_completion = input.path_completion,
        .sidebar_snapshot = input.agents,
        .sidebar_state = &self.sidebar,
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
        .workspace_list_collapsed = self.workspace_list_collapsed,
        .bar_state = input.bar_state,
    });
    const attachment_snapshot = self.attachment_store.snapshot();
    var attachment_plan = attachment_preview_module.renderShelf(
        &context,
        attachment_area,
        &attachment_snapshot,
    );
    const picker_prompt = view_ops.pickerPrompt(input.prompt);
    const application_area = context.buffer.area();
    const path_placement = path_picker_module.modalArea(
        application_area,
        input.model,
        input.tab,
        layout,
    );
    const current_modal_area = if (attachment_snapshot.modal != null)
        attachment_preview_module.modalArea(application_area)
    else if (picker_prompt) |prompt|
        if (prompt.target() == .history)
            history_browser_module.modalArea(application_area, .{ .count = input.history.len, .inspecting = prompt.inspecting() })
        else if (prompt.target() == .paths)
            path_placement.area
        else
            goto_picker_module.modalArea(application_area)
    else
        cellgrid.Rect{};
    const graphical_modal = self.graphicalModalCovers(current_modal_area);
    if (input.compositor) |compositor| {
        if (!self.modal_overlay_area.isEmpty()) {
            compositor.copyArea(&self.scratch, self.modal_overlay_area.intersect(self.regions.workbench));
        }
        if (!current_modal_area.isEmpty() and
            !std.meta.eql(current_modal_area, self.modal_overlay_area))
        {
            compositor.copyArea(&self.scratch, current_modal_area.intersect(self.regions.workbench));
        }
    }
    const toast_area = toast_module.overlayArea(self.regions.workbench);
    const has_toasts = input.notifications.hasItems() and !toast_area.isEmpty();
    const pill_occluded = !label_area.intersect(current_modal_area).isEmpty() or
        (has_toasts and !label_area.intersect(toast_area).isEmpty());
    const pill_plan = if (pill_occluded) &view_ops.empty_pane_labels else label_plan;
    self.kitty_pill.observe(pill_plan, self.palette());
    if (self.kitty_pill.coversText(pill_plan, self.palette())) {
        for (pill_plan.slice()) |label| {
            const area: cellgrid.Rect = .{ .x = pill_plan.area.x + label.offset, .y = pill_plan.area.y, .w = label.width, .h = 1 };
            self.scratch.fill(area, .{ .glyph = " ", .style = .{} });
        }
    }

    const graphical_toasts = self.kitty_toasts.covers(input.notifications);
    if (has_toasts or self.toast_overlay_drawn) {
        if (input.compositor) |compositor| {
            compositor.copyArea(&self.scratch, toast_area);
        }
        if (has_toasts) {
            if (graphical_toasts) {
                toast_module.registerHits(&context, toast_area, input.notifications);
            } else {
                toast_module.render(&context, toast_area, input.notifications);
            }
        }
    }
    var drawn_modal_area = attachment_preview_module.renderModal(&context, .{
        .application = application_area,
        .snapshot = &attachment_snapshot,
        .plan = &attachment_plan,
        .graphical_frame = graphical_modal,
    });
    var picker_cursor: ?Cursor = null;
    if (picker_prompt) |prompt| {
        if (drawn_modal_area.isEmpty() and prompt.target() == .paths) {
            const picker_output = path_picker_module.render(&context, .{
                .placement = path_placement,
                .field = &prompt.field,
                .selection = prompt.selection(),
                .state = &input.model.path_picker,
                .graphical_frame = graphical_modal,
            });
            drawn_modal_area = picker_output.area;
            picker_cursor = picker_output.cursor;
        } else if (drawn_modal_area.isEmpty()) {
            const picker_output = view_ops.renderGotoPicker(&context, application_area, .{
                .prompt = prompt,
                .agents = input.agents,
                .workspaces = input.workspaces,
                .model = input.model,
                .history = input.history,
                .suggestion = input.suggestion,
                .graphical_frame = graphical_modal,
            });
            drawn_modal_area = picker_output.area;
            picker_cursor = picker_output.cursor;
        }
    }
    if (hybrid) {
        var provider_marks: [core.max_agent_snapshot_entries]SidebarProviderPlacement = undefined;
        var provider_mark_count: usize = 0;
        for (composed.sidebar.provider_marks[0..composed.sidebar.provider_mark_count]) |mark| {
            const provider = kitty_sidebar_module.SidebarProvider.fromAgent(mark.provider) orelse continue;
            provider_marks[provider_mark_count] = .{ .area = mark.area, .provider = provider };
            provider_mark_count += 1;
        }
        self.graphics_plan.sidebar_area = composed.sidebar.area;
        self.graphics_plan.focused_card = if (composed.sidebar.focused_card) |area|
            if (focused_card_color) |color| .{ .area = area, .color = color } else null
        else
            null;
        @memcpy(
            self.graphics_plan.provider_marks[0..provider_mark_count],
            provider_marks[0..provider_mark_count],
        );
        self.graphics_plan.provider_mark_count = @intCast(provider_mark_count);
    } else {
        self.graphics_plan.sidebar_area = .{};
        self.graphics_plan.focused_card = null;
        self.graphics_plan.provider_mark_count = 0;
    }
    self.graphics_plan.toast_area = toast_area;
    self.graphics_plan.attachments = attachment_plan;
    self.graphics_plan.modal_area = drawn_modal_area;
    self.graphics_plan.pill_labels = pill_plan.*;
    self.graphics_plan_dirty = true;

    var stats: RenderStats = .{};
    stats = view_ops.addStats(stats, try view_ops.syncRegion(screen, &self.scratch, self.regions.top));
    stats = view_ops.addStats(stats, try view_ops.syncRegion(screen, &self.scratch, self.regions.sidebar));
    stats = view_ops.addStats(stats, try view_ops.syncRegion(screen, &self.scratch, self.regions.bottom));
    stats = view_ops.addStats(stats, try view_ops.syncRegion(screen, &self.scratch, attachment_area));
    stats = view_ops.addStats(stats, try view_ops.syncRegion(screen, &self.scratch, previous_pill_area));
    stats = view_ops.addStats(stats, try view_ops.syncRegion(screen, &self.scratch, label_area));
    if (has_toasts or self.toast_overlay_drawn) {
        stats = view_ops.addStats(stats, try view_ops.syncRegion(screen, &self.scratch, toast_area));
    }
    if (!self.modal_overlay_area.isEmpty()) {
        stats = view_ops.addStats(stats, try view_ops.syncRegion(screen, &self.scratch, self.modal_overlay_area));
    }
    if (!drawn_modal_area.isEmpty() and
        !std.meta.eql(drawn_modal_area, self.modal_overlay_area))
    {
        stats = view_ops.addStats(stats, try view_ops.syncRegion(screen, &self.scratch, drawn_modal_area));
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
    self.dirty = false;
    self.toast_overlay_drawn = has_toasts;
    self.modal_overlay_area = drawn_modal_area;
    return stats;
}

pub fn mousePointerShape(self: *State, input: RenderInput) core.PointerShape {
    self.pointer_content = .{};

    if (input.copy_mode_active or input.prompt != null) {
        return .default;
    }

    if (self.sidebar_resize_active) {
        return .ew_resize;
    }

    const position = self.pointer_position orelse return .default;
    const hovered = self.hits.at(position.x, position.y) orelse return .default;
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
        .focus_pane => |pane_id| self.panePointerShape(input, pane_id),
        .active_workspace, .attachment_shelf_hold, .attachment_modal_hold => .default,
    };
}

fn panePointerShape(self: *State, input: RenderInput, pane_id: core.PaneId) core.PointerShape {
    if (self.attachment_store.hasModal()) {
        return .default;
    }

    const pane = input.model.panes.findInConst(input.model.tabs.location[input.tab].tab_id, pane_id) orelse return .default;
    if (!pane.attached) {
        return .default;
    }

    var fallback: data.LayoutSnapshot = .{};
    const layout = if (input.compositor) |compositor|
        compositor.layoutSnapshot()
    else layout: {
        input.model.tabs.layout[input.tab].snapshot(self.workbench(), &fallback);
        _ = fallback.reserveBelowPane(self.attachmentReservation());
        break :layout &fallback;
    };
    const view = layout.find(pane_id) orelse return .default;
    self.pointer_content = view.content;
    const position = self.pointer_position orelse return .default;
    if (!view.content.contains(position.x, position.y)) {
        return .default;
    }

    return pane.pointer_shape;
}

fn renderTabInsertion(self: *State, screen: *Screen) void {
    const target = self.tab_drag.gesture.destination orelse return;
    for (self.hits.registered()) |hit| {
        if (hit.action != .select_tab or hit.action.select_tab != target.relative_to) {
            continue;
        }

        const x = if (target.direction == .previous) hit.rect.x else hit.rect.x + hit.rect.w -| 1;
        _ = screen.back.writeTruncated(hit.rect, .{ .point = .{ .x = x, .y = hit.rect.y }, .text = "▏", .max_width = 1, .style = .{ .fg = self.palette().accent, .bg = self.palette().panel_bg, .flags = .{ .bold = true } } });
        return;
    }
}

const Dimensions = struct {
    width: u16,
    height: u16,
};

const Appearance = struct {
    theme: data.ColorTheme,
    icons: data.icons.Theme = .unicode,
};

const GraphicsPlan = struct {
    toast_area: cellgrid.Rect = .{},
    sidebar_area: cellgrid.Rect = .{},
    focused_card: ?SidebarFocus = null,
    provider_marks: [core.max_agent_snapshot_entries]SidebarProviderPlacement = undefined,
    provider_mark_count: u8 = 0,
    icons: Plan = .{},
    attachments: client.Plan = .{},
    modal_area: cellgrid.Rect = .{},
    pill_labels: PresentationPlan = .{},
};
