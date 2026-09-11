/// Record-time policy. The defaults record everything except commands that
/// look like credentials.
const Filters = @This();
const PatternList = @import("PatternList.zig");
const Input = @import("Input.zig");
const source_namespace = @import("history_filter.zig");
secrets: bool = true,
commands: PatternList = .{},
cwds: PatternList = .{},

/// Decides whether one completed command may be persisted. A leading
/// space keeps a command out of history by convention.
///
/// ```zig
/// if (!filters.shouldRecord(.{ .command = command, .cwd = cwd })) return;
/// ```
pub fn shouldRecord(filters: *const Filters, input: Input) bool {
    if (input.command.len == 0) {
        return false;
    }
    if (input.command[0] == ' ') {
        return false;
    }
    if (filters.secrets and source_namespace.looksLikeSecret(input.command)) {
        return false;
    }
    if (filters.commands.matches(input.command)) {
        return false;
    }
    if (filters.cwds.matches(input.cwd)) {
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
pub fn shouldRecordAgent(filters: *const Filters, input: Input, redact: bool) bool {
    if (input.command.len == 0) {
        return false;
    }
    if (redact and filters.secrets and source_namespace.looksLikeSecret(input.command)) {
        return false;
    }
    if (filters.commands.matches(input.command)) {
        return false;
    }
    if (filters.cwds.matches(input.cwd)) {
        return false;
    }

    return true;
}
