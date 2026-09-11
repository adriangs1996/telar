/// The text a tab shows: its display number, its name and, while one of its
/// panes is fullscreen, a marker drawn after the name.
const Label = @This();
const source_namespace = @import("tab_bar.zig");
const std = @import("std");
const ui = @import("../ui/root.zig");
const widget = @import("context_support.zig");
const Placement = @import("Placement.zig");
buffer: [source_namespace.schema.max_tab_label_bytes + 16]u8 = undefined,
len: usize = 0,
fullscreen: bool,

pub fn init(tab: *const source_namespace.tabs_mod.Tab, index: usize) Label {
    var label: Label = .{ .fullscreen = tab.model.layout.isFullscreen() };
    const written = std.fmt.bufPrint(&label.buffer, " {d}:{s} ", .{
        index + 1,
        tab.labelSlice(),
    }) catch fallback: {
        const placeholder = " tab ";
        @memcpy(label.buffer[0..placeholder.len], placeholder);
        break :fallback label.buffer[0..placeholder.len];
    };
    label.len = written.len;
    return label;
}

fn text(label: *const Label) []const u8 {
    return label.buffer[0..label.len];
}

pub fn width(label: *const Label) u16 {
    const marker: u16 = if (label.fullscreen) source_namespace.fullscreen_marker_width else 0;
    return ui.measure(label.text()) + marker;
}

/// Draws the text, then the marker when the whole marker fits.
pub fn draw(label: *const Label, context: *widget.Context, placement: Placement) void {
    const rect = placement.rect;
    const text_width = @min(ui.measure(label.text()), rect.w);
    _ = context.buffer.writeTruncated(rect, .{ .point = .{ .x = rect.x, .y = rect.y }, .text = label.text(), .max_width = text_width, .style = placement.style });
    if (!label.fullscreen or rect.w < text_width + source_namespace.fullscreen_marker_width) {
        return;
    }

    const marker_x = rect.x + text_width;
    _ = context.drawIcon(.{ .area = rect, .point = .{ .x = marker_x, .y = rect.y }, .icon = .pane_fullscreen, .style = placement.style });
    _ = context.buffer.writeTruncated(rect, .{ .point = .{ .x = marker_x + 1, .y = rect.y }, .text = " ", .max_width = 1, .style = placement.style });
}
