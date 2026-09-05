//! Owns query entries until their bounded payload transfers into a result.

const std = @import("std");
const model = @import("model.zig");

test "result accumulation releases rejected entries and survives allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseOwnership, .{});
}

fn exerciseOwnership(gpa: std.mem.Allocator) !void {
    var accumulator: Accumulator = .{ .gpa = gpa, .limit = 1 };
    defer accumulator.deinit();
    const entry: model.Entry = .{
        .id = 1,
        .pane_id = @enumFromInt(1),
        .started_at_ms = 0,
        .duration_ns = 0,
        .exit_code = 0,
        .status = .completed,
        .author = .human,
        .command = try gpa.dupe(u8, "ls"),
        .cwd = &.{},
        .workspace_path = &.{},
    };
    try std.testing.expect(try accumulator.append(entry));
    var rejected = entry;
    rejected.command = try gpa.dupe(u8, "pwd");
    try std.testing.expect(!try accumulator.append(rejected));
    const query = try model.Query.init(.{
        .request_id = @enumFromInt(1),
        .origin = .{ .client = .{ .id = 1, .generation = 1 }, .close_after_reply = false },
    });
    const result = try accumulator.finish(&query, false);
    defer result.deinit();
    try std.testing.expect(result.has_more);
    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    try std.testing.expectEqual(@as(usize, 0), accumulator.entries.items.len);
}

pub const Accumulator = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(model.Entry) = .empty,
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
    pub fn append(accumulator: *Accumulator, owned: model.Entry) !bool {
        var entry = owned;
        const bytes = model.encoded_entry_overhead_bytes + entry.command.len + entry.cwd.len + entry.workspace_path.len + entry.provider.len;
        if (accumulator.entries.items.len == accumulator.limit or bytes > model.max_result_payload_bytes - accumulator.encoded_bytes) {
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
    pub fn finish(accumulator: *Accumulator, request: *const model.Query, more_candidates: bool) !*model.QueryResult {
        const result = try accumulator.gpa.create(model.QueryResult);
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
};
