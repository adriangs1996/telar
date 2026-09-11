const ClientTabLayoutIterator = @This();
const wire = @import("../wire.zig");
const ClientTabLayoutView = @import("ClientTabLayoutView.zig");
const source_namespace = @import("layout.zig");
decoder: wire.Decoder,
remaining: u16,

/// Decodes the next tab layout, returning null after the declared count.
///
/// ```zig
/// const tab = (try tabs.next()) orelse return;
/// ```
pub fn next(iterator: *ClientTabLayoutIterator) !?ClientTabLayoutView {
    if (iterator.remaining == 0) {
        return null;
    }

    iterator.remaining -= 1;
    return @as(?ClientTabLayoutView, try source_namespace.decodeClientTabLayout(&iterator.decoder));
}
