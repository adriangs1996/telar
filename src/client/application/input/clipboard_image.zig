//! Application policy for one bounded local clipboard image capture.

const ClipboardCaptureType = @import("../../model/ClipboardCapture.zig");
const CapturedImage = @import("CapturedImage.zig");
const types = @import("../../model/types.zig");
const ModelType = @import("../../model/Model.zig");
const std = @import("std");
const TargetType = @import("../../attachments/AttachmentTarget.zig");
const TabLocationType = @import("telar-core").TabLocation;
const AgentInputType = @import("../../agents/AgentInput.zig");

pub const StartOutcome = union(enum) {
    started: ClipboardCaptureType,
    busy,
    unsupported,
    no_target,
};

pub const CompletionCommand = union(enum) {
    succeeded: CapturedImage,
    failed: struct {
        execution_id: types.ClipboardCaptureId,
        reason: anyerror,
    },

    pub fn executionId(command: CompletionCommand) types.ClipboardCaptureId {
        return switch (command) {
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

pub const CompletionEvent = enum {
    adopt,
    resize,
};

fn installFocusedTarget(model: *ModelType) !TargetType {
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const target: TargetType = .{
        .pane_id = @enumFromInt(7),
        .pane_generation = 2,
    };
    try model.workspace.bootstrap(.{ .pane_id = target.pane_id, .location = location, .size = .{ .cols = 20, .rows = 5 } });
    _ = try model.reconcileAgentSnapshot(.{
        .revision = 1,
        .agents = &.{AgentInputType{
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

fn successfulCommand(capture: ClipboardCaptureType) CompletionCommand {
    return .{ .succeeded = .{
        .execution_id = capture.id,
        .result_id = capture.id,
        .target = capture.target,
    } };
}
