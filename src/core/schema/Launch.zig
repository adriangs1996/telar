const id = @import("id.zig");
const types = @import("types.zig");
const EnvironmentEntry = @import("EnvironmentEntry.zig");
const Launch = @This();

cwd: []const u8,
/// When present, the runtime resolves the launch cwd from this attached
/// pane. `cwd` remains the explicit launch path for callers that do not
/// request inheritance.
cwd_source: ?id.PaneId = null,
arguments: []const []const u8,
environment_mode: types.EnvironmentMode = .inherit_runtime,
environment: []const EnvironmentEntry = &.{},
