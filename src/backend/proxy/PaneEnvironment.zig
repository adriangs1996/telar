const pty = @import("pty");
const ChildEnvironment = pty.ChildEnvironment;
/// Ephemeral child environment. Its proxy credential is scrubbed by
/// `pty.ChildEnvironment.deinit`; the runtime must not retain or inspect it.
const PaneEnvironment = @This();

value: ChildEnvironment,

/// Borrows the environment while this owner remains alive.
///
/// ```zig
/// const child_environment = pane_environment.environment();
/// ```
pub fn environment(self: *const PaneEnvironment) *const ChildEnvironment {
    return &self.value;
}

/// Scrubs and releases the ephemeral child environment.
///
/// ```zig
/// pane_environment.deinit();
/// ```
pub fn deinit(self: *PaneEnvironment) void {
    self.value.deinit();
}
