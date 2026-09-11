const id = @import("../id.zig");
const types = @import("../types.zig");
const TerminalSizeType = @import("../TerminalSize.zig");
const LaunchType = @import("../Launch.zig");
/// Opens the default pane in the workspace implied by `launch.cwd`, creating
/// it when none exists, or attaches to a specific existing pane. This makes
/// attach-or-create atomic.
const OpenPane = @This();

request_id: id.RequestId,
target: types.PaneTarget = .default,
size: TerminalSizeType,
launch: ?LaunchType,
