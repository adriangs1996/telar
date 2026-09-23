const core = @import("telar-core");
const platform = @import("../platform/platform.zig");
const EventResources = @This();

tty: *const platform.Tty,
resize_watcher: *platform.ResizeWatcher,
heap: *const core.Heap,
