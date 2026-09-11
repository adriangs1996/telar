const HistoryEntryIterator = @This();
const wire = @import("../wire.zig");
const source_namespace = @import("history.zig");
decoder: wire.Decoder,
remaining: u16,

pub fn next(iterator: *HistoryEntryIterator) !?source_namespace.HistoryEntry {
    if (iterator.remaining == 0) {
        return null;
    }
    iterator.remaining -= 1;
    return try source_namespace.decodeHistoryEntry(&iterator.decoder);
}
