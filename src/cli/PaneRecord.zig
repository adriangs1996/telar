const std = @import("std");
const core = @import("telar-core");
const PaneRecord = @This();

location: core.TabLocation,
position: u16,
pane: core.PaneDescriptor,

/// Emits an owned topology entry. Example: `try record.write(writer, true);`
pub fn write(self: *const PaneRecord, writer: *std.Io.Writer, json: bool) !void {
    if (json) {
        try std.json.Stringify.value(.{
            .workspace_id = core.raw(self.location.workspace.workspace),
            .tab_id = core.raw(self.location.tab_id),
            .position = self.position,
            .pane_id = core.raw(self.pane.pane_id),
            .pane_generation = self.pane.pane_generation,
            .kind = self.pane.kind,
            .lifecycle = self.pane.lifecycle,
        }, .{}, writer);
    } else {
        try writer.print("{d}\t{d}\t{d}\t{d}\t{s}\t{s}\n", .{ core.raw(self.location.workspace.workspace), core.raw(self.location.tab_id), core.raw(self.pane.pane_id), self.pane.pane_generation, @tagName(self.pane.kind), @tagName(self.pane.lifecycle) });
    }
}
