const pane_kind = @import("../pane_kind.zig");
const id = @import("../id.zig");
const types = @import("../types.zig");
const TerminalSize = @import("../TerminalSize.zig");
const Launch = @import("../Launch.zig");
const CreateTab = @This();

request_id: id.RequestId,
workspace: types.WorkspaceLocation,
label: []const u8 = "",
size: TerminalSize,
launch: Launch,

kind: pane_kind.PaneKind = .terminal,
