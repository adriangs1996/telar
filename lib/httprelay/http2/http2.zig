//! Public HTTP/2 relay capability for intercepted TLS connections.

const relay_mod = @import("relay.zig");
pub const GenericConnection = @import("GenericConnection.zig").Type;

pub const Direction = relay_mod.Direction;
pub const client_preface = relay_mod.client_preface;
pub const max_header_block_bytes = relay_mod.max_header_block_bytes;
pub const Stats = @import("Stats.zig");
pub const Lifecycle = @import("Lifecycle.zig");
pub const RequestBody = @import("RequestBody.zig");
pub const RequestFinished = @import("RequestFinished.zig");
pub const ResponseBody = @import("ResponseBody.zig");
pub const Event = relay_mod.Event;

pub const Route = @import("H2Route.zig");


pub const RelayOptions = @import("RelayOptions.zig");

pub const RelayConfiguration = @import("RelayConfiguration.zig");

/// Builds the route for one relay direction.
///
/// ```zig
/// const request = relayOptions(.request, .{ .gpa = gpa, .watched_routes = &inference_routes });
/// ```
pub fn relayOptions(direction: relay_mod.Direction, configuration: RelayConfiguration) RelayOptions {
    const route: Route = switch (direction) {
        .request => .{ .from = .child, .to = .origin, .direction = .request },
        .response => .{ .from = .origin, .to = .child, .direction = .response },
    };

    return .{
        .route = route,
        .gpa = configuration.gpa,
        .watched_routes = configuration.watched_routes,
    };
}

/// Relays one HTTP/2 direction byte for byte and emits borrowed semantic
/// events to `sink`.
///
/// ```zig
/// const stats = relay(session, .{
///     .route = .{ .from = .child, .to = .origin, .direction = .request },
///     .gpa = gpa,
///     .watched_routes = &inference_routes,
/// }, &sink);
/// ```
pub fn relay(session: anytype, options: RelayOptions, sink: anytype) Stats {
    const route = options.route;
    return relay_mod.relay(
        session,
        .{
            .from = route.from,
            .to = route.to,
            .direction = route.direction,
            .gpa = options.gpa,
            .watched_routes = options.watched_routes,
        },
        sink,
    );
}
