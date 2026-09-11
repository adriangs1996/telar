const KittyGraphicsWriterType = @import("../../graphics/KittyGraphicsWriter.zig");
const PillRenderer = @import("../../graphics/PillRenderer.zig");
const std = @import("std");
const CellGraphicsWriter = @This();

panes: ?KittyGraphicsWriterType = null,
pill: *PillRenderer,
pill_bytes: usize = 0,

pub fn writeOpaque(context: *anyopaque, writer: *std.Io.Writer) std.Io.Writer.Error!usize {
    const self: *CellGraphicsWriter = @ptrCast(@alignCast(context));
    self.pill_bytes = try self.pill.writeRetirements(writer);
    const pane_bytes = if (self.panes) |*panes| try panes.write(writer) else 0;
    return self.pill_bytes + pane_bytes;
}
