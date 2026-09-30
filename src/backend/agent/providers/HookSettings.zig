/// Where `telar integration install` writes an agent's hooks, and the text
/// that marks telar's own entries in that file.
const HookSettings = @This();

/// Variable that names the agent's configuration directory, when set.
environment: []const u8,
/// Configuration directory under the home directory otherwise.
home_directory: []const u8,
file: []const u8,
/// The end of the command telar installs, `... hook <agent>`.
marker: []const u8,
