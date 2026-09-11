const DecoderType = @import("../Decoder.zig");
const ClientTabLayoutView = @import("ClientTabLayoutView.zig");
const layout = @import("layout.zig");
const ClientTabLayoutIterator = @This();

decoder: DecoderType,
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
    return @as(?ClientTabLayoutView, try layout.decodeClientTabLayout(&iterator.decoder));
}
