const PaneKeyType = @import("../pane/PaneKey.zig");
const SessionReferenceType = @import("SessionReference.zig");
const AgentSessionFileKind = @import("telar-core").AgentSessionFileKind;
/// The session file one agent's hooks point at.
const Registration = @This();

key: PaneKeyType,
session: SessionReferenceType,
kind: AgentSessionFileKind,
path: []const u8,
