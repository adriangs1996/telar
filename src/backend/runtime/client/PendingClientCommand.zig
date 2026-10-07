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
