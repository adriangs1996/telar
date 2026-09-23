const id = @import("../id.zig");
const ImportEntryIterator = @import("ImportEntryIterator.zig");
const ImportHistoryView = @This();

request_id: id.RequestId,
source: []const u8,
base_sequence: u64,
entry_count: u16,
encoded_entries: []const u8,

pub fn entries(self: ImportHistoryView) ImportEntryIterator {
    return .{
        .decoder = .init(self.encoded_entries),
        .remaining = self.entry_count,
    };
}
