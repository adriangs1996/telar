const bytecodec = @import("bytecodec");
const Decoder = bytecodec.Decoder;
const ClientTabLayoutView = @import("ClientTabLayoutView.zig");
const layout = @import("layout.zig");
const ClientTabLayoutIterator = @This();

decoder: Decoder,
remaining: u16,

/// Decodes the next tab layout, returning null after the declared count.
///
/// ```zig
/// const tab = (try tabs.next()) orelse return;
/// ```
pub fn next(self: *ClientTabLayoutIterator) !?ClientTabLayoutView {
    if (self.remaining == 0) {
        return null;
    }

    self.remaining -= 1;
    return @as(?ClientTabLayoutView, try layout.decodeClientTabLayout(&self.decoder));
}
