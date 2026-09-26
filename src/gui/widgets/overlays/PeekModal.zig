//! A peek at one agent: its task and state, the last rows of its pane and a
//! field whose text goes to the agent. `/stop` interrupts it, `/diff` opens
//! its diff and an empty field opens its tab.
const std = @import("std");
const cellgrid = @import("cellgrid");
const client = @import("telar-client");
const Canvas = @import("../Canvas.zig");
const Modal = @import("Modal.zig");
const TextField = @import("../TextField.zig");
const PeekModal = @This();

/// Rows around the pane text: facts, a gap, the field and the hint.
const chrome_rows = 4;

area: cellgrid.Rect,
projection: *const client.Projection,

/// Example: `try peek.draw(canvas);`
pub fn draw(self: PeekModal, canvas: *Canvas) !void {
    const projection = self.projection.*;
    const model = projection.model;
    const palette = canvas.theme.palette;
    const key = model.peek_screen.agent orelse return;
    const agent = projection.agents.find(key) orelse return;
    const task = client.fleet_order.taskRow(projection.workspaces, agent);
    const modal: Modal = .{
        .area = self.area,
        .title = if (task) |row| row.displayName() else agent.displayName(),
    };
    try modal.draw(canvas);

    const content = modal.content();
    if (content.h < chrome_rows) {
        return;
    }

    var facts_buffer: [256]u8 = undefined;
    var facts = std.Io.Writer.fixed(&facts_buffer);
    facts.print("{s} \u{00b7} {s}", .{ agent.displayName(), @tagName(agent.status) }) catch {};
    if (task) |row| {
        facts.print("  \u{2387} {s}", .{row.handle()}) catch {};
    }

    if (agent.plan_total != 0) {
        facts.print("  {d}/{d} {s}", .{ agent.plan_done, agent.plan_total, agent.planStep() }) catch {};
    } else if (agent.lastEvent().len != 0) {
        facts.print("  {s}", .{agent.lastEvent()}) catch {};
    }

    try canvas.text(content.row(0), .{ .text = facts.buffered(), .color = palette.subtext0 });

    const screen_rows = content.h - chrome_rows;
    var lines = lastLines(model.peek_screen.slice(), screen_rows);
    var row: u16 = 0;
    while (lines.next()) |line| : (row += 1) {
        try canvas.text(content.row(1 + row), .{ .text = line, .color = palette.text });
    }

    try TextField.fromPrompt(&projection.prompt.?, canvas.rect(content.row(content.h - 2)), .name).draw(canvas);
    try canvas.text(content.row(content.h - 1), .{ .text = "Enter send  empty opens  /stop  /diff  Esc close", .color = palette.subtext0 });
}

/// The last `count` non-empty-tail lines of `text`, oldest first.
fn lastLines(text: []const u8, count: u16) std.mem.SplitIterator(u8, .scalar) {
    const trimmed = std.mem.trimEnd(u8, text, " \n\r\t");
    var start = trimmed.len;
    var seen: u16 = 0;
    while (start > 0 and seen < count) {
        start -= 1;
        if (trimmed[start] == '\n') {
            seen += 1;
            if (seen == count) {
                start += 1;
                break;
            }
        }
    }

    return std.mem.splitScalar(u8, trimmed[start..], '\n');
}

test "a peek shows the last rows of the pane" {
    var lines = lastLines("one\ntwo\nthree\nfour\n\n", 2);
    try std.testing.expectEqualStrings("three", lines.next().?);
    try std.testing.expectEqualStrings("four", lines.next().?);
    try std.testing.expect(lines.next() == null);

    var all = lastLines("solo", 4);
    try std.testing.expectEqualStrings("solo", all.next().?);
    try std.testing.expect(all.next() == null);
}
