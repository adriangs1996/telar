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
const PaneHeader = @This();

context: *Context,
pane: *const client.Pane,
agent: ?*const client.Agent,
index: u16,

/// Paints into the pixel rectangle of the border row.
/// Example: `try header.paint(canvas.rect(view.outer.row(0)));`
pub fn paint(header: PaneHeader, row: Rect) !void {
    const canvas = header.context.canvas;
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
    x += try canvas.textPixels(.{ .x = x, .y = band.y, .width = @max(0, end - x), .height = band.height }, .{ .text = index_text, .color = palette.text, .bold = true, .face = .sans });
    x += chrome.px(6);
    const name = header.pane.foregroundName();
    var chip_storage: [32]u8 = undefined;
    const chip_text = header.chip(&chip_storage);
    var chip_width: f32 = 0;
    if (chip_text.len != 0) {
        chip_width = @ceil(try canvas.measure(.{ .text = chip_text, .face = .sans }) + 2 * chrome.px(6));
    }

    const name_width = @max(0, end - x - (if (chip_width != 0) chip_width + chrome.px(8) else 0));
    _ = try canvas.textPixels(.{ .x = x, .y = band.y, .width = name_width, .height = band.height }, .{ .text = if (name.len == 0) "shell" else name, .color = palette.subtext0, .face = .sans });
    if (chip_width == 0 or chip_width > band.width) {
        return;
    }

    const chip_height = @min(band.height, chrome.px(16));
    const chip_bounds: Rect = .{ .x = end - chip_width, .y = band.y + @floor((band.height - chip_height) / 2), .width = chip_width, .height = chip_height };
    try canvas.fillRoundedPixels(chip_bounds, .{ .radius = chrome.px(4), .color = attention.statusColor(palette, header.agent.?.status) });
    _ = try canvas.textPixels(.{ .x = chip_bounds.x + chrome.px(6), .y = band.y, .width = chip_width - 2 * chrome.px(6), .height = band.height }, .{ .text = chip_text, .color = palette.surface_dim, .face = .sans });
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
        .working => workingLabel(storage, agent.statusAgeSeconds()),
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
