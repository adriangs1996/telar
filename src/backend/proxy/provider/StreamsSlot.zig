const Observer = @import("Observer.zig");
const Slot = @This();

stream_id: u32 = 0,
observer: Observer = .{},
