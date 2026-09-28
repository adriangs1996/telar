const WorkspaceCreation = @This();

name: []const u8,
cwd: []const u8,
arguments: []const []const u8,
/// The first pane's width until a window attaches and sizes it.
columns: u16 = 80,
