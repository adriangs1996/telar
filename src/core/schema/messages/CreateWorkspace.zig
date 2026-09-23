const id = @import("../id.zig");
const TerminalSize = @import("../TerminalSize.zig");
const Launch = @import("../Launch.zig");
/// Forces a named workspace identity at `launch.cwd`. Unlike `open_pane`, this
/// never attaches to an existing workspace with the same path. The name is
/// explicit and remains independent from pane cwd changes.
const CreateWorkspace = @This();

request_id: id.RequestId,
size: TerminalSize,
name: []const u8,
launch: Launch,
/// Asks the runtime to create `launch.cwd` before launching when the user
/// confirmed a directory that does not exist yet. Ignored with `cwd_source`.
create_cwd: bool = false,
