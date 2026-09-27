//! Covers the workbench while the window cannot reach its runtime. The last
//! panes stay visible under a dim, and two centred lines say which machine
//! the window is reaching and, after a failure, what failed. Nothing is
//! drawn while the link is connected.
const std = @import("std");
const data = @import("model");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
const Label = @import("Label.zig");
const LinkStatus = @This();

/// How much of the terminal background covers the stale panes.
const dim_alpha: f32 = 0.6;
/// A line's height as a multiple of its text size.
const line_height_factor: f32 = 1.5;
/// Logical pixels between the two lines and around the text.
const line_gap: f32 = 6;
const inset: f32 = 24;
/// The longest headline, in bytes.
const max_headline_bytes = 320;

context: *const Context,

/// Example: `try status.draw(canvas);`
pub fn draw(self: LinkStatus, canvas: *Canvas) !void {
    const projection = self.context.projection;
    const link = &projection.model.runtime_link;
    if (link.phase == .connected) {
        return;
    }

    const area = canvas.rect(projection.geometry.area);
    if (area.width <= 0 or area.height <= 0) {
        return;
    }

    try canvas.dimAt(area, dim_alpha);

    var storage: [max_headline_bytes]u8 = undefined;
    const headline: Label = .{
        .text = headlineText(link, &storage),
        .color = canvas.theme.palette.text,
        .bold = true,
        .face = .sans,
        .size = .title,
    };
    const detail: ?Label = if (link.failure()) |failure| .{
        .text = failure,
        .color = canvas.theme.palette.subtext0,
        .face = .sans,
        .size = .body,
    } else null;

    const chrome = canvas.chrome;
    const line_height = @as(f32, @floatFromInt(chrome.text(.title) orelse canvas.metrics.pixel_height)) * line_height_factor;
    const lines: f32 = if (detail == null) 1 else 2;
    const block_height = lines * line_height + (lines - 1) * chrome.px(line_gap);
    var row: Rect = .{
        .x = area.x + chrome.px(inset),
        .y = area.y + @max(0, (area.height - block_height) / 2),
        .width = @max(0, area.width - 2 * chrome.px(inset)),
        .height = line_height,
    };

    try centred(canvas, row, headline);
    if (detail) |label| {
        row.y += line_height + chrome.px(line_gap);
        try centred(canvas, row, label);
    }
}

fn centred(canvas: *Canvas, row: Rect, label: Label) !void {
    const width = @min(try canvas.measure(label), row.width);
    _ = try canvas.textAt(.{
        .x = row.x + (row.width - width) / 2,
        .y = row.y,
        .width = width,
        .height = row.height,
    }, label);
}

fn headlineText(link: *const data.RuntimeLink, buffer: []u8) []const u8 {
    const target = link.target();
    return switch (link.phase) {
        .connected => "",
        .connecting => if (link.sessions == 0 and link.attempt == 0)
            std.fmt.bufPrint(buffer, "Connecting to {s}…", .{target}) catch "Connecting…"
        else
            std.fmt.bufPrint(buffer, "Reconnecting to {s} (attempt {d})…", .{ target, link.attempt + 1 }) catch "Reconnecting…",
        .lost => std.fmt.bufPrint(buffer, "{s} is unreachable; trying again shortly", .{target}) catch "The runtime is unreachable",
    };
}

test "the headline names the machine and the attempt" {
    var link: data.RuntimeLink = .{};
    link.name("dev@box");
    var buffer: [max_headline_bytes]u8 = undefined;

    try std.testing.expectEqualStrings("Connecting to dev@box…", headlineText(&link, &buffer));

    link.phase = .lost;
    try std.testing.expectEqualStrings("dev@box is unreachable; trying again shortly", headlineText(&link, &buffer));

    link.phase = .connecting;
    link.attempt = 2;
    try std.testing.expectEqualStrings("Reconnecting to dev@box (attempt 3)…", headlineText(&link, &buffer));
}
