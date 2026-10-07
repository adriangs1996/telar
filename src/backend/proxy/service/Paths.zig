const exchangecapture = @import("exchangecapture");
const Config = exchangecapture.Config;

key: []const u8,
certificate: []const u8,
bundle: []const u8,
/// The proxy secret file; created on first start.
secret: []const u8,
/// This runtime's remembered listener port, keyed by its endpoint
/// (`PortMemory.path`); rewritten on every start.
port: []const u8,
/// The listener port earlier versions shared between every runtime; set
/// only for the runtime on the default socket, which inherits it.
legacy_port: ?[]const u8,
/// This runtime's socket path, recorded beside its port.
endpoint: []const u8,
system_authority: bool = false,
intercept_hosts: []const []const u8 = &.{},
/// Admits a CONNECT without credentials when the proxy does not intercept
/// its host: the tunnel stays opaque, so nothing anonymous reaches capture.
anonymous_tunnels: bool = false,
capture: Config = .{},
