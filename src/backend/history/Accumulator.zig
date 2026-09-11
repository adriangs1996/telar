const std = @import("std");
const EntryType = @import("Entry.zig");
const model = @import("model.zig");
const max_frame_size = @import("telar-core").max_frame_size;
const QueryType = @import("Query.zig");
const QueryResultType = @import("QueryResult.zig");
const Accumulator = @This();

gpa: std.mem.Allocator,
entries: std.ArrayList(EntryType) = .empty,
encoded_bytes: usize = model.encoded_result_header_bytes,
limit: usize,
has_more: bool = false,

/// Releases only entries that have not transferred into a result.
/// Example: `defer accumulator.deinit();`.
pub fn deinit(accumulator: *Accumulator) void {
    for (accumulator.entries.items) |*entry| {
        entry.deinit(accumulator.gpa);
    }

    accumulator.entries.deinit(accumulator.gpa);
}

/// Takes ownership even on rejection or allocation failure.
/// Example: `if (!try accumulator.append(entry)) break;`.
pub fn append(accumulator: *Accumulator, owned: EntryType) !bool {
    var entry = owned;
    const bytes = model.encoded_entry_overhead_bytes + entry.command.len + entry.cwd.len + entry.workspace_path.len + entry.provider.len;
    if (accumulator.entries.items.len == accumulator.limit or bytes > max_frame_size - accumulator.encoded_bytes) {
        entry.deinit(accumulator.gpa);
        accumulator.has_more = true;
        return false;
    }

    errdefer entry.deinit(accumulator.gpa);
    try accumulator.entries.append(accumulator.gpa, entry);
    accumulator.encoded_bytes += bytes;
    return true;
}

/// Transfers entries only after result allocation succeeds.
/// Example: `return accumulator.finish(request, more_candidates);`.
pub fn finish(accumulator: *Accumulator, request: *const QueryType, more_candidates: bool) !*QueryResultType {
    const result = try accumulator.gpa.create(QueryResultType);
    errdefer accumulator.gpa.destroy(result);
    result.* = .{
        .request_id = request.request_id,
        .origin = request.origin,
        .snapshot_id = request.snapshot_id,
        .has_more = accumulator.has_more or more_candidates,
        .entries = try accumulator.entries.toOwnedSlice(accumulator.gpa),
        .gpa = accumulator.gpa,
    };
    return result;
}
