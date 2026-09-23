const platform = @import("../../platform/platform.zig");
const StartupRequest = @This();

resize_watcher: *platform.ResizeWatcher,
