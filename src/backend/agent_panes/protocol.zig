//! Codex app-server JSONL bounds, verified against the locally generated
//! Codex 0.154 schema. Unknown server requests receive an explicit RPC error.

const command_module = @import("command.zig");

pub const max_json_bytes = 2 * 1024 * 1024;
pub const max_write_bytes = 64 * 1024;
pub const queue_depth = 8;
pub const max_approvals = 8;
pub const Event = union(enum) {
    line: anyerror![]const u8,
    command: anyerror!command_module.Command,
    deadline: anyerror!void,
    resume_deadline: anyerror!void,
    command_deadline: anyerror!void,
};
pub const WriteEvent = union(enum) {
    written: anyerror!void,
    deadline: anyerror!void,
};
