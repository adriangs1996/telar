const core = @import("telar-core");
const PaneKey = @import("PaneKey.zig");
const pty = @import("pty");
const Command = pty.Command;
const GraphicsLimits = @import("../media/GraphicsLimits.zig");
const CreationRequest = @This();

identity: PaneKey,
location: core.TabLocation,
command: ?*const Command = null,
kind: core.PaneKind = .terminal,
restore_conversation: ?core.RecentConversation = null,
launch_cwd: []const u8,
workspace_path: []const u8,
size: core.TerminalSize,
graphics_limits: GraphicsLimits,
terminal_colors: core.TerminalColors = .{},
