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
        limit: ?core.LimitReach = null,
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
    /// The limit the image passed; the client reports it by name.
    too_large: core.LimitReach,
    worker_failed: anyerror,
    adoption_failed: anyerror,
};

/// What a failed capture means for the person: an image past a limit names
/// the limit the worker returned, or the error when it returned none.
///
/// ```zig
/// const outcome = clipboard_image.classifyFailure(err, completion.limit);
/// ```
pub fn classifyFailure(reason: anyerror, limit: ?core.LimitReach) CompletionOutcome {
    return switch (reason) {
        error.NoImageOnClipboard => .no_image,
        error.ClipboardImageTooLarge => .{ .too_large = limit orelse core.limit_reached.unnamed(reason, "") },
        else => .{ .worker_failed = reason },
    };
}

const CapturedImage = struct {
    execution_id: model_data.ClipboardCaptureId,
    result_id: model_data.ClipboardCaptureId,
    target: model_data.AttachmentTarget,
};
