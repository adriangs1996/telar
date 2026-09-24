//! Public HTTP/2 relay capability for intercepted TLS connections.

const relay_mod = @import("relay.zig");
const GenericConnection = @import("GenericConnection.zig").Type;
const Rewrite = @import("../Rewrite.zig");
const std = @import("std");
const localca = @import("localca");
const Session = localca.Session;
const RouteMatch = @import("../RouteMatch.zig");
const IntegrationContext = @import("IntegrationContext.zig");
const middleware = @import("../middleware.zig");
const connection = @import("connection.zig");
const h2frames = @import("h2frames");
const streams = h2frames.streams;

pub const Direction = relay_mod.Direction;
pub const client_preface = relay_mod.client_preface;
pub const Stats = @import("Stats.zig");
pub const Lifecycle = @import("Lifecycle.zig");
pub const RequestBody = @import("RequestBody.zig");
pub const RequestFinished = @import("RequestFinished.zig");
pub const ResponseBody = @import("ResponseBody.zig");
pub const Event = relay_mod.Event;
const Settings = h2frames.Settings;

pub const Route = @import("H2Route.zig");

pub const Transformation = @import("Transformation.zig");

pub const Transform = @import("Transform.zig");

pub const RelayOptions = @import("RelayOptions.zig");

pub const RelayConfiguration = @import("RelayConfiguration.zig");

/// Builds the route and crossed peer settings for one relay direction.
///
/// ```zig
/// const request = relayOptions(.request, &settings, .{ .watched_routes = &inference_routes });
/// ```
pub fn relayOptions(direction: relay_mod.Direction, settings: *Settings, configuration: RelayConfiguration) RelayOptions {
    const route: Route = switch (direction) {
        .request => .{ .from = .child, .to = .origin, .direction = .request },
        .response => .{ .from = .origin, .to = .child, .direction = .response },
    };
    const source_settings, const target_settings = switch (direction) {
        .request => .{ &settings.child, &settings.origin },
        .response => .{ &settings.origin, &settings.child },
    };

    return .{
        .route = route,
        .watched_routes = configuration.watched_routes,
        .transformation = if (configuration.transformation) |selected| .{
            .source_settings = source_settings,
            .target_settings = target_settings,
            .rewrites = selected.rewrites,
        } else null,
    };
}

/// Relays one HTTP/2 direction and emits borrowed semantic events to `sink`.
/// Header transformation is selected by `options`; DATA and flow control stay
/// end to end in either mode.
///
/// ```zig
/// const stats = relay(session, .{
///     .route = .{ .from = .child, .to = .origin, .direction = .request },
///     .watched_routes = &inference_routes,
/// }, &sink);
/// ```
pub fn relay(session: anytype, options: RelayOptions, sink: anytype) Stats {
    const route = options.route;
    const transformation = options.transformation orelse return relay_mod.relay(
        session,
        .{
            .from = route.from,
            .to = route.to,
            .direction = route.direction,
            .watched_routes = options.watched_routes,
        },
        sink,
    );

    return relay_mod.relayTransformed(
        session,
        .{
            .route = .{
                .from = route.from,
                .to = route.to,
                .direction = route.direction,
                .watched_routes = options.watched_routes,
            },
            .source_settings = transformation.source_settings,
            .target_settings = transformation.target_settings,
            .rewrites = transformation.rewrites,
        },
        sink,
    );
}

test "relay options map direction and peer settings" {
    var settings: Settings = .{};
    const no_rewrites: []const Rewrite = &.{};

    const watched = [_]RouteMatch{.{ .method = "POST", .paths = &.{"/v1/messages"} }};
    const observed_request = relayOptions(.request, &settings, .{});
    try std.testing.expectEqual(Session.Side.child, observed_request.route.from);
    try std.testing.expectEqual(Session.Side.origin, observed_request.route.to);
    try std.testing.expectEqual(@as(usize, 0), observed_request.watched_routes.len);
    try std.testing.expect(observed_request.transformation == null);

    const request = relayOptions(.request, &settings, .{
        .watched_routes = &watched,
        .transformation = .{
            .rewrites = no_rewrites,
        },
    });
    try std.testing.expectEqual(Session.Side.child, request.route.from);
    try std.testing.expectEqual(Session.Side.origin, request.route.to);
    try std.testing.expect(request.watched_routes.ptr == &watched);
    try std.testing.expect(request.transformation.?.source_settings == &settings.child);
    try std.testing.expect(request.transformation.?.target_settings == &settings.origin);

    const response = relayOptions(.response, &settings, .{
        .transformation = .{
            .rewrites = no_rewrites,
        },
    });
    try std.testing.expectEqual(Session.Side.origin, response.route.from);
    try std.testing.expectEqual(Session.Side.child, response.route.to);
    try std.testing.expect(response.transformation.?.source_settings == &settings.origin);
    try std.testing.expect(response.transformation.?.target_settings == &settings.child);
}

const IntegrationConnection = GenericConnection(IntegrationContext);

test "HTTP2 connection composition relays both directions before settlement" {
    const settings_frame = "\x00\x00\x00\x04\x00\x00\x00\x00\x00";
    const request_header = "\x00\x00\x0f\x01\x04\x00\x00\x00\x01";
    const request_block = "\x83\x04\x0c/v1/messages";
    const request_wire = relay_mod.client_preface ++ settings_frame ++ request_header ++ request_block;
    var done_storage: [1]u8 = undefined;
    var done: std.Io.Queue(u8) = .init(&done_storage);
    var context: IntegrationContext = .{
        .session = .{
            .child_input = request_wire,
            .origin_input = settings_frame,
        },
        .request_done = &done,
    };

    IntegrationConnection.run(std.testing.io, &context);

    try std.testing.expectEqualStrings(request_wire, context.session.originOutput());
    try std.testing.expectEqualStrings(settings_frame, context.session.childOutput());
    try std.testing.expect(context.session.origin_half_closed);
    try std.testing.expect(context.session.child_half_closed);
    try std.testing.expectEqual(@as(u32, 3), context.event_count.load(.monotonic));
    try std.testing.expectEqual(middleware.Phase.request_started, context.request_phase.?);
    try std.testing.expectEqual(@as(u8, 0), context.decode_failures);
    try std.testing.expectEqual(@as(u8, 1), context.settlements);
}

test {
    std.testing.refAllDecls(connection);
    std.testing.refAllDecls(relay_mod);
    std.testing.refAllDecls(streams);
}
