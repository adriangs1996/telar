/// One owned batch of imported foreign history. The session identity is
/// derived deterministically from the source label, so re-imports reuse the
/// same session and `INSERT OR IGNORE` keeps them idempotent.
const ImportBatch = @This();
const source_namespace = @import("model.zig");
const std = @import("std");
session_id: source_namespace.SessionId,
pane_id: source_namespace.schema.PaneId,
location: source_namespace.schema.TabLocation,
base_sequence: u64,
started_at_ms: i64,
source: []u8,
times: []i64,
commands: [][]u8,

pub fn init(gpa: std.mem.Allocator, view: source_namespace.schema.ImportHistoryView) !*ImportBatch {
    const batch = try gpa.create(ImportBatch);
    errdefer gpa.destroy(batch);
    const seed_low = std.hash.Wyhash.hash(0x74656c6172_696d70, view.source);
    const seed_high = std.hash.Wyhash.hash(seed_low, view.source);
    var session_id: source_namespace.SessionId = undefined;
    std.mem.writeInt(u64, session_id[0..8], seed_low, .little);
    std.mem.writeInt(u64, session_id[8..16], seed_high, .little);
    // Masked to stay positive as SQLite's i64; bit zero keeps it nonzero.
    const synthetic = (seed_low & ((@as(u64, 1) << 62) - 1)) | 1;

    const source = try gpa.dupe(u8, view.source);
    errdefer gpa.free(source);
    const times = try gpa.alloc(i64, view.entry_count);
    errdefer gpa.free(times);
    const commands = try gpa.alloc([]u8, view.entry_count);
    var copied: usize = 0;
    errdefer {
        for (commands[0..copied]) |command| gpa.free(command);
        gpa.free(commands);
    }
    var iterator = view.entries();
    var first_time: i64 = 0;
    while (try iterator.next()) |entry| {
        times[copied] = entry.started_at_ms;
        if (copied == 0) {
            first_time = entry.started_at_ms;
        }

        commands[copied] = try gpa.dupe(u8, entry.command);
        copied += 1;
    }
    if (copied != view.entry_count) {
        return error.InvalidImportBatch;
    }

    batch.* = .{
        .session_id = session_id,
        .pane_id = @enumFromInt(synthetic),
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(synthetic) },
            .tab_id = @enumFromInt(synthetic),
        },
        .base_sequence = view.base_sequence,
        .started_at_ms = first_time,
        .source = source,
        .times = times,
        .commands = commands,
    };
    return batch;
}

pub fn deinit(batch: *ImportBatch, gpa: std.mem.Allocator) void {
    for (batch.commands) |command| gpa.free(command);
    gpa.free(batch.commands);
    gpa.free(batch.times);
    gpa.free(batch.source);
    gpa.destroy(batch);
}
