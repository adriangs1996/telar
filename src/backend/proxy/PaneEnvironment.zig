const ChildEnvironmentType = @import("../pty/ChildEnvironment.zig");
/// Ephemeral child environment. Its proxy credential is scrubbed by
/// `pty.ChildEnvironment.deinit`; the runtime must not retain or inspect it.
const PaneEnvironment = @This();

value: ChildEnvironmentType,

/// Borrows the environment while this owner remains alive.
///
/// ```zig
/// const child_environment = pane_environment.environment();
/// ```
pub fn environment(pane_environment: *const PaneEnvironment) *const ChildEnvironmentType {
    return &pane_environment.value;
}

/// Scrubs and releases the ephemeral child environment.
///
/// ```zig
/// pane_environment.deinit();
/// ```
pub fn deinit(pane_environment: *PaneEnvironment) void {
    pane_environment.value.deinit();
}
