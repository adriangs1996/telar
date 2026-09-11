const Task = @This();
const source_namespace = @import("sidebar.zig");
title: []const u8,
chip: source_namespace.Chip,
/// Where the work is: a repository and branch, or a machine and a path.
place: []const u8,
place_detail: []const u8,
origin: source_namespace.Origin,
status: source_namespace.Status,
status_detail: []const u8,
/// The tool doing the work: `claude/opus`, `shell/vitest`.
tool: []const u8,
/// What it is saying about itself.
note: []const u8,
section: source_namespace.Section,
