const TerminalSizeType = @import("telar-core").TerminalSize;
const OpenedPane = @import("OpenedPane.zig");
const WorkspaceCreation = @This();

requested_size: TerminalSizeType,
opened: OpenedPane,
