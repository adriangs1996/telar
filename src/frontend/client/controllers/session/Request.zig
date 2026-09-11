const platform = @import("../../../platform/platform.zig");
const Request = @This();

resize_watcher: *platform.ResizeWatcher,
