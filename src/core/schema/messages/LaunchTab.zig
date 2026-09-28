const id = @import("../id.zig");
const TerminalSize = @import("../TerminalSize.zig");
const Launch = @import("../Launch.zig");
/// Starts a command in a new tab of a workspace without attaching the sender
/// or taking the workspace's geometry, so a script opens a tab beside a
/// person without moving their focus to it.
const LaunchTab = @This();

request_id: id.RequestId,
workspace: id.WorkspaceId,
label: []const u8 = "",
size: TerminalSize,
launch: Launch,
