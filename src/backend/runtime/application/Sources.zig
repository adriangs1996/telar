const PaneStoreType = @import("../../pane/PaneStore.zig");
const ReaderType = @import("../../workspace/Reader.zig");
const Sources = @This();

panes: *const PaneStoreType,
workspaces: ReaderType,
