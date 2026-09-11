const Config = @This();
const capture_mod = @import("capture/root.zig");
key_path: []const u8,
certificate_path: []const u8,
bundle_path: []const u8,
system_authority: bool = false,
intercept_hosts: []const []const u8 = &.{},
capture: capture_mod.Config = .{},
