const core = @import("telar-core");
const console = @import("console");
const platform = console.platform;
const EventResources = @This();

tty: *const platform.Tty,
resize_watcher: *platform.ResizeWatcher,
heap: *const core.Heap,
