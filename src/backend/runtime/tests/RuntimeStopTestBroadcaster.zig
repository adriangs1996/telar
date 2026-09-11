const Broadcaster = @This();
const Recipient = @import("Recipient.zig");
const shutdown_mod = @import("../lifecycle/root.zig").shutdown_authority;
const runtime_stop_commands = @import("../application/commands/runtime_stop.zig");
recipients: [3]*Recipient,
calls: usize = 0,
event: ?shutdown_mod.StopRequested = null,

pub fn notifications(broadcaster: *Broadcaster) runtime_stop_commands.Notifications {
    return .{ .context = broadcaster, .publish_fn = publish };
}

fn publish(context: *anyopaque, event: shutdown_mod.StopRequested) void {
    const broadcaster: *Broadcaster = @ptrCast(@alignCast(context));
    broadcaster.calls += 1;
    broadcaster.event = event;

    for (broadcaster.recipients) |recipient| {
        if (recipient.active) {
            recipient.delivery.requestStop();
        }
    }
}
