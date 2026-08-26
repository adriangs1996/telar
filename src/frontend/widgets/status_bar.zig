//! System metrics at the left edge of the bottom bar.
//!
//! The runtime samples cpu, memory, and battery off the interactive path and
//! the client caches the latest values. Rendering only formats what is
//! already in memory, in fixed buffers, so the frame stays allocation free.

const std = @import("std");
const widget = @import("context.zig");
const ui = @import("../ui/root.zig");

/// Presentation values, already reduced by the transport layer. Memory is in
/// tenths of a GiB so formatting never touches floating point.
pub const Metrics = struct {
    cpu_percent: u8,
    memory_used_decigib: u16,
    battery_percent: ?u8,
};

pub fn render(context: *widget.Context, area: ui.Rect, metrics: ?Metrics) void {
    if (area.isEmpty()) return;
    const values = metrics orelse return;
    var x = area.x + 1;
    const background = context.palette.panel_bg;

    var cpu_buffer: [12]u8 = undefined;
    const cpu = std.fmt.bufPrint(&cpu_buffer, "\u{2699} {d}%", .{values.cpu_percent}) catch
        return;
    x += context.buffer.writeText(area, x, area.y, cpu, .{
        .fg = cpuColor(context, values.cpu_percent),
        .bg = background,
    });
    x += context.buffer.writeText(area, x, area.y, "  ", .{ .bg = background });

    var memory_buffer: [16]u8 = undefined;
    const memory = std.fmt.bufPrint(&memory_buffer, "\u{25a4} {d}.{d}G", .{
        values.memory_used_decigib / 10,
        values.memory_used_decigib % 10,
    }) catch return;
    x += context.buffer.writeText(area, x, area.y, memory, .{
        .fg = context.palette.mauve,
        .bg = background,
    });

    // Machines without a battery show nothing rather than a fake 0%.
    if (values.battery_percent) |battery| {
        x += context.buffer.writeText(area, x, area.y, "  ", .{ .bg = background });
        var battery_buffer: [12]u8 = undefined;
        const text = std.fmt.bufPrint(&battery_buffer, "\u{26a1}{d}%", .{battery}) catch return;
        _ = context.buffer.writeText(area, x, area.y, text, .{
            .fg = if (battery < 20) context.palette.red else context.palette.green,
            .bg = background,
        });
    }
}

fn cpuColor(context: *const widget.Context, cpu_percent: u8) ui.Color {
    if (cpu_percent > 90) return context.palette.red;
    if (cpu_percent > 70) return context.palette.yellow;
    return context.palette.teal;
}
