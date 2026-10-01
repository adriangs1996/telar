//! A tracked worktree command without an agent. Its last exit remains visible.
const std = @import("std");
const data = @import("model");
const client = @import("telar-client");
const gfx = @import("gfx");
const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
const CardGeometry = @import("CardGeometry.zig");
const TextFit = @import("TextFit.zig");
const Label = @import("Label.zig");
const CommandCard = @This();

context: *const Context,
bounds: gfx.Rect,
task: *const data.WorktreeRow,
machine_label: []const u8,
connected: bool,
geometry: CardGeometry,
nested: bool,
navigation: ?client.Intent,

/// Draws a command's owner, outcome, task and command label.
/// Example: `try card.draw(canvas);`
pub fn draw(self: CommandCard, canvas: *Canvas) !void {
    const palette = canvas.theme.palette;
    if (self.navigation) |intent| {
        if (self.context.isHovered(.{ .intent = intent })) {
            try canvas.fillRoundedAt(self.bounds, .{ .radius = self.geometry.px(CardGeometry.radius), .color = palette.surface1 });
        }
    }

    if (self.nested) {
        try canvas.fillAt(.{ .x = self.bounds.x - self.geometry.px(CardGeometry.task_indent) / 2, .y = self.bounds.y, .width = 1, .height = self.bounds.height }, palette.surface1);
    }

    var buffer: [TextFit.max_bytes]u8 = undefined;
    const status = if (!self.connected) "offline · last known" else switch (self.task.command_state) {
        .none => "",
        .running => "running",
        .exited => if (self.task.command_exit == 0) "exited successfully" else "failed",
    };
    const facts = std.fmt.bufPrint(&buffer, "{s} · {s} · {s}", .{ self.machine_label, self.task.handle(), status }) catch status;
    try fitted(canvas, self.geometry.row(self.bounds, 0), .{ .text = facts, .color = palette.subtext0, .face = .sans, .size = .small });
    try fitted(canvas, self.geometry.row(self.bounds, 1), .{ .text = self.task.displayName(), .color = palette.text, .face = .sans, .size = .title });
    try fitted(canvas, self.geometry.row(self.bounds, 2), .{ .text = self.task.commandLabel(), .color = palette.overlay1, .face = .sans, .size = .small });
}

fn fitted(canvas: *Canvas, row: gfx.Rect, label: Label) !void {
    var buffer: [TextFit.max_bytes]u8 = undefined;
    const fit: TextFit = .{ .canvas = canvas, .width = row.width };
    var result = label;
    result.text = try fit.fit(label, &buffer);
    _ = try canvas.textAt(row, result);
}
