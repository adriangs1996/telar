const bytecodec = @import("bytecodec");
const Decoder = bytecodec.Decoder;
const LimitListEntry = @import("LimitListEntry.zig");
const limits = @import("limits.zig");
const LimitListIterator = @This();

decoder: Decoder,
remaining: u16,

pub fn next(self: *LimitListIterator) !?LimitListEntry {
    if (self.remaining == 0) {
        return null;
    }

    self.remaining -= 1;
    return try limits.decodeLimitListEntry(&self.decoder);
}
