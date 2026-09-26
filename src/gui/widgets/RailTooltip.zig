//! The name of the workspace under the pointer in the rail, beside its mark
//! and above the panes, with what it runs: agents waiting for the person,
//! else its agents, else its tabs. It paints only; the mark owns the target.
const std = @import("std");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const attention = @import("attention.zig");
const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
const Label = @import("Label.zig");
const WorkspaceLoad = @import("WorkspaceLoad.zig");
const RailTooltip = @This();

const offset: f32 = 8;
const height: f32 = 28;
const padding: f32 = 10;
const spacing: f32 = 8;
const radius: f32 = 8;
const shadow_layers = 3;
const shadow_spread: f32 = 3;
const shadow_alpha: f32 = 0.08;

context: *const Context,
/// The rail's band; the tooltip starts past its right edge.
area: Rect,

/// Example: `try (RailTooltip{ .context = context, .area = bands.sidebar }).draw(canvas);`
pub fn draw(self: RailTooltip, canvas: *Canvas) !void {
    if (!canvas.sidebar.rail or self.area.width <= 0) {
        return;
    }

    const hovered = self.context.hovered orelse return;
    if (hovered != .intent or hovered.intent != .select_workspace) {
        return;
    }

    const id = hovered.intent.select_workspace;
    const hit = self.context.bands.find(hovered.intent) orelse return;
    if (hit.area.x >= self.area.x + self.area.width) {
        return;
    }

    const projection = self.context.projection;
    const index = projection.workspaces.indexOf(id) orelse return;
    const palette = canvas.theme.palette;
    const chrome = canvas.chrome;
    const name: Label = .{ .text = projection.workspaces.nameAt(index), .color = palette.text, .bold = true, .face = .sans, .size = .body };
    var storage: [32]u8 = undefined;
    const detail: Label = .{ .text = summary(&storage, attention.workspaceLoad(projection, id), projection.workspaces.tabCountAt(index)), .color = palette.subtext0, .face = .sans, .size = .small };
    const name_width = try canvas.measure(name);
    const detail_width = try canvas.measure(detail);
    const box_height = chrome.px(height);
    const viewport_width: f32 = @floatFromInt(canvas.viewport[0]);
    const x = self.area.x + self.area.width + chrome.px(offset);
    const bounds: Rect = .{
        .x = x,
        .y = hit.area.y + (hit.area.height - box_height) / 2,
        .width = @max(0, @min(name_width + detail_width + 2 * chrome.px(padding) + chrome.px(spacing), viewport_width - x - chrome.px(offset))),
        .height = box_height,
    };
    if (bounds.width <= 0) {
        return;
    }

    const first = canvas.quads.items().len;
    for (0..shadow_layers) |layer| {
        const spread = chrome.px(shadow_spread) * @as(f32, @floatFromInt(shadow_layers - layer));
        try canvas.quads.pushRounded(.{ .x = bounds.x - spread, .y = bounds.y - spread + chrome.px(2), .width = bounds.width + 2 * spread, .height = bounds.height + 2 * spread }, .{ .fill = .{ .r = 0, .g = 0, .b = 0, .a = shadow_alpha }, .radius = chrome.px(radius) + spread });
    }

    try canvas.fillRoundedAt(bounds, .{ .radius = chrome.px(radius), .color = canvas.covering(palette.surface0) });
    try canvas.ringAt(bounds, .{ .color = palette.surface1, .width = chrome.px(1), .radius = chrome.px(radius) });
    const content: Rect = .{ .x = bounds.x + chrome.px(padding), .y = bounds.y, .width = @max(0, bounds.width - 2 * chrome.px(padding)), .height = bounds.height };
    const painted = try canvas.textAt(content, name);
    const detail_x = content.x + painted + chrome.px(spacing);
    _ = try canvas.textAt(.{ .x = detail_x, .y = content.y, .width = @max(0, content.x + content.width - detail_x), .height = content.height }, detail);
    canvas.quads.clipFrom(first, .{ .x = 0, .y = 0, .width = viewport_width, .height = @floatFromInt(canvas.viewport[1]) });
}

fn summary(storage: []u8, load: WorkspaceLoad, tabs: u16) []const u8 {
    if (load.waiting > 0) {
        return std.fmt.bufPrint(storage, "{d} waiting", .{load.waiting}) catch "";
    }

    if (load.agents > 0) {
        return std.fmt.bufPrint(storage, "{d} {s}", .{ load.agents, if (load.agents == 1) "agent" else "agents" }) catch "";
    }

    return std.fmt.bufPrint(storage, "{d} {s}", .{ tabs, if (tabs == 1) "tab" else "tabs" }) catch "";
}

test "the summary prefers waiting agents, then agents, then tabs" {
    var storage: [32]u8 = undefined;
    const waiting: WorkspaceLoad = .{
        .agents = 3,
        .waiting = 2,
    };
    const working: WorkspaceLoad = .{
        .agents = 1,
    };

    try std.testing.expectEqualStrings("2 waiting", summary(&storage, waiting, 4));
    try std.testing.expectEqualStrings("1 agent", summary(&storage, working, 4));
    try std.testing.expectEqualStrings("1 tab", summary(&storage, .{}, 1));
}
