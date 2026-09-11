const DecoderType = @import("../Decoder.zig");
const PaneDescriptorType = @import("../PaneDescriptor.zig");
const id = @import("../id.zig");
const codec = @import("../codec.zig");
const PaneDescriptorIterator = @This();

decoder: DecoderType,
remaining: u16,

pub fn next(iterator: *PaneDescriptorIterator) !?PaneDescriptorType {
    if (iterator.remaining == 0) {
        return null;
    }
    iterator.remaining -= 1;
    return .{
        .pane_id = try id.pane(try iterator.decoder.readInt(u64)),
        .lifecycle = try codec.decodePaneLifecycle(try iterator.decoder.readByte()),
    };
}
