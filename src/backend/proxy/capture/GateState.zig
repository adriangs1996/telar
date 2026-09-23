const Credential = @import("../Credential.zig");
const GateState = @This();

generation: u64 = 1,

pub fn accepts(context: *anyopaque, credential: *const Credential) bool {
    const state: *const GateState = @ptrCast(@alignCast(context));
    return credential.pane_generation == state.generation;
}
