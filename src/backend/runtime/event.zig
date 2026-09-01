//! Events delivered to the runtime loop and their execution-budget class.

const std = @import("std");
const core = @import("telar-core");
const agent = @import("../agent/root.zig");
const history = @import("../history/root.zig");
const proxy = @import("../proxy/root.zig");
const client_session = @import("client/root.zig").session;
const pane_events = @import("entrypoints/events/pane/root.zig");
const pane_launcher = @import("application/pane_launcher.zig");

const diagnostics = core.diagnostics;

pub const ClientMessage = struct {
    client: client_session.Key,
    result: anyerror![]u8,
};

pub const ClientSent = struct {
    client: client_session.Key,
    result: anyerror!void,
};

pub const Event = union(enum) {
    accepted: anyerror!core.transport.SocketChannel,
    handshaken: anyerror!void,
    client_message: ClientMessage,
    client_sent: ClientSent,
    history_response: anyerror!history.Response,
    pane_input_written: pane_events.input.Completion,
    pane_response_written: pane_events.response.Completion,
    pane_output: pane_launcher.PaneOutputEvent,
    pane_ingested: pane_events.ingest.Completion,
    pane_observed: pane_events.observation.Completion,
    pane_media: pane_events.media.Completion,
    pane_exit: pane_launcher.PaneExitEvent,
    telemetry_tick: anyerror!void,
    telemetry_written: anyerror!void,
    proxy_event: anyerror!proxy.Observation,
    agent_tick: anyerror!void,
    agent_description: agent.description.Result,
    metrics_tick: anyerror!void,
    checkpoint_written: anyerror!void,
    stopped: anyerror!void,
};

/// Returns the latency budget used to diagnose one event while it is handled.
///
/// ```zig
/// const path = diagnosticsPath(event);
/// diagnostics.record(path, elapsed_ns);
/// ```
pub fn diagnosticsPath(event: Event) diagnostics.Path {
    return diagnosticsPathForTag(std.meta.activeTag(event));
}

fn diagnosticsPathForTag(tag: std.meta.Tag(Event)) diagnostics.Path {
    return switch (tag) {
        .pane_output,
        .pane_ingested,
        .pane_input_written,
        .pane_response_written,
        .client_message,
        .client_sent,
        => .interactive,
        .pane_media => .media,
        .pane_observed,
        .history_response,
        .proxy_event,
        .agent_tick,
        .agent_description,
        .metrics_tick,
        .telemetry_tick,
        .telemetry_written,
        .checkpoint_written,
        => .observation,
        .accepted,
        .handshaken,
        .pane_exit,
        .stopped,
        => .other,
    };
}

test "interactive events use the interactive budget" {
    const tags = [_]std.meta.Tag(Event){
        .pane_output,
        .pane_ingested,
        .pane_input_written,
        .pane_response_written,
        .client_message,
        .client_sent,
    };

    for (tags) |tag| {
        try std.testing.expectEqual(diagnostics.Path.interactive, diagnosticsPathForTag(tag));
    }
}

test "media events use the media budget" {
    try std.testing.expectEqual(diagnostics.Path.media, diagnosticsPathForTag(.pane_media));
}

test "observation events use the observation budget" {
    const tags = [_]std.meta.Tag(Event){
        .pane_observed,
        .history_response,
        .proxy_event,
        .agent_tick,
        .agent_description,
        .metrics_tick,
        .telemetry_tick,
        .telemetry_written,
    };

    for (tags) |tag| {
        try std.testing.expectEqual(diagnostics.Path.observation, diagnosticsPathForTag(tag));
    }
}

test "lifecycle events stay outside latency-budgeted paths" {
    const tags = [_]std.meta.Tag(Event){
        .accepted,
        .handshaken,
        .pane_exit,
        .stopped,
    };

    for (tags) |tag| {
        try std.testing.expectEqual(diagnostics.Path.other, diagnosticsPathForTag(tag));
    }
}
