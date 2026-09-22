const core = @import("telar-core");
/// An agent's own session identifier as reported through the control API,
/// typed and bounded so restore can rebuild a fixed argv from it.
const SessionReference = @This();

bytes: [core.max_agent_session_reference_bytes]u8 = undefined,
len: u8 = 0,
observed_at_ms: i64 = 0,

pub fn slice(reference: *const SessionReference) []const u8 {
    return reference.bytes[0..reference.len];
}

/// Copies a validated reference.
///
/// ```zig
/// const reference = try SessionReference.init("0192...", now_ms);
/// ```
pub fn init(value: []const u8, observed_at_ms: i64) !SessionReference {
    try core.validateSessionReference(value);
    var reference: SessionReference = .{ .observed_at_ms = observed_at_ms };
    @memcpy(reference.bytes[0..value.len], value);
    reference.len = @intCast(value.len);
    return reference;
}
