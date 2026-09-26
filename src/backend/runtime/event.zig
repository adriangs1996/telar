//! Events delivered to the runtime loop and their execution-budget class.
const owned = @import("../proxy/capture/owned.zig");
const localsocket = @import("localsocket");
const core = @import("telar-core");
const EditorJob = @import("../editors/Job.zig");

const ClientMessage = @import("events/ClientMessage.zig");
const ClientSent = @import("events/ClientSent.zig");
const model = @import("../history/model.zig");
const InputCompletion = @import("events/InputCompletion.zig");
const ResponseCompletion = @import("events/ResponseCompletion.zig");
const OutputCompletion = @import("events/OutputCompletion.zig");
const IngestCompletion = @import("events/IngestCompletion.zig");
const ObservationCompletion = @import("events/ObservationCompletion.zig");
const MediaCompletion = @import("events/MediaCompletion.zig");
const ExitCompletion = @import("events/ExitCompletion.zig");
const Wake = @import("events/Wake.zig");
const Half = owned.Half;
const Result = @import("../plugins/Result.zig");
const AgentResult = @import("../agent/Result.zig");
const EngineRuntime = @import("resources/EngineRuntime.zig");
const Response = EngineRuntime.Service.Response;
const hostmetrics = @import("hostmetrics");
const SystemMetricsSample = hostmetrics.SystemMetricsSample;
const Completion = @import("resources/Completion.zig");
const AgentCompletion = @import("../agent/Completion.zig");
const std = @import("std");
const Job = @import("../change_review/Job.zig");

pub const Event = union(enum) {
    accepted: anyerror!localsocket.SocketChannel,
    handshaken: anyerror!void,
    client_message: ClientMessage,
    client_sent: ClientSent,
    cell_publication_due: anyerror!void,
    history_response: anyerror!model.Response,
    pane_input_written: InputCompletion,
    pane_response_written: ResponseCompletion,
    pane_output: OutputCompletion,
    pane_ingested: IngestCompletion,
    pane_observed: ObservationCompletion,
    pane_media: MediaCompletion,
    pane_exit: ExitCompletion,
    pane_search: Wake,
    telemetry_tick: anyerror!void,
    telemetry_written: anyerror!void,
    proxy_capture: anyerror!*Half,
    plugin_effects: anyerror!*Result,
    agent_tick: anyerror!void,
    agent_description: AgentResult,
    engine_response: anyerror!Response,
    change_review_completed: *Job,
    metrics_tick: anyerror!void,
    metrics_sampled: SystemMetricsSample,
    checkpoint_written: anyerror!void,
    git_status: Completion,
    editor_opened: *EditorJob,
    session_name: AgentCompletion,
    stopped: anyerror!void,
};

/// Releases values transferred into an event that teardown will not dispatch.
/// Retained jobs and borrowed buffers are released by their owners after join.
/// Example: `discard(completed, io);` after `select.cancel()`.
pub fn discard(completed: Event, io: std.Io) void {
    switch (completed) {
        .accepted => |result| {
            var connection = result catch return;
            connection.deinit(io);
        },
        .history_response => |result| switch (result catch return) {
            .query_result => |value| value.deinit(),
            .output_result => |value| value.deinit(),
            .stats_result => |value| value.deinit(),
            .failed, .pruned => {},
        },
        .proxy_capture => |result| {
            const half = result catch return;
            half.deinit();
        },
        .plugin_effects => |result| {
            const effects = result catch return;
            effects.deinit();
        },
        // These pointers name slots still retained by RuntimeModel.
        .change_review_completed, .editor_opened => {},
        // Other events contain values or borrows whose owners outlive the join.
        .handshaken,
        .client_message,
        .client_sent,
        .cell_publication_due,
        .pane_input_written,
        .pane_response_written,
        .pane_output,
        .pane_ingested,
        .pane_observed,
        .pane_media,
        .pane_exit,
        .pane_search,
        .telemetry_tick,
        .telemetry_written,
        .agent_tick,
        .agent_description,
        .engine_response,
        .metrics_tick,
        .metrics_sampled,
        .checkpoint_written,
        .git_status,
        .session_name,
        .stopped,
        => {},
    }
}

/// Returns the latency budget used to diagnose one event while it is handled.
///
/// ```zig
/// const path = diagnosticsPath(event);
/// diagnostics.record(path, elapsed_ns);
/// ```
pub fn diagnosticsPath(event: Event) core.Path {
    return diagnosticsPathForTag(std.meta.activeTag(event));
}

fn diagnosticsPathForTag(tag: std.meta.Tag(Event)) core.Path {
    return switch (tag) {
        .pane_output,
        .pane_ingested,
        .pane_input_written,
        .pane_response_written,
        .client_message,
        .client_sent,
        .cell_publication_due,
        => .interactive,
        .pane_media => .media,
        .pane_search,
        .pane_observed,
        .history_response,
        .proxy_capture,
        .plugin_effects,
        .agent_tick,
        .agent_description,
        .engine_response,
        .change_review_completed,
        .metrics_tick,
        .metrics_sampled,
        .telemetry_tick,
        .telemetry_written,
        .checkpoint_written,
        .git_status,
        .editor_opened,
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
        try std.testing.expectEqual(core.Path.interactive, diagnosticsPathForTag(tag));
    }
}

test "media events use the media budget" {
    try std.testing.expectEqual(core.Path.media, diagnosticsPathForTag(.pane_media));
}

test "observation events use the observation budget" {
    const tags = [_]std.meta.Tag(Event){
        .pane_observed,
        .history_response,
        .proxy_capture,
        .plugin_effects,
        .agent_tick,
        .agent_description,
        .engine_response,
        .change_review_completed,
        .metrics_tick,
        .metrics_sampled,
        .telemetry_tick,
        .telemetry_written,
    };

    for (tags) |tag| {
        try std.testing.expectEqual(core.Path.observation, diagnosticsPathForTag(tag));
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
        try std.testing.expectEqual(core.Path.other, diagnosticsPathForTag(tag));
    }
}
