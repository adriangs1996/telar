//! The runtime decides audible agent transitions; every active UI client
//! receives them and only clients touch host audio.

const core = @import("telar-core");
const RuntimeModel = @import("RuntimeModel.zig");

/// Queues an agent sound for every active UI client.
///
/// ```zig
/// agent_sound.publish(model, .{ .pane_id = id, .pane_generation = generation, .sound = .done });
/// ```
pub fn publish(model: *RuntimeModel, notification: core.AgentSoundNotification) void {
    for (&model.clients.items) |*slot| {
        const recipient = slot.* orelse continue;

        if (!recipient.active() or recipient.role != .ui) {
            continue;
        }

        _ = recipient.delivery.responses.pushAgentSound(notification);
    }
}
