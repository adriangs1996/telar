const Decoder = @import("../Decoder.zig");
const SearchMatch = @import("../SearchMatch.zig");
const SearchMatchIterator = @This();

decoder: Decoder,
remaining: u16,

pub fn next(iterator: *SearchMatchIterator) !?SearchMatch {
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
