//! Application policy for one bounded client plugin execution.
const model_data = @import("model");

pub const StartOutcome = union(enum) {
    started: model_data.PluginExecution,
    busy,
    unavailable,
    rejected: anyerror,
};

pub const CompletionCommand = union(enum) {
    succeeded: model_data.PluginResult,
    failed: struct {
        execution_id: model_data.PluginExecutionId,
        reason: anyerror,
    },

    pub fn executionId(self: CompletionCommand) model_data.PluginExecutionId {
        return switch (self) {
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
