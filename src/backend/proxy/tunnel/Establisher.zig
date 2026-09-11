const Resources = @import("Resources.zig");
const ExchangeType = @import("Exchange.zig");
const GenericAttempt = @import("../GenericAttempt.zig").Type;
const std = @import("std");
const GenericRoute = @import("../GenericRoute.zig").Type;
const SessionType = @import("../Session.zig");
const tls = @import("tls.zig");
const Establisher = @This();

resources: Resources,
exchange: *ExchangeType,

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
pub fn establish(establisher: *Establisher, attempt: GenericAttempt(std.Io.net.Stream)) ?GenericRoute(*SessionType) {
    return tls.Establish.execute(establisher, attempt);
}
