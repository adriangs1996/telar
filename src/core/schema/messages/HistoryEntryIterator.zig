const Decoder = @import("../Decoder.zig");
const HistoryEntry = @import("../HistoryEntry.zig");
const history = @import("history.zig");
const HistoryEntryIterator = @This();

decoder: Decoder,
remaining: u16,

pub fn next(iterator: *HistoryEntryIterator) !?HistoryEntry {
    if (iterator.remaining == 0) {
        return null;
    }
    iterator.remaining -= 1;
    return try history.decodeHistoryEntry(&iterator.decoder);
}
