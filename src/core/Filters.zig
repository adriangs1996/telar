const std = @import("std");
const history_filter = @import("history_filter.zig");
/// Record-time policy. The defaults record everything except commands that
/// look like credentials.
const Filters = @This();

secrets: bool = true,
commands: PatternList = .{},
cwds: PatternList = .{},

/// Decides whether one completed command may be persisted. A leading
/// space keeps a command out of history by convention.
///
/// ```zig
/// if (!filters.shouldRecord(.{ .command = command, .cwd = cwd })) return;
/// ```
pub fn shouldRecord(self: *const Filters, input: Input) bool {
    if (input.command.len == 0) {
        return false;
    }
    if (input.command[0] == ' ') {
        return false;
    }
    if (self.secrets and history_filter.looksLikeSecret(input.command)) {
        return false;
    }
    if (self.commands.matches(input.command)) {
        return false;
    }
    if (self.cwds.matches(input.cwd)) {
        return false;
    }

    return true;
}

/// Applies configured filters to an agent command without treating a
/// leading space as shell history control. Secret refusal is optional.
///
/// ```zig
/// if (!filters.shouldRecordAgent(.{ .command = command, .cwd = cwd }, true)) return;
/// ```
pub fn shouldRecordAgent(self: *const Filters, input: Input, redact: bool) bool {
    if (input.command.len == 0) {
        return false;
    }
    if (redact and self.secrets and history_filter.looksLikeSecret(input.command)) {
        return false;
    }
    if (self.commands.matches(input.command)) {
        return false;
    }
    if (self.cwds.matches(input.cwd)) {
        return false;
    }

    return true;
}

const Input = struct {
    command: []const u8,
    cwd: []const u8,
};

const PatternList = struct {
    /// Bounded list of case-sensitive substring patterns from configuration.
    storage: [history_filter.max_patterns][history_filter.max_pattern_bytes]u8 = undefined,
    lens: [history_filter.max_patterns]u8 = .{0} ** history_filter.max_patterns,
    count: u8 = 0,

    /// Adds one pattern; empty, oversized or NUL-carrying patterns are
    /// rejected so a list always holds usable matchers.
    ///
    /// ```zig
    /// try list.add("vault kv get");
    /// ```
    pub fn add(self: *PatternList, pattern: []const u8) !void {
        if (pattern.len == 0 or pattern.len > history_filter.max_pattern_bytes) {
            return error.InvalidFilterPattern;
        }
        if (std.mem.indexOfScalar(u8, pattern, 0) != null) {
            return error.InvalidFilterPattern;
        }
        if (self.count == history_filter.max_patterns) {
            return error.TooManyFilterPatterns;
        }

        @memcpy(self.storage[self.count][0..pattern.len], pattern);
        self.lens[self.count] = @intCast(pattern.len);
        self.count += 1;
    }

    pub fn at(self: *const PatternList, index: usize) []const u8 {
        return self.storage[index][0..self.lens[index]];
    }

    pub fn matches(self: *const PatternList, text: []const u8) bool {
        for (0..self.count) |index| {
            if (std.mem.indexOf(u8, text, self.at(index)) != null) {
                return true;
            }
        }

        return false;
    }
};
