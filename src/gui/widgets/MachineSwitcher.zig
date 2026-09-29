//! The machine switcher at the top of the expanded sidebar: one control per
//! machine the window holds, in slot order, with the machine's color disc
//! and an attention dot, the shown one filled. Machines past the width fold
//! into a `+N` control that opens the palette on the machines. Drawn only
//! while the window holds more than one machine; the rail never shows it.
const std = @import("std");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const client = @import("telar-client");
const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
const Label = @import("Label.zig");
const PixelButton = @import("PixelButton.zig");
const MachineSegment = @import("MachineSegment.zig");
const MachineSwitcher = @This();

/// Logical pixels of the disc, the inner padding and the gap between
/// controls.
const disc: f32 = 7;
const padding: f32 = 8;
const gap: f32 = 4;
/// The widest one control grows, so a long label cannot take the row.
const max_control: f32 = 120;
/// Bytes of the `+N` text.
const max_more_bytes = 8;

context: *const Context,
area: Rect,

/// Example: `try switcher.draw(canvas);`
pub fn draw(self: MachineSwitcher, canvas: *Canvas) !void {
    const machines = self.context.projection.machines orelse return;
    if (machines.count() <= 1 or self.area.width <= 0 or self.area.height <= 0) {
        return;
    }

    const chrome = canvas.chrome;
    var more_storage: [max_more_bytes]u8 = undefined;
    const more_reserve = try canvas.measure(.{ .text = "+99", .face = .sans, .size = .small }) + chrome.px(2 * padding);
    const right = self.area.x + self.area.width;
    var left = self.area.x;
    var hidden: usize = 0;

    for (0..client.Machines.capacity) |index| {
        const slot: u8 = @intCast(index);
        if (!machines.shown(slot)) {
            continue;
        }

        const label: Label = .{ .text = machines.label(slot), .face = .sans, .size = .small, .bold = slot == machines.active };
        const width = @min(try canvas.measure(label) + chrome.px(2 * padding + disc + gap), chrome.px(max_control));
        if (hidden != 0 or left + width > right - more_reserve) {
            hidden += 1;
            continue;
        }

        const control: Rect = .{ .x = left, .y = self.area.y, .width = width, .height = self.area.height };
        try (PixelButton{
            .context = self.context,
            .area = control,
            .intent = .{ .select_machine = slot },
            .text = label.text,
            .active = slot == machines.active,
            .background = slot == machines.active,
            .hover_fill = true,
            .size = .small,
            .bold = label.bold,
            .radius = chrome.px(6),
            .inset = chrome.px(padding + disc + gap),
            .dot = if (machines.attention[slot] and slot != machines.active) canvas.theme.palette.yellow else null,
        }).draw(canvas);

        const side = chrome.px(disc);
        try canvas.fillRoundedAt(.{
            .x = control.x + chrome.px(padding),
            .y = control.y + (control.height - side) / 2,
            .width = side,
            .height = side,
        }, .{ .radius = side, .color = MachineSegment.ink(canvas, machines, slot) });
        left += width + chrome.px(gap);
    }

    if (hidden == 0) {
        return;
    }

    const more = std.fmt.bufPrint(&more_storage, "+{d}", .{hidden}) catch "+";
    try (PixelButton{
        .context = self.context,
        .area = .{ .x = left, .y = self.area.y, .width = @max(0, @min(more_reserve, right - left)), .height = self.area.height },
        .intent = .machine_picker,
        .placement = .machine_fold,
        .text = more,
        .background = false,
        .hover_fill = true,
        .size = .small,
        .alignment = .center,
        .radius = chrome.px(6),
    }).draw(canvas);
}
