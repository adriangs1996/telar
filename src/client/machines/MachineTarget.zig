const RemoteMachine = @import("RemoteMachine.zig");
const RuntimeConfigSelection = @import("RuntimeConfigSelection.zig");

/// Which machine a client connects to: this one, whose runtime starts when
/// missing, or another over SSH.
pub const MachineTarget = union(enum) {
    local: RuntimeConfigSelection,
    remote: RemoteMachine,
};
