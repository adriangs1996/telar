const KittyGraphicsWriterType = @import("telar-frontend").KittyGraphicsWriter;
const std = @import("std");
const ExteriorGraphics = @This();

writer: KittyGraphicsWriterType,

pub fn writeOpaque(context: *anyopaque, writer: *std.Io.Writer) std.Io.Writer.Error!usize {
    const exterior: *ExteriorGraphics = @ptrCast(@alignCast(context));
    return exterior.writer.write(writer);
}
