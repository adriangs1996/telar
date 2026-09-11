const OpenedPane = @import("OpenedPane.zig");
const WorkspaceCreation = @import("WorkspaceCreation.zig");
const PaneSplitConfirmation = @import("PaneSplitConfirmation.zig");
const PaneAttachmentConfirmation = @import("PaneAttachmentConfirmation.zig");
const Effects = @This();

context: *anyopaque,
arrive_workspace: *const fn (*anyopaque, OpenedPane) anyerror!void,
create_workspace: *const fn (*anyopaque, WorkspaceCreation) anyerror!void,
confirm_split: *const fn (*anyopaque, PaneSplitConfirmation) anyerror!void,
confirm_attachment: *const fn (*anyopaque, PaneAttachmentConfirmation) anyerror!void,
