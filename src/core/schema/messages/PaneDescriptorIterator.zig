const PaneDescriptorIterator = @This();
const wire = @import("../wire.zig");
const source_namespace = @import("tab.zig");
const id = @import("../id.zig");
decoder: wire.Decoder,
remaining: u16,

pub fn next(iterator: *PaneDescriptorIterator) !?source_namespace.PaneDescriptor {
    if (iterator.remaining == 0) {
        return null;
    }
    iterator.remaining -= 1;
    return .{
        .pane_id = try id.pane(try iterator.decoder.readInt(u64)),
        .lifecycle = try source_namespace.decodePaneLifecycle(try iterator.decoder.readByte()),
    };
}
