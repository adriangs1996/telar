//! Record-time history filtering shared by both processes: the client parses
//! the configuration, the runtime enforces it before anything reaches SQLite.
//! Filtering refuses to record — it never redacts after the fact.

const std = @import("std");
const Limit = @import("Limit.zig");

/// Patterns one filter list holds. The configuration is refused past it,
/// never cut: a dropped pattern would record the commands it hides.
pub const max_patterns = 64;
pub const patterns_limit = Limit.declare("history_filter.max_patterns", "patterns", max_patterns);
/// Bytes of one pattern; cwd patterns are often whole paths.
pub const max_pattern_bytes = 256;
pub const pattern_bytes_limit = Limit.declare("history_filter.max_pattern_bytes", "bytes", max_pattern_bytes);

const SecretRule = union(enum) {
    /// The marker anywhere in the command is enough.
    substring: []const u8,
    /// The marker must be followed by at least `min_len` key-charset bytes.
    token: struct { marker: []const u8, min_len: u8 },
    /// The marker must be followed by a non-empty value with no space before
    /// its end, e.g. `password=hunter2`.
    assignment: []const u8,
};

const secret_rules = [_]SecretRule{
    .{ .token = .{ .marker = "AKIA", .min_len = 16 } },
    .{ .token = .{ .marker = "ghp_", .min_len = 20 } },
    .{ .token = .{ .marker = "gho_", .min_len = 20 } },
    .{ .token = .{ .marker = "github_pat_", .min_len = 20 } },
    .{ .token = .{ .marker = "npm_", .min_len = 30 } },
    .{ .token = .{ .marker = "sk_live_", .min_len = 12 } },
    .{ .token = .{ .marker = "rk_live_", .min_len = 12 } },
    .{ .token = .{ .marker = "xoxb-", .min_len = 10 } },
    .{ .token = .{ .marker = "xoxp-", .min_len = 10 } },
    .{ .substring = "hooks.slack.com/services/" },
    .{ .substring = "-----BEGIN" },
    .{ .assignment = "password=" },
    .{ .assignment = "passwd=" },
    .{ .assignment = "token=" },
    .{ .assignment = "secret=" },
    .{ .assignment = "api_key=" },
};

/// True when the command carries something shaped like a credential. Rules
/// are ASCII case-insensitive for assignment markers and case-sensitive for
/// token prefixes, matching how the real credentials are cased.
pub fn looksLikeSecret(command: []const u8) bool {
    for (secret_rules) |rule| {
        switch (rule) {
            .substring => |marker| {
                if (std.mem.indexOf(u8, command, marker) != null) {
                    return true;
                }
            },
            .token => |token| {
                if (tokenMatch(command, token.marker, token.min_len)) {
                    return true;
                }
            },
            .assignment => |marker| {
                if (assignmentMatch(command, marker)) {
                    return true;
                }
            },
        }
    }

    return false;
}

fn tokenMatch(command: []const u8, marker: []const u8, min_len: u8) bool {
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, command, offset, marker)) |index| {
        offset = index + 1;
        var run: usize = 0;
        for (command[index + marker.len ..]) |byte| {
            if (!tokenByte(byte)) {
                break;
            }

            run += 1;
        }
        if (run >= min_len) {
            return true;
        }
    }

    return false;
}

fn tokenByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

fn assignmentMatch(command: []const u8, marker: []const u8) bool {
    var offset: usize = 0;
    while (offset + marker.len <= command.len) : (offset += 1) {
        if (!std.ascii.startsWithIgnoreCase(command[offset..], marker)) {
            continue;
        }

        const value = command[offset + marker.len ..];
        if (value.len != 0 and value[0] != ' ' and value[0] != '"' and value[0] != '\'') {
            return true;
        }
    }

    return false;
}
