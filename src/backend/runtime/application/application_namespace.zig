//! Runtime model state and cross-capability invariants.

const core = @import("telar-core");
const GenericCheckpointer = @import("GenericCheckpointer.zig").Type;
const RuntimeModel = @import("../RuntimeModel.zig");
const GenericGitStatusObserver = @import("GenericGitStatusObserver.zig").Type;
const GenericSessionNameObserver = @import("GenericSessionNameObserver.zig").Type;
const GenericState = @import("../client/GenericState.zig").Type;
const std = @import("std");

pub const SessionCheckpoint = GenericCheckpointer(RuntimeModel);
pub const GitObserver = GenericGitStatusObserver(RuntimeModel);
pub const SessionNameObserver = GenericSessionNameObserver(RuntimeModel);

pub const ClientAdmissionState = GenericState(core.SocketChannel);


pub fn deinitWorkspaces(model: *RuntimeModel) void {
    var repository = model.workspaceRepository();
    repository.deinit();
}

test {
    std.testing.refAllDecls(@This());
}
