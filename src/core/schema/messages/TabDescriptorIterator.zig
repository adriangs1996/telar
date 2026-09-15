const DecoderType = @import("../Decoder.zig");
const TabDescriptorView = @import("TabDescriptorView.zig");
const id = @import("../id.zig");
const TabDescriptorIterator = @This();

decoder: DecoderType,
remaining: u16,

pub fn next(iterator: *TabDescriptorIterator) !?TabDescriptorView {
    if (iterator.remaining == 0) {
        return null;
    }
    iterator.remaining -= 1;
    var descriptor: TabDescriptorView = .{
        .tab_id = try id.tab(try iterator.decoder.readInt(u64)),
        .position = try iterator.decoder.readInt(u16),
        .pane_count = try iterator.decoder.readInt(u16),
        .label = try iterator.decoder.readSized16(),
        .foreground_count = try iterator.decoder.readInt(u16),
        .encoded_foregrounds = undefined,
    };
    const start = iterator.decoder.index;
    for (0..descriptor.foreground_count) |_| {
        _ = try iterator.decoder.readInt(u64);
        _ = try iterator.decoder.readSized16();
    }

    descriptor.encoded_foregrounds = iterator.decoder.consumed(start);
    return descriptor;
}
