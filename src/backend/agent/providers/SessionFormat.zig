const std = @import("std");

/// The shape of the session reference an agent resumes by. A restored
/// reference must have it exactly, so a stored value can never add options
/// or shell syntax to the resume command.
pub const SessionFormat = enum {
    /// Claude Code, Codex, Pi and Cursor Agent: `8-4-4-4-12` hexadecimal.
    uuid,
    /// OpenCode: `ses_`, twelve hexadecimal digits of time and fourteen
    /// base62 characters.
    opencode,

    /// Reports whether `reference` has this shape.
    ///
    /// ```zig
    /// if (!SessionFormat.opencode.accepts("ses_f212d4cc3ffeR3t3CA08EwN5Ap")) return error.InvalidResumeSession;
    /// ```
    pub fn accepts(self: SessionFormat, reference: []const u8) bool {
        return switch (self) {
            .uuid => isUuid(reference),
            .opencode => isOpenCodeSession(reference),
        };
    }
};

fn isUuid(value: []const u8) bool {
    if (value.len != 36) {
        return false;
    }

    for (value, 0..) |byte, index| {
        const dash = index == 8 or index == 13 or index == 18 or index == 23;
        if (dash) {
            if (byte != '-') {
                return false;
            }
        } else if (!std.ascii.isHex(byte)) {
            return false;
        }
    }

    return true;
}

// `SessionID.descending` in OpenCode's `packages/schema/src/identifier.ts`:
// the prefix, 6 bytes of inverted time as hexadecimal and 14 random base62
// characters.
fn isOpenCodeSession(value: []const u8) bool {
    const prefix = "ses_";
    const time_digits = 12;
    const random_characters = 14;
    if (value.len != prefix.len + time_digits + random_characters or !std.mem.startsWith(u8, value, prefix)) {
        return false;
    }

    for (value[prefix.len..][0..time_digits]) |byte| {
        if (!std.ascii.isHex(byte)) {
            return false;
        }
    }

    for (value[prefix.len + time_digits ..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte)) {
            return false;
        }
    }

    return true;
}

test "session formats accept only their own references" {
    const uuid = "0192aaaa-bbbb-cccc-dddd-eeeeffff0000";
    const opencode = "ses_f212d4cc3ffeR3t3CA08EwN5Ap";
    try std.testing.expect(SessionFormat.uuid.accepts(uuid));
    try std.testing.expect(!SessionFormat.uuid.accepts(opencode));
    try std.testing.expect(SessionFormat.opencode.accepts(opencode));
    try std.testing.expect(!SessionFormat.opencode.accepts(uuid));

    try std.testing.expect(!SessionFormat.opencode.accepts("ses_f212d4cc3ffeR3t3CA08EwN5A"));
    try std.testing.expect(!SessionFormat.opencode.accepts("ses_f212d4cc3ffeR3t3CA08EwN5Ap0"));
    try std.testing.expect(!SessionFormat.opencode.accepts("ses_g212d4cc3ffeR3t3CA08EwN5Ap"));
    try std.testing.expect(!SessionFormat.opencode.accepts("ses_f212d4cc3ffeR3t3CA08Ew-5Ap"));
    try std.testing.expect(!SessionFormat.opencode.accepts("msg_f212d4cc3ffeR3t3CA08EwN5Ap"));
    try std.testing.expect(!SessionFormat.uuid.accepts("0192aaaa-bbbb-cccc-dddd-eeeeffff000g"));
}
