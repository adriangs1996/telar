const PatternList = @import("PatternList.zig");
const Input = @import("Input.zig");
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
