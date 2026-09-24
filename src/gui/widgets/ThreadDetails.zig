//! Extra metadata appears once; output retains the full original tool result.
const std = @import("std");
const Canvas = @import("Canvas.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const ThreadItemView = @import("ThreadItemView.zig");
const MessageText = @import("MessageText.zig");
const Details = @This();

view: ThreadItemView,
bounds: Rect,

/// Measures only metadata lines not already present in the tool result.
/// Example: `const height = try details.measure(canvas);`
pub fn measure(self: Details, canvas: *Canvas) !f32 {
    return self.layout(canvas, false);
}

/// Draws additional working directory and other metadata before the output.
/// Example: `try details.draw(canvas);`
pub fn draw(self: Details, canvas: *Canvas) !void {
    _ = try self.layout(canvas, true);
}

fn layout(self: Details, canvas: *Canvas, paint: bool) !f32 {
    const item = self.view.item;
    const snapshot = self.view.thread.transcript.?;
    var lines = std.mem.tokenizeAny(u8, item.detail(snapshot), "\r\n");
    var height: f32 = 0;
    while (lines.next()) |line| {
        if (represented(line, self.view.text(), item.kind == .command)) {
            continue;
        }

        var text: MessageText = .{ .bounds = self.bounds, .viewport = self.view.viewport, .text = line, .markdown = false, .muted = true };
        text.owner = self.view.source(.metadata);
        text.owner.?.source_offset += @intCast(@intFromPtr(line.ptr) - @intFromPtr(item.detail(snapshot).ptr));
        text.bounds.y += height;
        const measured = try text.measure(canvas);
        if (paint) {
            try text.draw(canvas);
        }

        height += measured;
    }

    return height;
}

/// Tests whether a metadata line is already shown in the activity output.
/// Example: `if (ThreadDetails.represented(line, output, command)) continue;`
pub fn represented(line: []const u8, output: []const u8, command: bool) bool {
    var lines = std.mem.tokenizeAny(u8, output, "\r\n");
    while (lines.next()) |candidate| {
        const trimmed = std.mem.trim(u8, candidate, " \t");
        const content = if (command and std.mem.startsWith(u8, trimmed, "$ ")) trimmed[2..] else trimmed;
        if (std.mem.eql(u8, content, std.mem.trim(u8, line, " \t"))) {
            return true;
        }
    }

    return false;
}

test "metadata deduplication removes exact repeated lines and preserves directory context" {
    try std.testing.expect(represented("zig build check", "$ zig build check\nAll tests passed", true));
    try std.testing.expect(!represented("zig build check", "$ zig build check\nAll tests passed", false));
    try std.testing.expect(represented("1 file(s)", "1 file(s)\n@@ line 1\n+ added", false));
    try std.testing.expect(!represented("/work/project", "Checked /work/project/src", false));
}
