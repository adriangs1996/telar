const core = @import("telar-core");
const PaneKey = @import("PaneKey.zig");
const pty = @import("pty");
const Command = pty.Command;
const GraphicsLimits = @import("../media/GraphicsLimits.zig");
const CreationRequest = @This();

identity: PaneKey,
location: core.TabLocation,
command: *const Command,
launch_cwd: []const u8,
workspace_path: []const u8,
size: core.TerminalSize,
graphics_limits: GraphicsLimits,
terminal_colors: core.TerminalColors = .{},
