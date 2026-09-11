const ConfigType = @import("capture/Config.zig");
const Config = @This();

key_path: []const u8,
certificate_path: []const u8,
bundle_path: []const u8,
system_authority: bool = false,
intercept_hosts: []const []const u8 = &.{},
capture: ConfigType = .{},
