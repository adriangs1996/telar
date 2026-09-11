const DecoderType = @import("../Decoder.zig");
const types = @import("../types.zig");
const layout = @import("layout.zig");
const ClientLayoutNodeIterator = @This();

decoder: DecoderType,
remaining: u16,

/// Decodes the next tree node, returning null after the declared count.
///
/// ```zig
/// const node = (try nodes.next()) orelse return;
/// ```
pub fn next(iterator: *ClientLayoutNodeIterator) !?types.ClientLayoutNode {
    if (iterator.remaining == 0) {
        return null;
    }

    iterator.remaining -= 1;
    return @as(?types.ClientLayoutNode, try layout.decodeClientLayoutNode(&iterator.decoder));
}
