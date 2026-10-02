const exchangecapture = @import("exchangecapture");
const ConfigType = exchangecapture.Config;
const TunnelTestGate = @import("service/TunnelTestGate.zig");
const Config = @This();

key_path: []const u8,
certificate_path: []const u8,
bundle_path: []const u8,
/// The proxy secret file inside the proxy directory; created on first start.
secret_path: []const u8,
/// This runtime's remembered listener port inside the proxy directory,
/// keyed by its endpoint (`PortMemory.path`).
port_path: []const u8,
/// The listener port earlier versions shared, `proxy-port`; null unless this
/// runtime listens on the default socket and so inherits it.
legacy_port_path: ?[]const u8,
/// This runtime's socket path, recorded in its port file.
endpoint: []const u8,
system_authority: bool = false,
intercept_hosts: []const []const u8 = &.{},
capture: ConfigType = .{},
/// Test seam: holds a tunnel in a wait no cancellation interrupts.
tunnel_gate: ?*TunnelTestGate = null,
