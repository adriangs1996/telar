const exchangecapture = @import("exchangecapture");
const Config = exchangecapture.Config;
const Paths = @This();

key: []const u8,
certificate: []const u8,
bundle: []const u8,
/// The proxy secret file; created on first start.
secret: []const u8,
/// This runtime's remembered listener port, keyed by its endpoint
/// (`PortMemory.path`); rewritten on every start.
port: []const u8,
/// The listener port earlier versions shared between every runtime; read
/// until this runtime migrates off it.
legacy_port: []const u8,
system_authority: bool = false,
intercept_hosts: []const []const u8 = &.{},
capture: Config = .{},
