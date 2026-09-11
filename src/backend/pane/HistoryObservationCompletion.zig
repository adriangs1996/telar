const HistoryObservationCompletion = @This();
const agent_process = @import("../process/root.zig");
previous_process: agent_process.Cache,
cwd_changed: bool,
shell_foreground: bool,
