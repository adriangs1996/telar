//! A decoded `limit_list`, borrowing the frame's bytes.
const id = @import("../id.zig");
const LimitListIterator = @import("LimitListIterator.zig");
const LimitListView = @This();

request_id: id.RequestId,
entry_count: u8,
encoded_entries: []const u8,

/// Iterates the rows. Example: `var entries = view.entries();`
pub fn entries(self: LimitListView) LimitListIterator {
    return .{
        .decoder = .init(self.encoded_entries),
        .remaining = self.entry_count,
    };
}
