//! The band inside a pane's top edge: index in bold, the program name and,
//! when an agent lives in the pane, a status chip in that agent's colour.
//! The band is the pane's border row, so it is as tall as one cell and never
//! covers a terminal row; `ChromeMetrics.pane_header` caps the text band
//! inside it. The cwd no longer appears here; the top bar shows location.
const data = @import("model");
const std = @import("std");
const Context = @import("Context.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const attention = @import("attention.zig");
const Canvas = @import("Canvas.zig");
const PaneProgress = @import("PaneProgress.zig");
const ChangeReviewButton = @import("ChangeReviewButton.zig");
const StatusChip = @import("StatusChip.zig");
const PaneHeader = @This();

context: *const Context,
pane: *const data.Pane,
agent: ?*const data.Agent,
index: u16,
area: Rect,

/// Paints into the pixel rectangle of the border row.
/// Example: `try header.draw(canvas);`
pub fn draw(self: PaneHeader, canvas: *Canvas) !void {
    const row = self.area;
    const palette = canvas.theme.palette;
    const chrome = canvas.chrome;
    const band_height = @min(row.height, @as(f32, @floatFromInt(chrome.pane_header)));
    if (band_height <= 0 or row.width <= 0) {
        return;
    }

    var band: Rect = .{ .x = row.x + chrome.px(8), .y = row.y, .width = @max(0, row.width - 2 * chrome.px(8)), .height = band_height };
    band.width -= try (ChangeReviewButton{ .area = band, .pane = self.pane }).draw(canvas);
    var index_storage: [8]u8 = undefined;
    const index_text = std.fmt.bufPrint(&index_storage, "{d}", .{self.index}) catch unreachable;
    const index_width = try canvas.measure(.{ .text = index_text, .bold = true, .face = .sans, .size = .body });
    var chip: StatusChip = .{ .context = self.context, .agent = self.agent, .area = band };
    var chip_width = try chip.width(canvas);
    var progress: PaneProgress = .{ .pane = self.pane, .area = band, .motions = self.context.progress };
    var progress_width = try progress.width(canvas);
    const reserved = index_width + chip_width + chrome.px(12);
    if (progress_width > @min(band.width / 2, @max(0, band.width - reserved))) {
        progress.compact = true;
        progress_width = try progress.width(canvas);
    }

    const attention_width = if (self.agent) |agent| (if (attention.needsInput(agent.status)) chip_width else 0) else 0;
    if (progress_width > 0 and progress_width + index_width + attention_width + chrome.px(12) <= band.width) {
        try progress.draw(canvas);
        band.width = @max(0, band.width - progress_width - chrome.px(6));
    }

    var x = band.x;
    const end = band.x + band.width;
    x += try canvas.textAt(.{ .x = x, .y = band.y, .width = @max(0, end - x), .height = band.height }, .{ .text = index_text, .color = palette.text, .bold = true, .face = .sans, .size = .body });
    x += chrome.px(6);
    const name = self.pane.foregroundName();
    if (chip_width > end - x) {
        chip_width = 0;
    }

    const name_width = @max(0, end - x - (if (chip_width != 0) chip_width + chrome.px(8) else 0));
    _ = try canvas.textAt(.{ .x = x, .y = band.y, .width = name_width, .height = band.height }, .{ .text = if (name.len == 0) "shell" else name, .color = palette.subtext0, .face = .sans, .size = .body });
    if (chip_width == 0) {
        return;
    }

    chip.area = .{ .x = end - chip_width, .y = band.y, .width = chip_width, .height = band.height };
    try chip.draw(canvas);
}
