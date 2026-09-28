//! Disposable native controls. The shared client remains the sole navigation owner.
const keyinput = @import("keyinput");
const SidebarRegions = @import("SidebarRegions.zig");
const core = @import("telar-core");
const action_module = @import("action.zig");
const std = @import("std");
const client = @import("telar-client");
const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
const HitMap = @import("HitMap.zig");
const Bands = @import("Bands.zig");
const SidebarState = @import("SidebarState.zig");
const AgentAges = @import("AgentAges.zig");
const HitState = @import("HitState.zig");
const RingFades = @import("RingFades.zig");
const Favicons = @import("Favicons.zig");
const PointerEvent = @import("../input/PointerEvent.zig");
const BandCommand = @import("BandCommand.zig");
const GenericPresentedState = @import("../render/GenericPresentedState.zig").Type;
const ProgressMotions = @import("ProgressMotions.zig");
const animate = @import("animate");
const FrameClock = animate.FrameClock;
const PixelScroll = @import("PixelScroll.zig");
const Chrome = @This();

maps: GenericPresentedState(HitState) = .{},
sidebar: SidebarState = .{},
ages: AgentAges = .{},
rings: RingFades = .{},
progress: ProgressMotions = .{},
favicons: Favicons = .{},
hovered: ?action_module.Action = null,
gesture_button: ?u8 = null,
band_gesture: ?u8 = null,
sidebar_resize_active: bool = false,
/// Whether the pointer rests on the delivered tab strip.
pointer_in_tabs: bool = false,
/// The tab the strip's widths were last laid out around. While the pointer
/// rests on the strip this tab keeps the room of the selected one, so a click
/// changes the selection without moving tabs under the pointer.
tab_anchor: ?core.TabId = null,
revision: u64 = 0,
/// Monotonic time the driver stamps before each preparation.
now_ns: u64 = 0,
animation: FrameClock = .{},

/// Starts the pending hit map and returns a context borrowing only the caller's
/// projection and persistent chrome state. Keep it alive until drawing ends.
/// Example: `composition.context = try chrome.begin(canvas, projection);`
pub fn begin(self: *Chrome, canvas: *Canvas, projection: *const client.Projection) !Context {
    const pending = self.maps.begin();
    try registerPanes(&pending.hits, projection.*);
    pending.bands = Bands.resolve(canvas);
    pending.sidebar_regions = if (canvas.sidebar.expanded()) try SidebarRegions.resolve(canvas, pending.bands.sidebar, projection.workspaces.project_count) else .{};
    pending.tab_strip = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    self.ages.observe(projection.agents, self.now_ns);
    self.progress.begin();
    const context: Context = .{ .hits = &pending.hits, .bands = &pending.band_hits, .projection = projection, .hovered = self.hovered, .presented_workspace = self.presented().workspace, .ages = &self.ages, .favicons = &self.favicons, .progress = &self.progress, .sidebar_regions = &pending.sidebar_regions, .tab_strip = &pending.tab_strip, .pointer_in_tabs = self.pointer_in_tabs, .tab_anchor = &self.tab_anchor, .bar_panel = &pending.bar_panel, .bar_overflow = &pending.bar_overflow };
    pending.workspace = context.workspaceId();
    return context;
}

/// Appends the permanent chrome in painter order without emitting quads.
/// The caller owns the context through draw. Example: `try chrome.compose(&context, &widgets);`
pub fn compose(self: *Chrome, context: *Context, widgets: anytype) !void {
    const bands = self.maps.preparing().bands;
    try widgets.append(.{ .top_bar = .{ .context = context, .area = bands.top_bar } });
    try widgets.append(.{ .status = .{ .context = context, .area = bands.status_bar } });
    if (bands.rail) {
        self.sidebar.hide();
        try widgets.append(.{ .rail = .{ .context = context, .area = bands.sidebar } });
    } else {
        try widgets.append(.{ .sidebar = .{ .state = &self.sidebar, .context = context, .area = bands.sidebar } });
    }

    try widgets.append(.{ .panes = .{ .context = context, .rings = &self.rings } });
    try widgets.append(.{ .rail_tooltip = .{ .context = context, .area = bands.sidebar } });
    try widgets.append(.{ .bar_overlay = .{ .context = context, .area = bands.status_bar } });
}

/// Seals hit records only after every composed widget has drawn successfully.
/// Example: `chrome.seal();`
pub fn seal(self: *Chrome) void {
    self.progress.end();
    self.maps.seal();
}

/// Publishes only the controls belonging to the host's completed frame token.
/// Example: `chrome.present(delivered);`.
pub fn present(self: *Chrome, delivered: bool) void {
    self.maps.present(delivered);
}

pub fn prepared(self: *const Chrome) *const HitState {
    return self.maps.prepared();
}

pub fn presented(self: *const Chrome) *const HitState {
    return self.maps.presented();
}

/// Advances local hover/scroll invalidation without changing pane geometry.
/// Example: `chrome.invalidate();`
pub fn invalidate(self: *Chrome) void {
    self.revision +%= 1;
}

/// Keeps existing hover paint and native cursor hints in sync with widgets.
/// Example: `chrome.widgetPointer(pointer, resizing);`
pub fn widgetPointer(self: *Chrome, event: PointerEvent, resizing: bool) void {
    self.sidebar_resize_active = resizing;
    if (event.kind == .leave) {
        self.leavePointer();
    } else {
        self.hover(self.presented().band_hits.at(.{ event.x, event.y }));
    }
}

/// Retains a cell-control gesture through release, even outside its
/// bounds. Compare `revision` around this call to request a local repaint.
/// Example: `const command = chrome.pointer(mouse);`
pub fn pointer(self: *Chrome, event: keyinput.Mouse) client.ViewInteractionCommand {
    const visible = self.presented();
    const action = visible.hits.at(.{ event.x, event.y });
    self.hover(action);
    if (self.gesture_button) |button| {
        if (event.kind == .drag or event.kind == .release) {
            if (event.button & 3 != button and event.button & 3 != 3) {
                return .{ .consumed = true };
            }

            if (event.kind == .release) {
                self.gesture_button = null;
                self.invalidate();
            }
        }

        return .{ .consumed = true };
    }

    const target = action orelse return .{};
    if (target == .pane_content) {
        return .{ .intent = if (event.kind == .press) .{ .focus_pane = target.pane_content } else .none };
    }

    if (event.kind != .press) {
        return .{ .consumed = true };
    }

    self.gesture_button = event.button & 3;
    return .{ .intent = buttonIntent(target.intent, event.button & 3), .consumed = true };
}

/// Routes a native pointer sample that lands in a chrome band or pixel target.
/// Returns null when no target, band or band gesture owns the sample,
/// so the caller can map it to cells. A press acquires the gesture until
/// its release; a press on the sidebar's resize handle turns the drag into
/// widths, and the wheel over the sidebar scrolls its cards.
/// Example: `if (chrome.bandPointer(event)) |command| return apply(command);`
pub fn bandPointer(self: *Chrome, event: PointerEvent) ?BandCommand {
    const visible = self.presented();
    self.trackTabs(Bands.within(visible.tab_strip, event.x, event.y));
    const action = visible.band_hits.at(.{ event.x, event.y });
    const panel_open = visible.bar_panel.width > 0;
    const in_panel = panel_open and Bands.within(visible.bar_panel, event.x, event.y);
    const inside = action != null or in_panel or visible.bands.contains(event.x, event.y);
    if (self.band_gesture) |button| {
        if (event.kind == .release or event.kind == .drag) {
            const resize = self.sidebar_resize_active;
            if (event.kind == .release and @intFromEnum(event.button) == button) {
                self.band_gesture = null;
                self.sidebar_resize_active = false;
                self.invalidate();
            }

            return .{ .interaction = .{ .consumed = true }, .sidebar_width = if (resize) edgeWidth(event.x) else null };
        }

        return if (inside) .{ .interaction = .{ .consumed = true } } else null;
    }

    if (!inside) {
        // A press on the panes while a bar panel is open only dismisses it.
        if (panel_open and event.kind == .press) {
            self.hover(null);
            return .{ .interaction = .{ .intent = .close_panel, .consumed = true } };
        }

        return null;
    }

    self.hover(action);
    if (event.kind == .scroll_up or event.kind == .scroll_down) {
        if (self.sidebarScrollAt(.{ event.x, event.y })) |scroll| {
            if (scroll.wheel(if (event.kind == .scroll_up) .scroll_up else .scroll_down)) {
                self.invalidate();
            }
        }

        return .{ .interaction = .{ .consumed = true } };
    }

    if (event.kind != .press) {
        return .{ .interaction = .{ .consumed = true } };
    }

    const button: u8 = @intFromEnum(event.button);
    self.band_gesture = button;
    self.invalidate();
    const target = action orelse return .{ .interaction = .{ .consumed = true } };
    if (target == .resize_sidebar) {
        self.sidebar_resize_active = button == 0;
        return .{ .interaction = .{ .consumed = true } };
    }

    return .{ .interaction = .{ .intent = buttonIntent(target.intent, button), .consumed = true } };
}

/// Selects a scroll owner using only the completed frame's list viewports.
/// Example: `const scroll = chrome.sidebarScrollAt(point) orelse return;`
pub fn sidebarScrollAt(self: *Chrome, point: [2]f64) ?*PixelScroll {
    const list = self.presented().sidebar_regions.at(point) orelse return null;
    return switch (list) {
        .projects => &self.sidebar.projects,
        .agents => &self.sidebar.agents,
    };
}

/// The cursor a band point deserves, from the delivered band targets: a
/// hand over a control and the horizontal resize cursor over the sidebar
/// edge or while it is being dragged.
/// Example: `hover.assign(null, chrome.bandShape(event));`
pub fn bandShape(self: *const Chrome, event: PointerEvent) core.PointerShape {
    if (self.sidebar_resize_active) {
        return .col_resize;
    }

    const action = self.presented().band_hits.at(.{ event.x, event.y }) orelse return .default;
    return switch (action) {
        .resize_sidebar => .col_resize,
        .intent => |intent| if (intent != .none) .pointer else .default,
        .pane_content => .default,
    };
}

// The edge line is the band's last pixel column, so the width that puts it
// under the pointer is the pointer column plus one.
fn edgeWidth(x: f64) u32 {
    return @intFromFloat(@max(1, @min(65535, @floor(x) + 1)));
}

fn buttonIntent(intent: client.Intent, button: u8) client.Intent {
    return switch (button) {
        0 => intent,
        2 => client.secondaryIntent(intent),
        else => .none,
    };
}

// Entering or leaving the strip relayouts it: inside, the widths hold still;
// outside, they follow the selection again.
fn trackTabs(self: *Chrome, inside: bool) void {
    if (inside != self.pointer_in_tabs) {
        self.pointer_in_tabs = inside;
        self.invalidate();
    }
}

fn hover(self: *Chrome, action: ?action_module.Action) void {
    if (!std.meta.eql(action, self.hovered)) {
        self.hovered = action;
        self.invalidate();
    }
}

fn registerPanes(hits: *HitMap, projection: client.Projection) !void {
    const layout = projection.layout orelse return;
    for (layout.views()) |view| {
        try hits.add(.{ .area = view.content, .action = .{ .pane_content = view.pane_id } });
    }
}

/// Clears gestures when window focus is lost and no release can arrive.
/// Example: `chrome.cancelPointer();`
pub fn cancelPointer(self: *Chrome) void {
    if (self.gesture_button == null and self.band_gesture == null and self.hovered == null and !self.pointer_in_tabs) {
        return;
    }

    self.pointer_in_tabs = false;
    self.gesture_button = null;
    self.band_gesture = null;
    self.sidebar_resize_active = false;
    self.hovered = null;
    self.invalidate();
}

/// Leaving the window clears hover while an acquired drag keeps its owner.
/// Example: `chrome.leavePointer();`
pub fn leavePointer(self: *Chrome) void {
    self.trackTabs(false);
    if (self.hovered != null) {
        self.hovered = null;
        self.invalidate();
    }
}
