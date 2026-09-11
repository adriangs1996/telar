const CacheType = @import("../process/Cache.zig");
const HistoryObservationCompletion = @This();

previous_process: CacheType,
cwd_changed: bool,
shell_foreground: bool,
