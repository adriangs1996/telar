const core = @import("telar-core");
const PaneKey = @import("../pane/PaneKey.zig");
const SessionReference = @import("SessionReference.zig");
/// The session file one agent's hooks point at.
const Registration = @This();

key: PaneKey,
session: SessionReference,
kind: core.AgentSessionFileKind,
path: []const u8,
