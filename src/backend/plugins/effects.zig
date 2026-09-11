//! Typed, bounded effects returned by a runtime tap worker.

const RecordCommand = @import("RecordCommand.zig");
const AgentEvidence = @import("AgentEvidence.zig");
const Notification = @import("Notification.zig");

pub const max_effects = 16;
pub const max_effect_bytes = 64 * 1024;

pub const Confidence = enum(u8) { low, medium };

pub const Effect = union(enum) {
    record_command: RecordCommand,
    agent_evidence: AgentEvidence,
    notification: Notification,
};
