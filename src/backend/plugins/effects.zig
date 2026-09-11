//! Typed, bounded effects returned by a runtime tap worker.

const std = @import("std");
const core = @import("telar-core");

pub const max_effects = 16;
pub const max_effect_bytes = 64 * 1024;

pub const Confidence = enum(u8) { low, medium };

pub const RecordCommand = @import("RecordCommand.zig");

pub const AgentEvidence = @import("AgentEvidence.zig");

pub const Notification = @import("Notification.zig");

pub const Effect = union(enum) {
    record_command: RecordCommand,
    agent_evidence: AgentEvidence,
    notification: Notification,
};

pub const Batch = @import("Batch.zig");

pub const Result = @import("Result.zig");
