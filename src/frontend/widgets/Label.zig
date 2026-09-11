const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const TabType = @import("telar-client").Tab;
const std = @import("std");
const tab_bar = @import("tab_bar.zig");
const measure_module = @import("telar-core").measure;
const ContextType = @import("Context.zig");
const Placement = @import("Placement.zig");
/// The text a tab shows: its display number, its name and, while one of its
/// panes is fullscreen, a marker drawn after the name.
const Label = @This();

buffer: [max_tab_label_bytes_module + 16]u8 = undefined,
len: usize = 0,
fullscreen: bool,

pub fn init(tab: *const TabType, index: usize) Label {
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
    const marker: u16 = if (label.fullscreen) tab_bar.fullscreen_marker_width else 0;
    return measure_module(label.text()) + marker;
}

/// Draws the text, then the marker when the whole marker fits.
pub fn draw(label: *const Label, context: *ContextType, placement: Placement) void {
    const rect = placement.rect;
    const text_width = @min(measure_module(label.text()), rect.w);
    _ = context.buffer.writeTruncated(rect, .{ .point = .{ .x = rect.x, .y = rect.y }, .text = label.text(), .max_width = text_width, .style = placement.style });
    if (!label.fullscreen or rect.w < text_width + tab_bar.fullscreen_marker_width) {
        return;
    }

    const marker_x = rect.x + text_width;
    _ = context.drawIcon(.{ .area = rect, .point = .{ .x = marker_x, .y = rect.y }, .icon = .pane_fullscreen, .style = placement.style });
    _ = context.buffer.writeTruncated(rect, .{ .point = .{ .x = marker_x + 1, .y = rect.y }, .text = " ", .max_width = 1, .style = placement.style });
}
