const exchangecapture = @import("exchangecapture");
const Config = exchangecapture.Config;
const Paths = @This();

key: []const u8,
certificate: []const u8,
bundle: []const u8,
system_authority: bool = false,
intercept_hosts: []const []const u8 = &.{},
capture: Config = .{},
