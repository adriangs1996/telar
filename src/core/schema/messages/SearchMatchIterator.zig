const bytecodec = @import("bytecodec");
const Decoder = bytecodec.Decoder;
const SearchMatch = @import("../SearchMatch.zig");
const SearchMatchIterator = @This();

decoder: Decoder,
remaining: u16,

pub fn next(self: *SearchMatchIterator) !?SearchMatch {
    if (self.remaining == 0) {
        return null;
    }
    self.remaining -= 1;
    return .{
        .x = try self.decoder.readInt(u16),
        .y = try self.decoder.readInt(u32),
        .len = try self.decoder.readInt(u16),
    };
}
