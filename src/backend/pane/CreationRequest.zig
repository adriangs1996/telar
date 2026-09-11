const PaneKey = @import("PaneKey.zig");
const TabLocationType = @import("telar-core").TabLocation;
const CommandType = @import("../pty/Command.zig");
const TerminalSizeType = @import("telar-core").TerminalSize;
const GraphicsLimitsType = @import("../media/GraphicsLimits.zig");
const TerminalColorsType = @import("telar-core").TerminalColors;
const CreationRequest = @This();

identity: PaneKey,
location: TabLocationType,
command: *const CommandType,
launch_cwd: []const u8,
workspace_path: []const u8,
size: TerminalSizeType,
graphics_limits: GraphicsLimitsType,
terminal_colors: TerminalColorsType = .{},
