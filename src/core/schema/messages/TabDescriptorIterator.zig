const DecoderType = @import("../Decoder.zig");
const TabDescriptorType = @import("../TabDescriptor.zig");
const id = @import("../id.zig");
const TabDescriptorIterator = @This();

decoder: DecoderType,
remaining: u16,

pub fn next(iterator: *TabDescriptorIterator) !?TabDescriptorType {
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
