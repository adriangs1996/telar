//! Disposable native controls. The shared client remains the sole navigation owner.
const std = @import("std");
const client = @import("telar-client");
const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
const HitMap = @import("HitMap.zig");
const Action = @import("action.zig").Action;
const Bands = @import("Bands.zig");
const SidebarState = @import("SidebarState.zig");
const AgentAges = @import("AgentAges.zig");
const HitState = @import("HitState.zig");
const RingFades = @import("RingFades.zig");
const Favicons = @import("Favicons.zig");
const PointerEvent = @import("../input/PointerEvent.zig");
const BandCommand = @import("BandCommand.zig");
const GenericPresentedState = @import("../render/GenericPresentedState.zig").Type;
const Chrome = @This();

maps: GenericPresentedState(HitState) = .{},
sidebar: SidebarState = .{},
ages: AgentAges = .{},
rings: RingFades = .{},
progress: @import("ProgressMotions.zig") = .{},
favicons: Favicons = .{},
hovered: ?Action = null,
gesture_button: ?u8 = null,
band_gesture: ?u8 = null,
sidebar_resize_active: bool = false,
revision: u64 = 0,
/// Monotonic time the driver stamps before each preparation.
now_ns: u64 = 0,
animation: @import("../animation/FrameClock.zig") = .{},

/// Starts the pending hit map and returns a context borrowing only the caller's
/// projection and persistent chrome state. Keep it alive until drawing ends.
/// Example: `composition.context = try chrome.begin(canvas, projection);`
pub fn begin(chrome: *Chrome, canvas: *Canvas, projection: *const client.Projection) !Context {
    const pending = chrome.maps.begin();
    try registerPanes(&pending.hits, projection.*);
    pending.bands = Bands.resolve(canvas);
    chrome.ages.observe(projection.agents, chrome.now_ns);
    chrome.progress.begin();
    return .{ .hits = &pending.hits, .bands = &pending.band_hits, .projection = projection, .hovered = chrome.hovered, .ages = &chrome.ages, .favicons = &chrome.favicons, .progress = &chrome.progress };
}

/// Appends the permanent chrome in painter order without emitting quads.
/// The caller owns the context through draw. Example: `try chrome.compose(&context, &widgets);`
pub fn compose(chrome: *Chrome, context: *Context, widgets: anytype) !void {
    const bands = chrome.maps.preparing().bands;
    try widgets.append(.{ .top_bar = .{ .context = context, .area = bands.top_bar, .sidebar_visible = bands.sidebar.width > 0 } });
    try widgets.append(.{ .status = .{ .context = context, .area = bands.status_bar } });
    try widgets.append(.{ .sidebar = .{ .state = &chrome.sidebar, .context = context, .area = bands.sidebar } });
    try widgets.append(.{ .panes = .{ .context = context, .rings = &chrome.rings } });
}

/// Seals hit records only after every composed widget has drawn successfully.
/// Example: `chrome.seal();`
pub fn seal(chrome: *Chrome) void {
    chrome.progress.end();
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

/// Keeps existing hover paint and native cursor hints in sync with widgets.
/// Example: `chrome.widgetPointer(pointer, resizing);`
pub fn widgetPointer(chrome: *Chrome, event: PointerEvent, resizing: bool) void {
    chrome.sidebar_resize_active = resizing;
    if (event.kind == .leave) {
        chrome.leavePointer();
    } else {
        chrome.hover(chrome.presented().band_hits.at(.{ event.x, event.y }));
    }
}

/// Retains a cell-control gesture through release, even outside its
/// bounds. Compare `revision` around this call to request a local repaint.
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

            if (event.kind == .release) {
                chrome.gesture_button = null;
                chrome.invalidate();
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

    chrome.gesture_button = event.button & 3;
    return .{ .intent = buttonIntent(target.intent, event.button & 3), .consumed = true };
}

/// Routes a native pointer sample that lands in a chrome band, outside the
/// cell grid. Returns null when no band and no band gesture owns the sample,
/// so the caller can map it to cells. A press acquires the gesture until
/// its release; a press on the sidebar's resize handle turns the drag into
/// widths, and the wheel over the sidebar scrolls its cards.
/// Example: `if (chrome.bandPointer(event)) |command| return apply(command);`
pub fn bandPointer(chrome: *Chrome, event: PointerEvent) ?BandCommand {
    const visible = chrome.presented();
    const inside = visible.bands.contains(event.x, event.y);
    if (chrome.band_gesture) |button| {
        if (event.kind == .release or event.kind == .drag) {
            const resize = chrome.sidebar_resize_active;
            if (event.kind == .release and @intFromEnum(event.button) == button) {
                chrome.band_gesture = null;
                chrome.sidebar_resize_active = false;
                chrome.invalidate();
            }

            return .{ .interaction = .{ .consumed = true }, .sidebar_width = if (resize) edgeWidth(event.x) else null };
        }

        return if (inside) .{ .interaction = .{ .consumed = true } } else null;
    }

    if (!inside) {
        return null;
    }

    const action = visible.band_hits.at(.{ event.x, event.y });
    chrome.hover(action);
    if (event.kind == .scroll_up or event.kind == .scroll_down) {
        if (Bands.within(visible.bands.sidebar, event.x, event.y) and chrome.sidebar.wheel(if (event.kind == .scroll_up) .scroll_up else .scroll_down)) {
            chrome.invalidate();
        }

        return .{ .interaction = .{ .consumed = true } };
    }

    if (event.kind != .press) {
        return .{ .interaction = .{ .consumed = true } };
    }

    const button: u8 = @intFromEnum(event.button);
    chrome.band_gesture = button;
    chrome.invalidate();
    const target = action orelse return .{ .interaction = .{ .consumed = true } };
    if (target == .resize_sidebar) {
        chrome.sidebar_resize_active = button == 0;
        return .{ .interaction = .{ .consumed = true } };
    }

    return .{ .interaction = .{ .intent = buttonIntent(target.intent, button), .consumed = true } };
}

/// The cursor a band point deserves, from the delivered band targets: a
/// hand over a control and the horizontal resize cursor over the sidebar
/// edge or while it is being dragged.
/// Example: `hover.assign(null, chrome.bandShape(event));`
pub fn bandShape(chrome: *const Chrome, event: PointerEvent) @import("telar-core").PointerShape {
    if (chrome.sidebar_resize_active) {
        return .col_resize;
    }

    const action = chrome.presented().band_hits.at(.{ event.x, event.y }) orelse return .default;
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
