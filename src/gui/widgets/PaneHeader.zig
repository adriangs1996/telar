//! The band inside a pane's top edge: index in bold, the program name and,
//! when an agent lives in the pane, a status chip in that agent's colour.
//! The band is the pane's border row, so it is as tall as one cell and never
//! covers a terminal row; `ChromeMetrics.pane_header` caps the text band
//! inside it. The cwd no longer appears here; the top bar shows location.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Context = @import("Context.zig");
const Rect = @import("../render/Rect.zig");
const attention = @import("attention.zig");
const Canvas = @import("Canvas.zig");
const PaneHeader = @This();

context: *const Context,
pane: *const client.Pane,
agent: ?*const client.Agent,
index: u16,
area: Rect,

/// Paints into the pixel rectangle of the border row.
/// Example: `try header.draw(canvas);`
pub fn draw(header: PaneHeader, canvas: *Canvas) !void {
    const row = header.area;
    const palette = canvas.theme.palette;
    const chrome = canvas.chrome;
    const band_height = @min(row.height, @as(f32, @floatFromInt(chrome.pane_header)));
    if (band_height <= 0 or row.width <= 0) {
        return;
    }

    const band: Rect = .{ .x = row.x + chrome.px(8), .y = row.y, .width = @max(0, row.width - 2 * chrome.px(8)), .height = band_height };
    var index_storage: [8]u8 = undefined;
    const index_text = std.fmt.bufPrint(&index_storage, "{d}", .{header.index}) catch unreachable;
    var x = band.x;
    const end = band.x + band.width;
    x += try canvas.textAt(.{ .x = x, .y = band.y, .width = @max(0, end - x), .height = band.height }, .{ .text = index_text, .color = palette.text, .bold = true, .face = .sans, .size = .body });
    x += chrome.px(6);
    const name = header.pane.foregroundName();
    var chip_storage: [32]u8 = undefined;
    const chip_text = header.chip(&chip_storage);
    var chip_width: f32 = 0;
    if (chip_text.len != 0) {
        chip_width = @ceil(try canvas.measure(.{ .text = chip_text, .face = .sans, .size = .body }) + 2 * chrome.px(6));
    }

    const name_width = @max(0, end - x - (if (chip_width != 0) chip_width + chrome.px(8) else 0));
    _ = try canvas.textAt(.{ .x = x, .y = band.y, .width = name_width, .height = band.height }, .{ .text = if (name.len == 0) "shell" else name, .color = palette.subtext0, .face = .sans, .size = .body });
    if (chip_width == 0 or chip_width > band.width) {
        return;
    }

    const chip_height = @min(band.height, chrome.px(16));
    const chip_bounds: Rect = .{ .x = end - chip_width, .y = band.y + @floor((band.height - chip_height) / 2), .width = chip_width, .height = chip_height };
    try canvas.fillRoundedAt(chip_bounds, .{ .radius = chrome.px(4), .color = attention.statusColor(palette, header.agent.?.status) });
    _ = try canvas.textAt(.{ .x = chip_bounds.x + chrome.px(6), .y = band.y, .width = chip_width - 2 * chrome.px(6), .height = band.height }, .{ .text = chip_text, .color = palette.surface_dim, .face = .sans, .size = .body });
}

fn chip(header: PaneHeader, storage: []u8) []const u8 {
    const agent = header.agent orelse return "";
    return switch (agent.status) {
        .blocked => switch (agent.blockedReason()) {
            .permission => "permission",
            .question => "question",
            .plan => "plan",
            .none, .other => "blocked",
        },
        .working => workingLabel(storage, header.context.statusAge(agent)),
        .done => "done",
        .failed => "failed",
        .ready => "ready",
        .unknown => "",
    };
}

fn workingLabel(storage: []u8, seconds: u32) []const u8 {
    var age_storage: [16]u8 = undefined;
    const age = attention.ageLabel(&age_storage, seconds);
    return std.fmt.bufPrint(storage, "working {s}", .{age}) catch "working";
}

test "pane header duration advances with the card clock between runtime reports" {
    var agents: client.AgentSnapshot = .{};
    const input: client.AgentInput = .{ .key = .{ .pane_id = @enumFromInt(1), .pane_generation = 1 }, .location = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) }, .pane_index = 1, .provider = .codex, .status = .working, .status_age_s = 5 };
    _ = try agents.replace(.{ .revision = 1, .agents = &.{input} });
    var ages: @import("AgentAges.zig") = .{};
    const context: Context = .{ .hits = undefined, .bands = undefined, .projection = undefined, .hovered = null, .ages = &ages };
    const header: PaneHeader = .{ .context = &context, .pane = undefined, .agent = &agents.slice()[0], .index = 1, .area = .{ .x = 0, .y = 0, .width = 0, .height = 0 } };
    var storage: [32]u8 = undefined;
    ages.observe(&agents, 100 * std.time.ns_per_s);
    try std.testing.expectEqualStrings("working 5s", header.chip(&storage));
    ages.observe(&agents, 101 * std.time.ns_per_s);
    try std.testing.expectEqualStrings("working 6s", header.chip(&storage));

    _ = try agents.replace(.{ .revision = 2, .agents = &.{input} });
    ages.observe(&agents, 101 * std.time.ns_per_s);
    try std.testing.expectEqualStrings("working 6s", header.chip(&storage));
}
