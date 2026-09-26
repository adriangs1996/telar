const exchangecapture = @import("exchangecapture");
const ConfigType = exchangecapture.Config;
const Config = @This();

key_path: []const u8,
certificate_path: []const u8,
bundle_path: []const u8,
/// The proxy secret file inside the proxy directory; created on first start.
secret_path: []const u8,
/// The remembered listener port inside the proxy directory.
port_path: []const u8,
system_authority: bool = false,
intercept_hosts: []const []const u8 = &.{},
capture: ConfigType = .{},
