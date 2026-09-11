//! Audible policy for committed agent status transitions.

const AgentStatusType = @import("telar-core").AgentStatus;
const AgentSoundType = @import("telar-core").AgentSound;

/// Maps a committed transition to optional host sound.
/// Example: `const sound = soundForTransition(.working, .ready);`.
pub fn soundForTransition(previous: ?AgentStatusType, current: ?AgentStatusType) ?AgentSoundType {
    if (previous != .working) {
        return null;
    }

    return switch (current orelse return null) {
        .ready, .done => .ready,
        .blocked => .needs_input,
        .unknown, .working, .failed => null,
    };
}
