//! Events delivered to the runtime loop and their execution-budget class.
const core = @import("telar-core");
const EditorJob = @import("../editors/Job.zig");

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
const std = @import("std");

pub const Event = union(enum) {
    accepted: anyerror!core.SocketChannel,
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
    pane_search: WakeType,
    telemetry_tick: anyerror!void,
    telemetry_written: anyerror!void,
    proxy_event: anyerror!ObservationType,
    proxy_capture: anyerror!*Half,
    plugin_effects: anyerror!*ResultType,
    agent_tick: anyerror!void,
    agent_description: AgentResult,
    engine_response: anyerror!ResponseType,
    agent_thread_changed: @import("application/AgentThreadChanged.zig"),
    change_review_completed: *@import("../change_review/Job.zig"),
    agent_history_completed: *@import("application/AgentHistoryJob.zig"),
    metrics_tick: anyerror!void,
    metrics_sampled: SystemMetricsSample,
    checkpoint_written: anyerror!void,
    git_status: CompletionType,
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
        .change_review_completed, .agent_history_completed, .editor_opened => {},
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
        .proxy_event,
        .agent_tick,
        .agent_description,
        .engine_response,
        .agent_thread_changed,
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
        .proxy_event,
        .proxy_capture,
        .plugin_effects,
        .agent_tick,
        .agent_description,
        .engine_response,
        .agent_thread_changed,
        .agent_history_completed,
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
        .proxy_event,
        .proxy_capture,
        .plugin_effects,
        .agent_tick,
        .agent_description,
        .engine_response,
        .agent_thread_changed,
        .agent_history_completed,
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
