/// The session file one agent's hooks point at.
const Registration = @This();
const source_namespace = @import("session_file.zig");
key: source_namespace.PaneKey,
session: source_namespace.SessionReference,
kind: source_namespace.Kind,
path: []const u8,
