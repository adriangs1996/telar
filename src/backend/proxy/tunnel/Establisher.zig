const Establisher = @This();
const Resources = @import("Resources.zig");
const exchange_mod = @import("exchange_support.zig");
const tls_tunnel = @import("../tls_tunnel.zig");
const source_namespace = @import("tls.zig");
const tls_transport = @import("../tls.zig");
resources: Resources,
exchange: *exchange_mod.Exchange,

/// Applies the interception allowlist or establishes an opaque tunnel.
/// Interception failures record their exact stage and publish one failed
/// exchange.
///
/// ```zig
/// const route = establisher.establish(.{
///     .host = host,
///     .child = child,
///     .origin = origin,
/// });
/// ```
pub fn establish(establisher: *Establisher, attempt: tls_tunnel.Attempt(source_namespace.net.Stream)) ?tls_tunnel.Route(*tls_transport.Session) {
    return source_namespace.Establish.execute(establisher, attempt);
}
