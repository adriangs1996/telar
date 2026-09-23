//! Application policy for one bounded local clipboard image capture.
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

const CapturedImage = struct {
    execution_id: model_data.ClipboardCaptureId,
    result_id: model_data.ClipboardCaptureId,
    target: model_data.AttachmentTarget,
};
