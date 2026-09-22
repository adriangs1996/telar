const core = @import("telar-core");
const std = @import("std");
const history = @import("history.zig");
const ImportedEntry = @import("ImportedEntry.zig");
/// Accumulates entries and sends one bounded import_history request per
/// batch, waiting for each acknowledgement before the next batch.
const BatchSender = @This();

io: std.Io,
gpa: std.mem.Allocator,
connection: *core.SocketChannel,
source: []const u8,
entries: [core.max_import_entries]core.ImportEntry = undefined,
storage: [history.max_batch_payload]u8 = undefined,
used: usize = 0,
count: usize = 0,
sequence: u64 = 0,
total: u64 = 0,
next_request: u64 = 1,

pub fn push(sender: *BatchSender, entry: ImportedEntry) !void {
    if (entry.command.len == 0 or entry.command.len > core.max_import_command_bytes) {
        return;
    }
    if (sender.count == core.max_import_entries or entry.command.len > sender.storage.len - sender.used) {
        try sender.finish();
    }

    const copy = sender.storage[sender.used .. sender.used + entry.command.len];
    @memcpy(copy, entry.command);
    sender.used += entry.command.len;
    sender.entries[sender.count] = .{ .started_at_ms = entry.started_at_ms, .command = copy };
    sender.count += 1;
}

pub fn finish(sender: *BatchSender) !void {
    if (sender.count == 0) {
        return;
    }

    var send_buffer: [history.max_batch_payload + 1024]u8 = undefined;
    const request_id: core.RequestId = @enumFromInt(sender.next_request);
    sender.next_request += 1;
    try sender.connection.send(sender.io, try core.encodeImportHistory(&send_buffer, .{
        .request_id = request_id,
        .source = sender.source,
        .base_sequence = sender.sequence,
        .entries = sender.entries[0..sender.count],
    }));

    var receive_buffer: [1024]u8 = undefined;
    const response = try core.decodeServer(try sender.connection.receive(sender.io, &receive_buffer));
    switch (response) {
        .request_completed => {},
        .request_failed => |failure| {
            std.debug.print("telar history import: {s}\n", .{failure.message});
            return error.HistoryImportFailed;
        },
        else => return error.UnexpectedRuntimeResponse,
    }

    sender.sequence += sender.count;
    sender.total += sender.count;
    sender.count = 0;
    sender.used = 0;
}
