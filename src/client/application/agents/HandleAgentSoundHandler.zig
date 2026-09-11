const ModelType = @import("../../model/Model.zig");
const AgentSoundEffects = @import("AgentSoundEffects.zig");
const Command = @import("Command.zig");
const agent_sound = @import("agent_sound.zig");
const HandleAgentSoundHandler = @This();

model: *const ModelType,
effects: AgentSoundEffects,

/// Applies local sound policy only for an exact current agent identity.
///
/// ```zig
/// const outcome = try handler.execute(command);
/// ```
pub fn execute(handler: *HandleAgentSoundHandler, command: Command) !agent_sound.Outcome {
    if (!handler.model.knowsAgent(command.key)) {
        return .stale;
    }

    try handler.effects.schedule(handler.effects.context, command.sound);
    return .accepted;
}
