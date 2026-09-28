//! What the login step of `telar machine setup` works on: the agents the
//! person has here, whether a terminal can answer, and the profiles file
//! where each login's outcome is kept.
const std = @import("std");
const values = @import("arguments/values.zig");
const LoginRequest = @This();

wanted: std.EnumSet(values.HookAgent),
/// Whether setup can ask for a pasted code and wait for the person.
interactive: bool,
profiles_path: []const u8,
