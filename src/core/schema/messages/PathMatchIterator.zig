const bytecodec = @import("bytecodec");
const types = @import("../types.zig");
const Decoder = bytecodec.Decoder;
const PathMatch = @import("../PathMatch.zig");
const paths = @import("paths.zig");
const PathMatchIterator = @This();

decoder: Decoder,
remaining: u16,

/// Yields matches `decodePathResults` already validated; the path borrows
/// the message and the positions land in `storage`.
///
/// ```zig
/// var storage: [core.max_path_query_bytes]u16 = undefined;
/// while (try iterator.next(&storage)) |match| { ... }
/// ```
pub fn next(self: *PathMatchIterator, storage: *[types.max_path_query_bytes]u16) !?PathMatch {
    if (self.remaining == 0) {
        return null;
    }

    self.remaining -= 1;
    return try paths.decodePathMatch(&self.decoder, storage);
}
