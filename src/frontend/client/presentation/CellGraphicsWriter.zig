const CellGraphicsWriter = @This();
const source_namespace = @import("Presenter.zig");
panes: ?source_namespace.kitty.KittyGraphicsWriter = null,
pill: *source_namespace.pill_graphics.Renderer,
pill_bytes: usize = 0,

pub fn writeOpaque(context: *anyopaque, writer: *source_namespace.Io.Writer) source_namespace.Io.Writer.Error!usize {
    const self: *CellGraphicsWriter = @ptrCast(@alignCast(context));
    self.pill_bytes = try self.pill.writeRetirements(writer);
    const pane_bytes = if (self.panes) |*panes| try panes.write(writer) else 0;
    return self.pill_bytes + pane_bytes;
}
