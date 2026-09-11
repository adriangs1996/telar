const Paths = @This();
const capture_module = @import("../capture/root.zig");
key: []const u8,
certificate: []const u8,
bundle: []const u8,
system_authority: bool = false,
intercept_hosts: []const []const u8 = &.{},
capture: capture_module.Config = .{},
