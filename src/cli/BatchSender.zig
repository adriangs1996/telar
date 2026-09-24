const localsocket = @import("localsocket");
const core = @import("telar-core");
const std = @import("std");
const history = @import("history.zig");
const ImportedEntry = @import("ImportedEntry.zig");
/// Accumulates entries and sends one bounded import_history request per
/// batch, waiting for each acknowledgement before the next batch.
const BatchSender = @This();

io: std.Io,
gpa: std.mem.Allocator,
connection: *localsocket.SocketChannel,
source: []const u8,
entries: [core.max_import_entries]core.ImportEntry = undefined,
storage: [history.max_batch_payload]u8 = undefined,
used: usize = 0,
count: usize = 0,
sequence: u64 = 0,
total: u64 = 0,
next_request: u64 = 1,

pub fn push(self: *BatchSender, entry: ImportedEntry) !void {
    if (entry.command.len == 0 or entry.command.len > core.max_import_command_bytes) {
        return;
    }
    if (self.count == core.max_import_entries or entry.command.len > self.storage.len - self.used) {
        try self.finish();
    }

    const copy = self.storage[self.used .. self.used + entry.command.len];
    @memcpy(copy, entry.command);
    self.used += entry.command.len;
    self.entries[self.count] = .{ .started_at_ms = entry.started_at_ms, .command = copy };
    self.count += 1;
}

pub fn finish(self: *BatchSender) !void {
    if (self.count == 0) {
        return;
    }

    var send_buffer: [history.max_batch_payload + 1024]u8 = undefined;
    const request_id: core.RequestId = @enumFromInt(self.next_request);
    self.next_request += 1;
    try self.connection.send(self.io, try core.encodeImportHistory(&send_buffer, .{
        .request_id = request_id,
        .source = self.source,
        .base_sequence = self.sequence,
        .entries = self.entries[0..self.count],
    }));

    var receive_buffer: [1024]u8 = undefined;
    const response = try core.decodeServer(try self.connection.receive(self.io, &receive_buffer));
    switch (response) {
        .request_completed => {},
        .request_failed => |failure| {
            std.debug.print("telar history import: {s}\n", .{failure.message});
            return error.HistoryImportFailed;
        },
        else => return error.UnexpectedRuntimeResponse,
    }

    self.sequence += self.count;
    self.total += self.count;
    self.count = 0;
    self.used = 0;
}
