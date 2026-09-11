const Resources = @This();
const platform = @import("../../platform/root.zig");
const source_namespace = @import("events.zig");
tty: *const platform.Tty,
resize_watcher: *platform.ResizeWatcher,
heap: *const source_namespace.diagnostics.Heap,
