//! Application policy for one bounded local clipboard image capture.
const core = @import("telar-core");
const model_data = @import("model");

pub const StartOutcome = union(enum) {
    started: model_data.ClipboardCapture,
    busy,
    unsupported,
    no_target,
};

pub const CompletionCommand = union(enum) {
    succeeded: CapturedImage,
    failed: struct {
        execution_id: model_data.ClipboardCaptureId,
        reason: anyerror,
    },

    pub fn executionId(self: CompletionCommand) model_data.ClipboardCaptureId {
        return switch (self) {
            .succeeded => |result| result.execution_id,
            .failed => |failure| failure.execution_id,
        };
    }
};

pub const CompletionOutcome = union(enum) {
    applied,
    stale,
    ignored,
    no_image,
    too_large,
    worker_failed: anyerror,
    adoption_failed: anyerror,
};

pub fn classifyFailure(reason: anyerror) CompletionOutcome {
    return switch (reason) {
        error.NoImageOnClipboard => .no_image,
        error.ClipboardImageTooLarge => .too_large,
        else => .{ .worker_failed = reason },
    };
}

fn installFocusedTarget(model: *model_data.ClientModel) !model_data.AttachmentTarget {
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const target: model_data.AttachmentTarget = .{
        .pane_id = @enumFromInt(7),
        .pane_generation = 2,
    };
    try model_data.workspace_handoff.bootstrap(model, .{ .pane_id = target.pane_id, .location = location, .size = .{ .cols = 20, .rows = 5 } });
    _ = try model.reconcileAgentSnapshot(.{
        .revision = 1,
        .agents = &.{model_data.AgentInput{
            .key = .{
                .pane_id = target.pane_id,
                .pane_generation = target.pane_generation,
            },
            .location = location,
            .pane_index = 1,
            .provider = .codex,
            .attachments = .ordered,
            .status = .working,
        }},
    });
    return target;
}

fn successfulCommand(capture: model_data.ClipboardCapture) CompletionCommand {
    return .{ .succeeded = .{
        .execution_id = capture.id,
        .result_id = capture.id,
        .target = capture.target,
    } };
}

const CapturedImage = struct {
    execution_id: model_data.ClipboardCaptureId,
    result_id: model_data.ClipboardCaptureId,
    target: model_data.AttachmentTarget,
};
