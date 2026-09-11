//! Public HTTP/2 relay capability for intercepted TLS connections.

const std = @import("std");
const connection = @import("connection.zig");
const relay_mod = @import("relay.zig");
const middleware = @import("../middleware.zig");
const provider = @import("../provider/request_support.zig");
const tls = @import("../tls.zig");

pub const Direction = relay_mod.Direction;
pub const client_preface = relay_mod.client_preface;
pub const Stats = relay_mod.Stats;
pub const Lifecycle = relay_mod.Lifecycle;
pub const HeaderBlock = relay_mod.HeaderBlock;
pub const HeaderField = relay_mod.HeaderField;
pub const RequestBody = relay_mod.RequestBody;
pub const RequestFinished = relay_mod.RequestFinished;
pub const ResponseBody = relay_mod.ResponseBody;
pub const Event = relay_mod.Event;
pub const PeerSettings = relay_mod.PeerSettings;
pub const Settings = connection.Settings;
pub const ConnectionPort = connection.ConnectionPort;
pub const Connection = connection.Connection;

pub const Route = @import("H2Route.zig");

pub const Transformation = @import("Transformation.zig");

pub const Transform = @import("Transform.zig");

pub const RelayOptions = @import("RelayOptions.zig");

pub const RelayConfiguration = @import("RelayConfiguration.zig");

/// Builds the route and crossed peer settings for one relay direction.
///
/// ```zig
/// const request = relayOptions(.request, &settings, .{ .dialect = .anthropic_messages });
/// ```
pub fn relayOptions(direction: Direction, settings: *Settings, configuration: RelayConfiguration) RelayOptions {
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
        .dialect = configuration.dialect,
        .transformation = if (configuration.transformation) |selected| .{
            .source_settings = source_settings,
            .target_settings = target_settings,
            .pipeline = selected.pipeline,
            .io = selected.io,
            .context = selected.context,
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
///     .dialect = .anthropic_messages,
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
            .dialect = options.dialect,
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
                .dialect = options.dialect,
            },
            .source_settings = transformation.source_settings,
            .target_settings = transformation.target_settings,
            .pipeline = transformation.pipeline,
            .io = transformation.io,
            .transform_context = transformation.context,
        },
        sink,
    );
}

test "relay options map direction and peer settings" {
    var settings: Settings = .{};
    var pipeline: middleware.TransformPipeline = .{};
    const context: middleware.TransformContext = undefined;

    const observed_request = relayOptions(.request, &settings, .{ .dialect = .unknown });
    try std.testing.expectEqual(tls.Session.Side.child, observed_request.route.from);
    try std.testing.expectEqual(tls.Session.Side.origin, observed_request.route.to);
    try std.testing.expectEqual(provider.ApiDialect.unknown, observed_request.dialect);
    try std.testing.expect(observed_request.transformation == null);

    const request = relayOptions(.request, &settings, .{
        .dialect = .anthropic_messages,
        .transformation = .{
            .pipeline = &pipeline,
            .io = std.testing.io,
            .context = context,
        },
    });
    try std.testing.expectEqual(tls.Session.Side.child, request.route.from);
    try std.testing.expectEqual(tls.Session.Side.origin, request.route.to);
    try std.testing.expectEqual(provider.ApiDialect.anthropic_messages, request.dialect);
    try std.testing.expect(request.transformation.?.source_settings == &settings.child);
    try std.testing.expect(request.transformation.?.target_settings == &settings.origin);

    const response = relayOptions(.response, &settings, .{
        .dialect = .openai_responses,
        .transformation = .{
            .pipeline = &pipeline,
            .io = std.testing.io,
            .context = context,
        },
    });
    try std.testing.expectEqual(tls.Session.Side.origin, response.route.from);
    try std.testing.expectEqual(tls.Session.Side.child, response.route.to);
    try std.testing.expectEqual(provider.ApiDialect.openai_responses, response.dialect);
    try std.testing.expect(response.transformation.?.source_settings == &settings.origin);
    try std.testing.expect(response.transformation.?.target_settings == &settings.child);
}

const FakeSession = @import("FakeSession.zig");

const IntegrationContext = @import("IntegrationContext.zig");

const integration_port: ConnectionPort(IntegrationContext) = .{
    .io = IntegrationContext.io,
    .relay_request = IntegrationContext.relayRequest,
    .relay_response = IntegrationContext.relayResponse,
    .record_decode_failure = IntegrationContext.recordDecodeFailure,
    .settle = IntegrationContext.settle,
};

const IntegrationConnection = Connection(IntegrationContext, integration_port);

test "HTTP2 connection composition relays both directions before settlement" {
    const settings_frame = "\x00\x00\x00\x04\x00\x00\x00\x00\x00";
    const request_header = "\x00\x00\x0f\x01\x04\x00\x00\x00\x01";
    const request_block = "\x83\x04\x0c/v1/messages";
    const request_wire = client_preface ++ settings_frame ++ request_header ++ request_block;
    var done_storage: [1]u8 = undefined;
    var done: std.Io.Queue(u8) = .init(&done_storage);
    var context: IntegrationContext = .{
        .session = .{
            .child_input = request_wire,
            .origin_input = settings_frame,
        },
        .request_done = &done,
    };

    IntegrationConnection.run(&context);

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
    std.testing.refAllDecls(@import("streams.zig"));
}
