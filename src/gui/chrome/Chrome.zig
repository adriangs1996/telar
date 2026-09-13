//! Disposable native controls. The shared client remains the sole navigation owner.
const std = @import("std");
const client = @import("telar-client");
const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
const HitMap = @import("HitMap.zig");
const Action = @import("action.zig").Action;
const Regions = @import("Regions.zig");
const Sidebar = @import("Sidebar.zig");
const Bars = @import("Bars.zig");
const PaneDecorations = @import("PaneDecorations.zig");
const Chrome = @This();

regions: Regions = Regions.calculate(0, 0, .{ .visible = false, .preferred_width = client.default_width }),
hits: HitMap = .{},
sidebar: Sidebar = .{},
hovered: ?Action = null,
gesture_button: ?u8 = null,
sidebar_resize_active: bool = false,
revision: u64 = 0,

/// Paints after terminal leaves and before modal overlays. No borrowed model
/// pointer survives preparation; asynchronous consumers own only frame quads.
/// Example: `try chrome.paint(&canvas, projection);`
pub fn paint(chrome: *Chrome, canvas: *Canvas, projection: client.Projection) !void {
    chrome.hits.len = 0;
    try chrome.registerPanes(projection);
    chrome.regions = Regions.calculate(projection.host_size.cols, projection.host_size.rows, .{ .visible = projection.sidebar_visible, .preferred_width = projection.sidebar_width });
    var context: Context = .{ .canvas = canvas, .hits = &chrome.hits, .projection = &projection, .hovered = chrome.hovered };
    const bars: Bars = .{ .context = &context, .regions = chrome.regions };
    try bars.paint();
    try chrome.sidebar.paint(&context, chrome.regions.sidebar);
    const decorations: PaneDecorations = .{ .context = &context };
    try decorations.paint();
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
    const action = chrome.hits.at(.{ event.x, event.y });
    if (!std.meta.eql(action, chrome.hovered)) {
        chrome.hovered = action;
        chrome.invalidate();
    }

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

    if (chrome.regions.sidebar.contains(event.x, event.y)) {
        if (chrome.sidebar.wheel(event.kind)) {
            chrome.invalidate();
        }
    }

    if (action) |target| {
        if (target == .pane_content) {
            return .{ .intent = if (event.kind == .press) .{ .focus_pane = target.pane_content } else .none };
        }
    }

    const within_chrome = action != null or chrome.regions.sidebar.contains(event.x, event.y) or chrome.regions.top.contains(event.x, event.y) or chrome.regions.bottom.contains(event.x, event.y);
    if (event.kind != .press or !within_chrome) {
        return .{ .consumed = within_chrome };
    }

    chrome.gesture_button = event.button & 3;
    const target = action orelse return .{ .consumed = true };
    if (target == .resize_sidebar) {
        chrome.sidebar_resize_active = event.button & 3 == 0;
        return .{ .consumed = true };
    }

    var intent = target.intent;
    if (intent == .select_tab) {
        const tab_id = intent.select_tab;
        intent = switch (event.button & 3) {
            0 => .{ .select_tab = tab_id },
            2 => .{ .rename_tab = tab_id },
            else => .none,
        };
    } else if (event.button & 3 != 0) {
        intent = .none;
    }

    return .{ .intent = intent, .consumed = true };
}

fn registerPanes(chrome: *Chrome, projection: client.Projection) !void {
    const model = projection.model orelse return;
    var layout: client.LayoutSnapshot = .{};
    model.layout.snapshot(projection.geometry.area, &layout);
    for (layout.views()) |view| {
        try chrome.hits.add(.{ .area = view.content, .action = .{ .pane_content = view.pane_id } });
    }
}

/// Clears gestures when window focus is lost and no release can arrive.
/// Example: `chrome.cancelPointer();`
pub fn cancelPointer(chrome: *Chrome) void {
    if (chrome.gesture_button == null and chrome.hovered == null) {
        return;
    }

    chrome.gesture_button = null;
    chrome.sidebar_resize_active = false;
    chrome.hovered = null;
    chrome.invalidate();
}
