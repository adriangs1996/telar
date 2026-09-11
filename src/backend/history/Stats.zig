const Stats = @This();
const agent_detection = @import("agent_detection.zig");
input_bytes: u64 = 0,
captured: u64 = 0,
dropped: u64 = 0,
reset: bool = false,
failed: bool = false,
agent_observation: ?struct {
    signal: agent_detection.Signal,
    observed_at_ms: i64,
    observed_at_ns: ?i64 = null,
} = null,
