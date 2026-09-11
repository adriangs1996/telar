const DecoderType = @import("../Decoder.zig");
const SearchMatchType = @import("../SearchMatch.zig");
const SearchMatchIterator = @This();

decoder: DecoderType,
remaining: u16,

pub fn next(iterator: *SearchMatchIterator) !?SearchMatchType {
    if (iterator.remaining == 0) {
        return null;
    }
    iterator.remaining -= 1;
    return .{
        .x = try iterator.decoder.readInt(u16),
        .y = try iterator.decoder.readInt(u32),
        .len = try iterator.decoder.readInt(u16),
    };
}
