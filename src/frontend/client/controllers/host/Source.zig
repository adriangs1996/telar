const platform = @import("../../../platform/platform.zig");
const Source = @This();

tty: *const platform.Tty,
watcher: *platform.ResizeWatcher,
