//! Public HTTP/2 relay capability for intercepted TLS connections.

const relay_mod = @import("relay.zig");
const StatsType = @import("Stats.zig");
const SettingsType = @import("Settings.zig");
const GenericConnectionPort = @import("GenericConnectionPort.zig").Type;
const GenericConnection = @import("GenericConnection.zig").Type;
const H2Route = @import("H2Route.zig");
const RelayOptionsType = @import("RelayOptions.zig");
const RelayConfigurationType = @import("RelayConfiguration.zig");
const TransformPipelineType = @import("../TransformPipeline.zig");
const TransformContextType = @import("../TransformContext.zig");
const std = @import("std");
const SessionType = @import("../Session.zig");
const types = @import("../../agent/types.zig");
const IntegrationContext = @import("IntegrationContext.zig");
const middleware = @import("../middleware.zig");
const connection = @import("connection.zig");
const streams = @import("streams.zig");

pub const Direction = relay_mod.Direction;
pub const client_preface = relay_mod.client_preface;
pub const Stats = @import("Stats.zig");
pub const Lifecycle = @import("Lifecycle.zig");
pub const HeaderBlock = @import("HeaderBlock.zig");
pub const HeaderField = @import("HeaderField.zig");
pub const RequestBody = @import("RequestBody.zig");
pub const RequestFinished = @import("RequestFinished.zig");
pub const ResponseBody = @import("ResponseBody.zig");
pub const Event = relay_mod.Event;
pub const PeerSettings = @import("PeerSettings.zig");
pub const Settings = @import("Settings.zig");

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
pub fn relayOptions(direction: relay_mod.Direction, settings: *SettingsType, configuration: RelayConfigurationType) RelayOptionsType {
    const route: H2Route = switch (direction) {
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
pub fn relay(session: anytype, options: RelayOptionsType, sink: anytype) StatsType {
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
    var settings: SettingsType = .{};
    var pipeline: TransformPipelineType = .{};
    const context: TransformContextType = undefined;

    const observed_request = relayOptions(.request, &settings, .{ .dialect = .unknown });
    try std.testing.expectEqual(SessionType.Side.child, observed_request.route.from);
    try std.testing.expectEqual(SessionType.Side.origin, observed_request.route.to);
    try std.testing.expectEqual(types.ApiDialect.unknown, observed_request.dialect);
    try std.testing.expect(observed_request.transformation == null);

    const request = relayOptions(.request, &settings, .{
        .dialect = .anthropic_messages,
        .transformation = .{
            .pipeline = &pipeline,
            .io = std.testing.io,
            .context = context,
        },
    });
    try std.testing.expectEqual(SessionType.Side.child, request.route.from);
    try std.testing.expectEqual(SessionType.Side.origin, request.route.to);
    try std.testing.expectEqual(types.ApiDialect.anthropic_messages, request.dialect);
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
    try std.testing.expectEqual(SessionType.Side.origin, response.route.from);
    try std.testing.expectEqual(SessionType.Side.child, response.route.to);
    try std.testing.expectEqual(types.ApiDialect.openai_responses, response.dialect);
    try std.testing.expect(response.transformation.?.source_settings == &settings.origin);
    try std.testing.expect(response.transformation.?.target_settings == &settings.child);
}

const integration_port: GenericConnectionPort(IntegrationContext) = .{
    .io = IntegrationContext.io,
    .relay_request = IntegrationContext.relayRequest,
    .relay_response = IntegrationContext.relayResponse,
    .record_decode_failure = IntegrationContext.recordDecodeFailure,
    .settle = IntegrationContext.settle,
};

const IntegrationConnection = GenericConnection(IntegrationContext, integration_port);

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
    std.testing.refAllDecls(streams);
}
