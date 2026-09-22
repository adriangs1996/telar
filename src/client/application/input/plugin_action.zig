//! Application policy for one bounded client plugin execution.
const model_data = @import("model");

const PluginExecutionType = @import("../../model/PluginExecution.zig");
const PluginResult = @import("PluginResult.zig");

pub const StartOutcome = union(enum) {
    started: PluginExecutionType,
    busy,
    unavailable,
    rejected: anyerror,
};

pub const CompletionCommand = union(enum) {
    succeeded: PluginResult,
    failed: struct {
        execution_id: model_data.PluginExecutionId,
        reason: anyerror,
    },

    pub fn executionId(command: CompletionCommand) model_data.PluginExecutionId {
        return switch (command) {
            .succeeded => |result| result.execution_id,
            .failed => |failure| failure.execution_id,
        };
    }
};

pub const BatchDisposition = enum {
    continue_client,
    exit_client,
};

pub const CompletionOutcome = union(enum) {
    applied,
    exit,
    stale,
    ignored,
    worker_failed: anyerror,
    authorization_failed: anyerror,
};

pub const CompletionDirective = enum {
    continue_client,
    exit_client,
};

pub const CompletionEvent = enum {
    authorize,
    apply,
};

fn successfulCommand(execution_id: model_data.PluginExecutionId, batch: *const model_data.EffectBatch) CompletionCommand {
    return .{ .succeeded = .{
        .execution_id = execution_id,
        .package_index = 0,
        .plugin_id = 9,
        .digest = @splat(7),
        .batch = batch,
    } };
}
