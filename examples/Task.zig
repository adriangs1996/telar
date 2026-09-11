const sidebar = @import("sidebar.zig");
const Task = @This();

title: []const u8,
chip: sidebar.Chip,
/// Where the work is: a repository and branch, or a machine and a path.
place: []const u8,
place_detail: []const u8,
origin: sidebar.Origin,
status: sidebar.Status,
status_detail: []const u8,
/// The tool doing the work: `claude/opus`, `shell/vitest`.
tool: []const u8,
/// What it is saying about itself.
note: []const u8,
section: sidebar.Section,
