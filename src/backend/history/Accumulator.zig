const localsocket = @import("localsocket");
const std = @import("std");
const Entry = @import("Entry.zig");
const model = @import("model.zig");
const Query = @import("Query.zig");
const QueryResult = @import("QueryResult.zig");
const Accumulator = @This();

gpa: std.mem.Allocator,
entries: std.ArrayList(Entry) = .empty,
encoded_bytes: usize = model.encoded_result_header_bytes,
limit: usize,
has_more: bool = false,

/// Releases only entries that have not transferred into a result.
/// Example: `defer accumulator.deinit();`.
pub fn deinit(self: *Accumulator) void {
    for (self.entries.items) |*entry| {
        entry.deinit(self.gpa);
    }

    self.entries.deinit(self.gpa);
}

/// Takes ownership even on rejection or allocation failure.
/// Example: `if (!try accumulator.append(entry)) break;`.
pub fn append(self: *Accumulator, owned: Entry) !bool {
    var entry = owned;
    const bytes = model.encoded_entry_overhead_bytes + entry.command.len + entry.cwd.len + entry.workspace_path.len + entry.provider.len;
    if (self.entries.items.len == self.limit or bytes > localsocket.transport.max_frame_size - self.encoded_bytes) {
        entry.deinit(self.gpa);
        self.has_more = true;
        return false;
    }

    errdefer entry.deinit(self.gpa);
    try self.entries.append(self.gpa, entry);
    self.encoded_bytes += bytes;
    return true;
}

/// Transfers entries only after result allocation succeeds.
/// Example: `return accumulator.finish(request, more_candidates);`.
pub fn finish(self: *Accumulator, request: *const Query, more_candidates: bool) !*QueryResult {
    const result = try self.gpa.create(QueryResult);
    errdefer self.gpa.destroy(result);
    result.* = .{
        .request_id = request.request_id,
        .origin = request.origin,
        .snapshot_id = request.snapshot_id,
        .has_more = self.has_more or more_candidates,
        .entries = try self.entries.toOwnedSlice(self.gpa),
        .gpa = self.gpa,
    };
    return result;
}
