const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
const record_geometry = @import("record_geometry.zig");
const Bands = @import("Bands.zig");
const event_module = @import("Event.zig");
const Event = event_module.Event;
const client = @import("telar-client");
const gfx = @import("gfx");
const Switcher = @import("MachineSwitcher.zig");
const Segment = @import("MachineSegment.zig");
extern "c" fn getchar() c_int;

pub fn main() !void {
    while (getchar() >= 0) {
        const segment = try record_geometry.read(u8) != 0;
        var canvas: Canvas = .{};
        canvas.chrome.ratio = try record_geometry.read(f32);
        const area: gfx.Rect = .{ .x = try record_geometry.read(f32), .y = try record_geometry.read(f32), .width = try record_geometry.read(f32), .height = try record_geometry.read(f32) };
        var machines: client.Machines = .{};
        machines.total = try record_geometry.read(u8);
        machines.active = try record_geometry.read(u8);
        const attention = try record_geometry.read(u32);
        const radix = 10;

        for (&machines.labels, &machines.attention, 0..) |*label, *asking, slot| {
            label.* = .{ 'm', @intCast('0' + slot / radix), @intCast('0' + slot % radix) };
            asking.* = attention & (@as(u32, 1) << @as(u5, @intCast(slot))) != 0;
        }

        canvas.more = try record_geometry.read(f32);
        canvas.fold = try record_geometry.read(f32);
        for (&canvas.advances) |*advance| {
            advance.* = try record_geometry.read(f32);
        }

        var bands: Bands = .{};
        const context: Context = .{ .projection = .{ .machines = &machines }, .bands = &bands };
        try record_geometry.write(if (segment) try Segment.preferredWidth(&canvas, &context) else @as(f32, 0));
        if (segment) {
            try (Segment{ .context = &context, .area = area }).draw(&canvas);
        } else {
            try (Switcher{ .context = &context, .area = area }).draw(&canvas);
        }

        try record_geometry.write(@intFromEnum(Event.end));
    }
}
