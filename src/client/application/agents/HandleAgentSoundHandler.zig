const HandleAgentSoundHandler = @This();
const client_model = @import("../../root.zig").model;
const Effects = @import("AgentSoundEffects.zig");
const Command = @import("Command.zig");
const source_namespace = @import("agent_sound.zig");
model: *const client_model.Model,
effects: Effects,

/// Applies local sound policy only for an exact current agent identity.
///
/// ```zig
/// const outcome = try handler.execute(command);
/// ```
pub fn execute(handler: *HandleAgentSoundHandler, command: Command) !source_namespace.Outcome {
    if (!handler.model.knowsAgent(command.key)) {
        return .stale;
    }

    try handler.effects.schedule(handler.effects.context, command.sound);
    return .accepted;
}
