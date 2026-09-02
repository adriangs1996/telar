//! Record-time history filtering shared by both processes: the client parses
//! the configuration, the runtime enforces it before anything reaches SQLite.
//! Filtering refuses to record — it never redacts after the fact.

const std = @import("std");

pub const max_patterns = 16;
pub const max_pattern_bytes = 96;

/// Bounded list of case-sensitive substring patterns from configuration.
pub const PatternList = struct {
    storage: [max_patterns][max_pattern_bytes]u8 = undefined,
    lens: [max_patterns]u8 = .{0} ** max_patterns,
    count: u8 = 0,

    /// Adds one pattern; empty, oversized or NUL-carrying patterns are
    /// rejected so a list always holds usable matchers.
    ///
    /// ```zig
    /// try list.add("vault kv get");
    /// ```
    pub fn add(list: *PatternList, pattern: []const u8) !void {
        if (pattern.len == 0 or pattern.len > max_pattern_bytes) {
            return error.InvalidFilterPattern;
        }
        if (std.mem.indexOfScalar(u8, pattern, 0) != null) {
            return error.InvalidFilterPattern;
        }
        if (list.count == max_patterns) {
            return error.TooManyFilterPatterns;
        }

        @memcpy(list.storage[list.count][0..pattern.len], pattern);
        list.lens[list.count] = @intCast(pattern.len);
        list.count += 1;
    }

    pub fn at(list: *const PatternList, index: usize) []const u8 {
        return list.storage[index][0..list.lens[index]];
    }

    pub fn matches(list: *const PatternList, text: []const u8) bool {
        for (0..list.count) |index| {
            if (std.mem.indexOf(u8, text, list.at(index)) != null) {
                return true;
            }
        }

        return false;
    }
};

/// Record-time policy. The defaults record everything except commands that
/// look like credentials.
pub const Filters = struct {
    secrets: bool = true,
    commands: PatternList = .{},
    cwds: PatternList = .{},

    /// Decides whether one completed command may be persisted. A leading
    /// space keeps a command out of history by convention.
    ///
    /// ```zig
    /// if (!filters.shouldRecord(command, cwd)) return;
    /// ```
    pub fn shouldRecord(filters: *const Filters, command: []const u8, cwd: []const u8) bool {
        if (command.len == 0) {
            return false;
        }
        if (command[0] == ' ') {
            return false;
        }
        if (filters.secrets and looksLikeSecret(command)) {
            return false;
        }
        if (filters.commands.matches(command)) {
            return false;
        }
        if (filters.cwds.matches(cwd)) {
            return false;
        }

        return true;
    }
};

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

test "builtin rules catch common credentials and spare normal commands" {
    try std.testing.expect(looksLikeSecret("export AWS_KEY=AKIAIOSFODNN7EXAMPLE"));
    try std.testing.expect(looksLikeSecret("git push https://ghp_abcdefghijklmnopqrstuvwx@github.com/x/y"));
    try std.testing.expect(looksLikeSecret("curl https://hooks.slack.com/services/T0/B0/x"));
    try std.testing.expect(looksLikeSecret("echo -----BEGIN OPENSSH PRIVATE KEY-----"));
    try std.testing.expect(looksLikeSecret("mysql -u root --PASSWORD=hunter2"));
    try std.testing.expect(looksLikeSecret("http POST /login token=abc123"));

    try std.testing.expect(!looksLikeSecret("git status"));
    try std.testing.expect(!looksLikeSecret("grep -rn password= --include=*.md docs"));
    try std.testing.expect(!looksLikeSecret("echo AKIA is an aws prefix"));
    try std.testing.expect(!looksLikeSecret("man git-token"));
}

test "filters refuse leading spaces and configured patterns" {
    var filters: Filters = .{};
    try filters.commands.add("vault kv");
    try filters.cwds.add("/private/notes");

    try std.testing.expect(filters.shouldRecord("git status", "/work"));
    try std.testing.expect(!filters.shouldRecord(" git status", "/work"));
    try std.testing.expect(!filters.shouldRecord("", "/work"));
    try std.testing.expect(!filters.shouldRecord("vault kv get secret/x", "/work"));
    try std.testing.expect(!filters.shouldRecord("ls", "/private/notes/journal"));

    filters.secrets = false;
    try std.testing.expect(filters.shouldRecord("export t=ghp_abcdefghijklmnopqrstuvwx", "/work"));

    try std.testing.expectError(error.InvalidFilterPattern, filters.commands.add(""));
    try std.testing.expectError(error.InvalidFilterPattern, filters.commands.add("a" ** 97));
}
