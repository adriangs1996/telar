const ClientKey = @import("../../history/ClientKey.zig");
const core = @import("telar-core");
const PendingClientCommand = @This();

target: ClientKey,
request_id: core.RequestId,
action: core.ClientAction,
target_id: u64,

/// Rejects mismatched completions without consuming the exchange. Example: `if (pending.accepts(sender, reply)) { ... }`
pub fn accepts(self: PendingClientCommand, sender: ClientKey, reply: core.ClientCommand) bool {
    return self.target.id == sender.id and self.target.generation == sender.generation and
        self.request_id == reply.request_id and self.action == reply.action and
        self.target_id == reply.target_id and reply.status != .request;
}

const std = @import("std");
test "client completions reject stale senders and unrelated requests" {
    const pending: PendingClientCommand = .{ .target = .{ .id = 7, .generation = 9 }, .request_id = @enumFromInt(5), .action = .workspace_select, .target_id = 42 };
    var reply: core.ClientCommand = .{ .route = .{ .id = 1, .generation = 2 }, .request_id = @enumFromInt(5), .action = .workspace_select, .target_id = 42, .status = .admitted };
    try std.testing.expect(pending.accepts(.{ .id = 7, .generation = 9 }, reply));
    try std.testing.expect(!pending.accepts(.{ .id = 7, .generation = 10 }, reply));
    reply.request_id = @enumFromInt(6);
    try std.testing.expect(!pending.accepts(pending.target, reply));
    reply.request_id = pending.request_id;
    reply.target_id = 43;
    try std.testing.expect(!pending.accepts(pending.target, reply));
    reply.target_id = 42;
    reply.status = .request;
    try std.testing.expect(!pending.accepts(pending.target, reply));
}
