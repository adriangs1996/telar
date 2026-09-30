//! A decoded `limit_list`, borrowing the frame's bytes.
const id = @import("../id.zig");
const LimitListIterator = @import("LimitListIterator.zig");
const LimitListView = @This();

request_id: id.RequestId,
/// Runtime rows replaced by newer limits.
runtime_evicted: u64,
/// Client rows replaced by newer limits.
client_evicted: u64,
/// Client reports the runtime refused.
refused_reports: u64,
entry_count: u16,
encoded_entries: []const u8,

/// Iterates the rows. Example: `var entries = view.entries();`
pub fn entries(self: LimitListView) LimitListIterator {
    return .{
        .decoder = .init(self.encoded_entries),
        .remaining = self.entry_count,
    };
}
