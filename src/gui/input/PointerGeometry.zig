const Window = @import("telar-window");
const keyinput = @import("keyinput");
const std = @import("std");
const core = @import("telar-core");
const Event = @FieldType(Window.Input, "pointer");
const Geometry = @This();

origin: [2]u32 = .{ 0, 0 },
size: core.TerminalSize = .{ .cols = 0, .rows = 0 },

/// Padding lies outside the grid, never over its first cell. Existing drags
/// clamp there so selection can finish beyond the window. Example: `geometry.resolve(event)`.
pub fn resolve(self: Geometry, event: Event) ?keyinput.Mouse {
    if (event.kind == .leave) {
        return null;
    }

    if (self.size.cell_width_px == 0 or self.size.cell_height_px == 0) {
        return null;
    }

    const x = event.x - @as(f64, @floatFromInt(self.origin[0]));
    const y = event.y - @as(f64, @floatFromInt(self.origin[1]));
    const width = @as(u32, self.size.cols) * self.size.cell_width_px;
    const height = @as(u32, self.size.rows) * self.size.cell_height_px;
    if (width == 0 or height == 0) {
        return null;
    }

    const retained = event.kind == .release or event.kind == .drag;
    if (!retained and (x < 0 or y < 0 or x >= @as(f64, @floatFromInt(width)) or y >= @as(f64, @floatFromInt(height)))) {
        return null;
    }

    const raw_x: u32 = @intFromFloat(std.math.clamp(x, 0, @as(f64, @floatFromInt(width - 1))));
    const raw_y: u32 = @intFromFloat(std.math.clamp(y, 0, @as(f64, @floatFromInt(height - 1))));
    return .{
        .x = @intCast(raw_x / self.size.cell_width_px),
        .y = @intCast(raw_y / self.size.cell_height_px),
        .raw_x = raw_x,
        .raw_y = raw_y,
        .button = @as(u8, switch (event.kind) {
            .drag => 32 + @as(u8, @intFromEnum(event.button)),
            .scroll_up => 64,
            .scroll_down => 65,
            .move => 35,
            else => @intFromEnum(event.button),
        }) | (@as(u8, @intCast(event.mods & 7)) << 2),
        .kind = switch (event.kind) {
            .press => .press,
            .release => .release,
            .drag => .drag,
            .scroll_up => .scroll_up,
            .scroll_down => .scroll_down,
            .move => .move,
            .leave => unreachable,
        },
    };
}
