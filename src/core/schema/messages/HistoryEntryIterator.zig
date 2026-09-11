const DecoderType = @import("../Decoder.zig");
const HistoryEntryType = @import("../HistoryEntry.zig");
const history = @import("history.zig");
const HistoryEntryIterator = @This();

decoder: DecoderType,
remaining: u16,

pub fn next(iterator: *HistoryEntryIterator) !?HistoryEntryType {
    if (iterator.remaining == 0) {
        return null;
    }
    iterator.remaining -= 1;
    return try history.decodeHistoryEntry(&iterator.decoder);
}
