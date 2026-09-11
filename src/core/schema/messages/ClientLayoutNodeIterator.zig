const ClientLayoutNodeIterator = @This();
const wire = @import("../wire.zig");
const source_namespace = @import("layout.zig");
decoder: wire.Decoder,
remaining: u16,

/// Decodes the next tree node, returning null after the declared count.
///
/// ```zig
/// const node = (try nodes.next()) orelse return;
/// ```
pub fn next(iterator: *ClientLayoutNodeIterator) !?source_namespace.ClientLayoutNode {
    if (iterator.remaining == 0) {
        return null;
    }

    iterator.remaining -= 1;
    return @as(?source_namespace.ClientLayoutNode, try source_namespace.decodeClientLayoutNode(&iterator.decoder));
}
