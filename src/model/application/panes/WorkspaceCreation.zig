const core = @import("telar-core");
const OpenedPane = @import("OpenedPane.zig");
const WorkspaceCreation = @This();

requested_size: core.TerminalSize,
opened: OpenedPane,
