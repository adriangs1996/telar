const Resources = @import("Resources.zig");
const Exchange = @import("Exchange.zig");
const GenericAttempt = @import("../GenericAttempt.zig").Type;
const std = @import("std");
const GenericRoute = @import("../GenericRoute.zig").Type;
const Session = @import("../Session.zig");
const tls = @import("tls.zig");
const Establisher = @This();

resources: Resources,
exchange: *Exchange,

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
pub fn establish(self: *Establisher, attempt: GenericAttempt(std.Io.net.Stream)) ?GenericRoute(*Session) {
    return tls.Establish.execute(self, attempt);
}
