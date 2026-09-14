//! Disposable native controls. The shared client remains the sole navigation owner.
const std = @import("std");
const client = @import("telar-client");
const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
const HitMap = @import("HitMap.zig");
const Action = @import("action.zig").Action;
const Regions = @import("Regions.zig");
const Bands = @import("Bands.zig");
const Sidebar = @import("Sidebar.zig");
const TopBar = @import("TopBar.zig");
const TabStrip = @import("TabStrip.zig");
const StatusBar = @import("StatusBar.zig");
const PaneDecorations = @import("PaneDecorations.zig");
const HitState = @import("HitState.zig");
const HomePrefix = @import("HomePrefix.zig");
const RingFades = @import("RingFades.zig");
const InputEvent = @import("../native/InputEvent.zig").InputEvent;
const GenericPresentedState = @import("../render/GenericPresentedState.zig").Type;
const Chrome = @This();

maps: GenericPresentedState(HitState) = .{},
sidebar: Sidebar = .{},
rings: RingFades = .{},
home: HomePrefix = .{},
hovered: ?Action = null,
gesture_button: ?u8 = null,
band_gesture: ?u8 = null,
sidebar_resize_active: bool = false,
revision: u64 = 0,

/// Paints after terminal leaves and before modal overlays. No borrowed model
/// pointer survives preparation; asynchronous consumers own only frame quads.
/// Example: `try chrome.paint(&canvas, projection);`
pub fn paint(chrome: *Chrome, canvas: *Canvas, projection: client.Projection) !void {
    const pending = chrome.maps.begin();
    try registerPanes(&pending.hits, projection);
    pending.regions = Regions.calculate(projection.host_size.cols, projection.host_size.rows, .{ .visible = projection.sidebar_visible, .preferred_width = projection.sidebar_width });
    pending.bands = Bands.resolve(canvas, pending.regions.workbench);
    var context: Context = .{ .canvas = canvas, .hits = &pending.hits, .bands = &pending.band_hits, .projection = &projection, .hovered = chrome.hovered };
    const top_bar: TopBar = .{ .context = &context, .bands = pending.bands, .home = chrome.home.slice(), .sidebar_visible = !pending.regions.sidebar.isEmpty() };
    try top_bar.paint();
    const strip: TabStrip = .{ .context = &context, .bands = pending.bands };
    try strip.paint();
    const status: StatusBar = .{ .context = &context, .area = pending.bands.status_bar };
    try status.paint();
    try chrome.sidebar.paint(&context, pending.regions.sidebar);
    const decorations: PaneDecorations = .{ .context = &context, .rings = &chrome.rings };
    try decorations.paint();
    chrome.maps.seal();
}

/// Publishes only the controls belonging to the host's completed frame token.
/// Example: `chrome.present(delivered);`.
pub fn present(chrome: *Chrome, delivered: bool) void {
    chrome.maps.present(delivered);
}

pub fn prepared(chrome: *const Chrome) *const HitState {
    return chrome.maps.prepared();
}

pub fn presented(chrome: *const Chrome) *const HitState {
    return chrome.maps.presented();
}

/// Advances local hover/scroll invalidation without changing pane geometry.
/// Example: `chrome.invalidate();`
pub fn invalidate(chrome: *Chrome) void {
    chrome.revision +%= 1;
}

/// Retains chrome gesture ownership through release, even outside its bounds.
/// Compare `revision` around this call to request a local repaint.
/// Example: `const command = chrome.pointer(mouse);`
pub fn pointer(chrome: *Chrome, event: client.Mouse) client.ViewInteractionCommand {
    const visible = chrome.presented();
    const action = visible.hits.at(.{ event.x, event.y });
    chrome.hover(action);
    if (chrome.gesture_button) |button| {
        if (event.kind == .drag or event.kind == .release) {
            if (event.button & 3 != button and event.button & 3 != 3) {
                return .{ .consumed = true };
            }

            const resize = chrome.sidebar_resize_active;
            if (event.kind == .release) {
                chrome.gesture_button = null;
                chrome.sidebar_resize_active = false;
                chrome.invalidate();
            }

            return .{ .consumed = true, .intent = if (resize) .{ .resize_sidebar = event.x +| 1 } else .none };
        }

        return .{ .consumed = true };
    }

    if (visible.regions.sidebar.contains(event.x, event.y)) {
        if (chrome.sidebar.wheel(event.kind)) {
            chrome.invalidate();
        }
    }

    if (action) |target| {
        if (target == .pane_content) {
            return .{ .intent = if (event.kind == .press) .{ .focus_pane = target.pane_content } else .none };
        }
    }

    const within_chrome = action != null or visible.regions.sidebar.contains(event.x, event.y);
    if (event.kind != .press or !within_chrome) {
        return .{ .consumed = within_chrome };
    }

    chrome.gesture_button = event.button & 3;
    const target = action orelse return .{ .consumed = true };
    if (target == .resize_sidebar) {
        chrome.sidebar_resize_active = event.button & 3 == 0;
        return .{ .consumed = true };
    }

    return .{ .intent = buttonIntent(target.intent, event.button & 3), .consumed = true };
}

/// Routes a native pointer sample that lands in a chrome band, outside the
/// cell grid. Returns null when no band and no band gesture owns the sample,
/// so the caller can map it to cells. A press acquires the gesture until
/// its release, like `pointer`.
/// Example: `if (chrome.bandPointer(event)) |command| return apply(command);`
pub fn bandPointer(chrome: *Chrome, event: InputEvent) ?client.ViewInteractionCommand {
    const visible = chrome.presented();
    const inside = visible.bands.contains(event.x, event.y);
    if (chrome.band_gesture) |button| {
        if (event.code == 2 or event.code == 3) {
            if (event.code == 2 and event.button & 3 == button) {
                chrome.band_gesture = null;
                chrome.invalidate();
            }

            return .{ .consumed = true };
        }

        return if (inside) .{ .consumed = true } else null;
    }

    if (!inside) {
        return null;
    }

    const action = visible.band_hits.at(.{ event.x, event.y });
    chrome.hover(action);
    if (event.code != 1) {
        return .{ .consumed = true };
    }

    const button: u8 = @intCast(event.button & 3);
    chrome.band_gesture = button;
    chrome.invalidate();
    const target = action orelse return .{ .consumed = true };
    return .{ .intent = buttonIntent(target.intent, button), .consumed = true };
}

/// The cursor a band point deserves, from the delivered band targets.
/// Example: `hover.assign(null, chrome.bandShape(event));`
pub fn bandShape(chrome: *const Chrome, event: InputEvent) @import("telar-core").PointerShape {
    const action = chrome.presented().band_hits.at(.{ event.x, event.y }) orelse return .default;
    return if (action == .intent and action.intent != .none) .pointer else .default;
}

fn buttonIntent(intent: client.Intent, button: u8) client.Intent {
    if (intent == .select_tab) {
        const tab_id = intent.select_tab;
        return switch (button) {
            0 => .{ .select_tab = tab_id },
            2 => .{ .rename_tab = tab_id },
            else => .none,
        };
    }

    return if (button != 0) .none else intent;
}

fn hover(chrome: *Chrome, action: ?Action) void {
    if (!std.meta.eql(action, chrome.hovered)) {
        chrome.hovered = action;
        chrome.invalidate();
    }
}

fn registerPanes(hits: *HitMap, projection: client.Projection) !void {
    const model = projection.model orelse return;
    var layout: client.LayoutSnapshot = .{};
    model.layout.snapshot(projection.geometry.area, &layout);
    for (layout.views()) |view| {
        try hits.add(.{ .area = view.content, .action = .{ .pane_content = view.pane_id } });
    }
}

/// Clears gestures when window focus is lost and no release can arrive.
/// Example: `chrome.cancelPointer();`
pub fn cancelPointer(chrome: *Chrome) void {
    if (chrome.gesture_button == null and chrome.band_gesture == null and chrome.hovered == null) {
        return;
    }

    chrome.gesture_button = null;
    chrome.band_gesture = null;
    chrome.sidebar_resize_active = false;
    chrome.hovered = null;
    chrome.invalidate();
}

/// Leaving the window clears hover while an acquired drag keeps its owner.
/// Example: `chrome.leavePointer();`
pub fn leavePointer(chrome: *Chrome) void {
    if (chrome.hovered != null) {
        chrome.hovered = null;
        chrome.invalidate();
    }
}
