const TabDescriptorIterator = @This();
const wire = @import("../wire.zig");
const source_namespace = @import("workspace.zig");
const id = @import("../id.zig");
decoder: wire.Decoder,
remaining: u16,

pub fn next(iterator: *TabDescriptorIterator) !?source_namespace.TabDescriptor {
    if (iterator.remaining == 0) {
        return null;
    }
    iterator.remaining -= 1;
    return .{
        .tab_id = try id.tab(try iterator.decoder.readInt(u64)),
        .position = try iterator.decoder.readInt(u16),
        .pane_count = try iterator.decoder.readInt(u16),
        .label = try iterator.decoder.readSized16(),
    };
}
