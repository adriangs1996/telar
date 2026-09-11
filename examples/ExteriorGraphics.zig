const ExteriorGraphics = @This();
const source_namespace = @import("terminal_browser_pane.zig");
writer: source_namespace.kitty.KittyGraphicsWriter,

fn writeOpaque(context: *anyopaque, writer: *source_namespace.Io.Writer) source_namespace.Io.Writer.Error!usize {
    const exterior: *ExteriorGraphics = @ptrCast(@alignCast(context));
    return exterior.writer.write(writer);
}
