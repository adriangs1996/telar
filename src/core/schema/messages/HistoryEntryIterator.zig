const Decoder = @import("../Decoder.zig");
const HistoryEntry = @import("../HistoryEntry.zig");
const history = @import("history.zig");
const HistoryEntryIterator = @This();

decoder: Decoder,
remaining: u16,

pub fn next(self: *HistoryEntryIterator) !?HistoryEntry {
    if (self.remaining == 0) {
        return null;
    }
    self.remaining -= 1;
    return try history.decodeHistoryEntry(&self.decoder);
}
