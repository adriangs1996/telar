//! Application transaction for selecting, launching, and attaching a pane.

const WorkspaceCreatedType = @import("../../../workspace/WorkspaceCreated.zig");
const PaneLaunchedType = @import("../../../pane/PaneLaunched.zig");

pub const RuntimeEvent = union(enum) {
    workspace_created: WorkspaceCreatedType,
    pane_launched: PaneLaunchedType,
};

pub fn mapLaunchError(spawn_error: anyerror) anyerror {
    return switch (spawn_error) {
        error.PaneLimitReached => error.PaneLimitReached,
        error.UnsupportedEnvironment => error.UnsupportedEnvironment,
        else => error.PaneSpawnFailed,
    };
}
