const Cache = @import("../process/Cache.zig");
const HistoryObservationCompletion = @This();

previous_process: Cache,
cwd_changed: bool,
shell_foreground: bool,
