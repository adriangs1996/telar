//! Typed, bounded effects returned by a runtime tap worker.

const std = @import("std");
const core = @import("telar-core");

pub const max_effects = 16;
pub const max_effect_bytes = 64 * 1024;

pub const Confidence = enum(u8) { low, medium };

pub const RecordCommand = struct {
    command: []const u8,
    cwd: []const u8,
    provider: []const u8,
    tool_call_id: []const u8,
    session: ?[]const u8,
    exit_code: i32,
    started_at_ms: i64,
    duration_ms: u64,
    redact: bool,
};

pub const AgentEvidence = struct {
    pane: core.schema.PaneId,
    state: core.schema.AgentReportState,
    confidence: Confidence,
};

pub const Notification = struct {
    level: core.schema.NotificationLevel,
    duration_ms: u32,
    title: []const u8,
    message: []const u8,
};

pub const Effect = union(enum) {
    record_command: RecordCommand,
    agent_evidence: AgentEvidence,
    notification: Notification,
};

pub const Batch = struct {
    items: [max_effects]Effect = undefined,
    len: u8 = 0,

    pub fn slice(batch: *const Batch) []const Effect {
        return batch.items[0..batch.len];
    }
};

pub const Result = struct {
    gpa: std.mem.Allocator,
    package_index: u8,
    plugin_id: u64,
    digest: core.plugin.Digest,
    generation: u64,
    event_id: u64,
    pane: core.schema.PaneId,
    pane_generation: u64,
    storage: []u8,
    batch: Batch,

    /// Erases and releases the worker frame and result allocation.
    ///
    /// ```zig
    /// result.deinit();
    /// ```
    pub fn deinit(result: *Result) void {
        const gpa = result.gpa;
        std.crypto.secureZero(u8, result.storage);
        gpa.free(result.storage);
        std.crypto.secureZero(u8, std.mem.asBytes(result));
        gpa.destroy(result);
    }
};
