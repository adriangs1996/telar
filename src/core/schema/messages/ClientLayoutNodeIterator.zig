const Decoder = @import("../Decoder.zig");
const types = @import("../types.zig");
const layout = @import("layout.zig");
const ClientLayoutNodeIterator = @This();

decoder: Decoder,
remaining: u16,

/// Decodes the next tree node, returning null after the declared count.
///
/// ```zig
/// const node = (try nodes.next()) orelse return;
/// ```
pub fn next(self: *ClientLayoutNodeIterator) !?types.ClientLayoutNode {
    if (self.remaining == 0) {
        return null;
    }

    self.remaining -= 1;
    return @as(?types.ClientLayoutNode, try layout.decodeClientLayoutNode(&self.decoder));
}
