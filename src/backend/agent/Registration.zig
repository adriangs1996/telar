const core = @import("telar-core");
const PaneKeyType = @import("../pane/PaneKey.zig");
const SessionReferenceType = @import("SessionReference.zig");
/// The session file one agent's hooks point at.
const Registration = @This();

key: PaneKeyType,
session: SessionReferenceType,
kind: core.AgentSessionFileKind,
path: []const u8,
