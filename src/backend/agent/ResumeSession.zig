const core = @import("telar-core");
const std = @import("std");
const SessionReference = @import("SessionReference.zig");
const providers = @import("providers/providers.zig");
const ResumeSession = @This();

provider: core.AgentProvider,
reference: SessionReference,

/// Accepts only a built-in provider and a UUID, so stored values cannot add
/// options or shell syntax to a reconstructed resume command.
/// Example: `const session = try ResumeSession.init(.claude, reference);`.
pub fn init(provider: core.AgentProvider, reference: SessionReference) !ResumeSession {
    if (providers.of(provider).resume_prefix == null or !isUuid(reference.slice())) {
        return error.InvalidResumeSession;
    }

    return .{ .provider = provider, .reference = reference };
}

/// Compares the provider and session identifier, ignoring observation time.
/// Example: `if (previous.eql(current)) return;`.
pub fn eql(self: ResumeSession, other: ResumeSession) bool {
    return self.provider == other.provider and std.mem.eql(u8, self.reference.slice(), other.reference.slice());
}

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
