const std = @import("std");
const core = @import("telar-core");

/// Formats pane identity and generation without attaching to its terminal. Example: `try pane_output.write(writer, pane, true);`
pub fn write(writer: *std.Io.Writer, pane: core.PaneDescriptor, json: bool) !void {
    if (json) {
        try std.json.Stringify.value(.{ .pane_id = core.raw(pane.pane_id), .pane_generation = pane.pane_generation, .lifecycle = pane.lifecycle }, .{}, writer);
    } else {
        try writer.print("{d}\t{d}\t{s}\n", .{ core.raw(pane.pane_id), pane.pane_generation, @tagName(pane.lifecycle) });
    }
}
