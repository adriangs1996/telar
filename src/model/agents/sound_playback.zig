//! Fixed-depth playback state for one disposable client.

const core = @import("telar-core");

pub fn coalesce(current: ?core.AgentSound, incoming: core.AgentSound) core.AgentSound {
    if (current == .needs_input or incoming == .needs_input) {
        return .needs_input;
    }

    return .ready;
}
