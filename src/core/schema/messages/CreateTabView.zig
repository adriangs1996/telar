const pane_kind = @import("../pane_kind.zig");
const id = @import("../id.zig");
const types = @import("../types.zig");
const TerminalSizeType = @import("../TerminalSize.zig");
const LaunchViewType = @import("LaunchView.zig");
const CreateTabView = @This();

request_id: id.RequestId,
workspace: types.WorkspaceLocation,
label: []const u8,
size: TerminalSizeType,
launch: LaunchViewType,

kind: pane_kind.PaneKind = .terminal,
