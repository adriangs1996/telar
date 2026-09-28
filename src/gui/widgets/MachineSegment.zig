//! The top bar's name of the machine the window shows: a disc in the
//! machine's color, its label and a chevron, with an attention dot when
//! another machine asks for the person. A click opens the palette on the
//! window's machines. Nothing is drawn while the window holds one machine,
//! so a single-machine window looks as it always did.
const std = @import("std");
const cellgrid = @import("cellgrid");
const data = @import("model");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const client = @import("telar-client");
const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
const Label = @import("Label.zig");
const PixelButton = @import("PixelButton.zig");
const bar_tone = @import("bar_tone.zig");
const MachineSegment = @This();

/// Logical pixels of the color disc, the gaps around it and the widest
/// segment.
const disc: f32 = 8;
const padding: f32 = 10;
const gap: f32 = 6;
const max_width: f32 = 200;
/// The longest text the segment shows, in bytes.
const max_text_bytes = client.Machines.max_label_bytes + 8;

context: *const Context,
area: Rect,

/// Whether the window holds more than one machine.
pub fn shown(context: *const Context) bool {
    const machines = context.projection.machines orelse return false;
    return machines.count() > 1;
}

/// The width the segment wants, capped so the tabs keep their room.
/// Example: `const width = try MachineSegment.preferredWidth(canvas, context);`
pub fn preferredWidth(canvas: *Canvas, context: *const Context) !f32 {
    var storage: [max_text_bytes]u8 = undefined;
    const label: Label = .{ .text = text(context, &storage), .face = .sans, .size = .body, .bold = true };
    const chrome = canvas.chrome;
    const wanted = try canvas.measure(label) + chrome.px(disc + gap + 2 * padding);
    return @min(wanted, chrome.px(max_width));
}

/// Example: `try segment.draw(canvas);`
pub fn draw(self: MachineSegment, canvas: *Canvas) !void {
    const machines = self.context.projection.machines orelse return;
    if (machines.count() <= 1 or self.area.width <= 0) {
        return;
    }

    const chrome = canvas.chrome;
    var storage: [max_text_bytes]u8 = undefined;
    const button: PixelButton = .{
        .context = self.context,
        .area = self.area,
        .intent = .machine_picker,
        .text = text(self.context, &storage),
        .background = false,
        .hover_fill = true,
        .bold = true,
        .radius = chrome.px(8),
        .inset = chrome.px(padding + disc + gap),
        .dot = if (machines.attentionElsewhere()) canvas.theme.palette.yellow else null,
    };
    try button.draw(canvas);

    const side = chrome.px(disc);
    try canvas.fillRoundedAt(.{
        .x = self.area.x + chrome.px(padding),
        .y = self.area.y + (self.area.height - side) / 2,
        .width = side,
        .height = side,
    }, .{ .radius = side, .color = ink(canvas, machines, machines.active) });
}

/// The color a machine's profile names, or the accent.
/// Example: `const color = MachineSegment.ink(canvas, machines, slot);`
pub fn ink(canvas: *const Canvas, machines: *const client.Machines, slot: u8) cellgrid.Color {
    const name = machines.color(slot) orelse return canvas.theme.palette.accent;
    const parsed = data.color_name.parse(name) orelse return canvas.theme.palette.accent;
    return bar_tone.color(canvas, parsed);
}

fn text(context: *const Context, storage: *[max_text_bytes]u8) []const u8 {
    const machines = context.projection.machines orelse return "";
    return std.fmt.bufPrint(storage, "{s} ▾", .{machines.label(machines.active)}) catch machines.label(machines.active);
}
