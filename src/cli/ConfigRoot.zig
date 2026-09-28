//! Where an agent keeps its configuration: `environment` overrides the
//! directory on this machine, `directory` is relative to the home on both.
const ConfigRoot = @This();

environment: ?[]const u8,
/// Appended to the environment variable's value, for XDG bases.
environment_suffix: []const u8 = "",
directory: []const u8,
