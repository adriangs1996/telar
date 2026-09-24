const Fragment = @import("Fragment.zig");
const IgnoreTestObserver = @This();

pub fn head(_: IgnoreTestObserver, _: []const u8) void {}

pub fn observe(_: IgnoreTestObserver, _: Fragment) void {}
