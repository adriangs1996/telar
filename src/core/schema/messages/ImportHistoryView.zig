const ImportHistoryView = @This();
const source_namespace = @import("history.zig");
const ImportEntryIterator = @import("ImportEntryIterator.zig");
request_id: source_namespace.RequestId,
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
