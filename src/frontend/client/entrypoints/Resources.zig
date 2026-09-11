const platform = @import("../../platform/platform.zig");
const HeapType = @import("telar-core").Heap;
const Resources = @This();

tty: *const platform.Tty,
resize_watcher: *platform.ResizeWatcher,
heap: *const HeapType,
