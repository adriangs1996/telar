const id = @import("../id.zig");
const ImportEntryIterator = @import("ImportEntryIterator.zig");
const ImportHistoryView = @This();

request_id: id.RequestId,
source: []const u8,
base_sequence: u64,
entry_count: u16,
encoded_entries: []const u8,

pub fn entries(view: ImportHistoryView) ImportEntryIterator {
    return .{
        .decoder = .init(view.encoded_entries),
        .remaining = view.entry_count,
    };
}
