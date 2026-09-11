const SearchMatchIterator = @This();
const wire = @import("../wire.zig");
const source_namespace = @import("pane.zig");
decoder: wire.Decoder,
remaining: u16,

pub fn next(iterator: *SearchMatchIterator) !?source_namespace.SearchMatch {
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
