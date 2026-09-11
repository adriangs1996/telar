const GateState = @This();
const identity = @import("../identity.zig");
generation: u64 = 1,

pub fn accepts(context: *anyopaque, credential: *const identity.Credential) bool {
    const state: *const GateState = @ptrCast(@alignCast(context));
    return credential.pane_generation == state.generation;
}
