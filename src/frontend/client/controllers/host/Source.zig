const Source = @This();
const platform = @import("../../../platform/root.zig");
tty: *const platform.Tty,
watcher: *platform.ResizeWatcher,
