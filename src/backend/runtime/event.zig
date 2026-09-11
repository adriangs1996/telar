//! Events delivered to the runtime loop and their execution-budget class.

const SocketChannelType = @import("telar-core").SocketChannel;
const ClientMessage = @import("ClientMessage.zig");
const ClientSent = @import("ClientSent.zig");
const model = @import("../history/model.zig");
const InputCompletion = @import("entrypoints/events/pane/InputCompletion.zig");
const ResponseCompletion = @import("entrypoints/events/pane/ResponseCompletion.zig");
const OutputCompletion = @import("entrypoints/events/pane/OutputCompletion.zig");
const IngestCompletion = @import("entrypoints/events/pane/IngestCompletion.zig");
const ObservationCompletion = @import("entrypoints/events/pane/ObservationCompletion.zig");
const MediaCompletion = @import("entrypoints/events/pane/MediaCompletion.zig");
const ExitCompletion = @import("entrypoints/events/pane/ExitCompletion.zig");
const WakeType = @import("application/Wake.zig");
const ObservationType = @import("../proxy/Observation.zig");
const Half = @import("../proxy/capture/Half.zig");
const ResultType = @import("../plugins/Result.zig");
const AgentResult = @import("../agent/Result.zig");
const ResponseType = @import("../engine/Response.zig");
const SystemMetricsSample = @import("observability/SystemMetricsSample.zig");
const CompletionType = @import("resources/Completion.zig");
const AgentCompletion = @import("../agent/Completion.zig");
const PathType = @import("telar-core").Path;
const std = @import("std");

pub const Event = union(enum) {
    accepted: anyerror!SocketChannelType,
    handshaken: anyerror!void,
    client_message: ClientMessage,
    client_sent: ClientSent,
    history_response: anyerror!model.Response,
    pane_input_written: InputCompletion,
    pane_response_written: ResponseCompletion,
    pane_output: OutputCompletion,
    pane_ingested: IngestCompletion,
    pane_observed: ObservationCompletion,
    pane_media: MediaCompletion,
    pane_exit: ExitCompletion,
    pane_search: WakeType,
    telemetry_tick: anyerror!void,
    telemetry_written: anyerror!void,
    proxy_event: anyerror!ObservationType,
    proxy_capture: anyerror!*Half,
    plugin_effects: anyerror!*ResultType,
    agent_tick: anyerror!void,
    agent_description: AgentResult,
    engine_response: anyerror!ResponseType,
    metrics_tick: anyerror!void,
    metrics_sampled: SystemMetricsSample,
    checkpoint_written: anyerror!void,
    git_status: CompletionType,
    session_name: AgentCompletion,
    stopped: anyerror!void,
};

/// Returns the latency budget used to diagnose one event while it is handled.
///
/// ```zig
/// const path = diagnosticsPath(event);
/// diagnostics.record(path, elapsed_ns);
/// ```
pub fn diagnosticsPath(event: Event) PathType {
    return diagnosticsPathForTag(std.meta.activeTag(event));
}

fn diagnosticsPathForTag(tag: std.meta.Tag(Event)) PathType {
    return switch (tag) {
        .pane_output,
        .pane_ingested,
        .pane_input_written,
        .pane_response_written,
        .client_message,
        .client_sent,
        => .interactive,
        .pane_media => .media,
        .pane_search,
        .pane_observed,
        .history_response,
        .proxy_event,
        .proxy_capture,
        .plugin_effects,
        .agent_tick,
        .agent_description,
        .engine_response,
        .metrics_tick,
        .metrics_sampled,
        .telemetry_tick,
        .telemetry_written,
        .checkpoint_written,
        .git_status,
        .session_name,
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
        try std.testing.expectEqual(PathType.interactive, diagnosticsPathForTag(tag));
    }
}

test "media events use the media budget" {
    try std.testing.expectEqual(PathType.media, diagnosticsPathForTag(.pane_media));
}

test "observation events use the observation budget" {
    const tags = [_]std.meta.Tag(Event){
        .pane_observed,
        .history_response,
        .proxy_event,
        .proxy_capture,
        .plugin_effects,
        .agent_tick,
        .agent_description,
        .engine_response,
        .metrics_tick,
        .metrics_sampled,
        .telemetry_tick,
        .telemetry_written,
    };

    for (tags) |tag| {
        try std.testing.expectEqual(PathType.observation, diagnosticsPathForTag(tag));
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
        try std.testing.expectEqual(PathType.other, diagnosticsPathForTag(tag));
    }
}
