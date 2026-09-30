//! The limit error rule. The runtime and the window stay alive at a limit
//! only for errors in `LimitError`, so an error named like a limit that is
//! in no set would take them down again unnoticed. Every `error.X` whose
//! name looks like a limit must be in `LimitError`, `SystemError` or
//! `NotLimitError` of `src/core/limit_reached.zig`, and every member of
//! `NotLimitError` says why in a doc comment.
const std = @import("std");
const Violation = @import("Violation.zig");
const LimitErrorNames = @import("LimitErrorNames.zig");

/// The file that declares the sets.
pub const sets_path_suffix = "src/core/limit_reached.zig";

const set_names = [_][]const u8{ "LimitError", "SystemError", "NotLimitError" };
const exemption_set = "NotLimitError";
const limit_set = "LimitError";
const limit_words = [_][]const u8{ "TooMany", "TooLarge", "TooLong", "Full", "Exceeded", "Exhausted", "Limit", "Capacity", "Overflow" };

/// Reads the sets from their file's source, which must outlive `Names`,
/// and returns the members of `NotLimitError` that give no reason.
///
/// ```zig
/// var names: LimitErrorNames = .{};
/// const missing = try limit_errors.collect(gpa, source, &names);
/// ```
pub fn collect(allocator: std.mem.Allocator, source: [:0]const u8, names: *LimitErrorNames) ![]Violation {
    var violations: std.ArrayList(Violation) = .empty;
    errdefer violations.deinit(allocator);

    var tokens = try tokenize(allocator, source);
    defer tokens.deinit(allocator);

    const tags = tokens.items(.tag);
    const starts = tokens.items(.start);
    for (0..tokens.len) |index| {
        if (tags[index] != .identifier or index + 3 >= tokens.len) {
            continue;
        }

        const set = text(source, starts[index]);
        if (!isSetName(set) or tags[index + 1] != .equal or tags[index + 2] != .keyword_error or tags[index + 3] != .l_brace) {
            continue;
        }

        var member = index + 4;
        while (member < tokens.len and tags[member] != .r_brace) : (member += 1) {
            if (tags[member] != .identifier) {
                continue;
            }

            try names.members.put(allocator, text(source, starts[member]), .{
                .start = starts[member],
                .limit = std.mem.eql(u8, set, limit_set),
            });
            if (std.mem.eql(u8, set, exemption_set) and tags[member - 1] != .doc_comment) {
                try violations.append(allocator, at(source, starts[member], .limit_error_reason));
            }
        }
    }

    return violations.toOwnedSlice(allocator);
}

/// Returns every `error.X` of one file named like a limit and in no set,
/// and notes which set members the file raises.
///
/// ```zig
/// const violations = try limit_errors.lint(gpa, source, &names);
/// ```
pub fn lint(allocator: std.mem.Allocator, source: [:0]const u8, names: *LimitErrorNames) ![]Violation {
    var violations: std.ArrayList(Violation) = .empty;
    errdefer violations.deinit(allocator);

    var tokens = try tokenize(allocator, source);
    defer tokens.deinit(allocator);

    const tags = tokens.items(.tag);
    const starts = tokens.items(.start);
    for (0..tokens.len) |index| {
        if (tags[index] != .keyword_error or index + 2 >= tokens.len or tags[index + 1] != .period or tags[index + 2] != .identifier) {
            continue;
        }

        const name = text(source, starts[index + 2]);
        if (names.members.getPtr(name)) |member| {
            member.raised = true;
        }

        if (looksLikeLimit(name) and !names.contains(name)) {
            try violations.append(allocator, at(source, starts[index + 2], .limit_error_set));
        }
    }

    return violations.toOwnedSlice(allocator);
}

/// Returns every `LimitError` member no checked file raises, at its
/// declaration: a set that names errors nothing raises hides the real ones.
///
/// ```zig
/// const violations = try limit_errors.unraised(gpa, sets_source, &names);
/// ```
pub fn unraised(allocator: std.mem.Allocator, source: [:0]const u8, names: *const LimitErrorNames) ![]Violation {
    var violations: std.ArrayList(Violation) = .empty;
    errdefer violations.deinit(allocator);

    var members = names.members.iterator();
    while (members.next()) |entry| {
        if (entry.value_ptr.limit and !entry.value_ptr.raised) {
            try violations.append(allocator, at(source, entry.value_ptr.start, .limit_error_unraised));
        }
    }

    std.sort.insertion(Violation, violations.items, {}, lineBefore);
    return violations.toOwnedSlice(allocator);
}

fn lineBefore(_: void, left: Violation, right: Violation) bool {
    return left.line < right.line;
}

fn looksLikeLimit(name: []const u8) bool {
    for (limit_words) |word| {
        if (std.mem.indexOf(u8, name, word) != null) {
            return true;
        }
    }

    return false;
}

fn isSetName(name: []const u8) bool {
    for (set_names) |set| {
        if (std.mem.eql(u8, name, set)) {
            return true;
        }
    }

    return false;
}

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) !std.MultiArrayList(TokenStart) {
    var tokens: std.MultiArrayList(TokenStart) = .empty;
    errdefer tokens.deinit(allocator);

    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) {
            break;
        }

        try tokens.append(allocator, .{
            .tag = token.tag,
            .start = token.loc.start,
        });
    }

    return tokens;
}

const TokenStart = struct {
    tag: std.zig.Token.Tag,
    start: usize,
};

fn text(source: [:0]const u8, start: usize) []const u8 {
    var end = start;
    while (end < source.len and (std.ascii.isAlphanumeric(source[end]) or source[end] == '_')) {
        end += 1;
    }

    return source[start..end];
}

fn at(source: [:0]const u8, start: usize, rule: @FieldType(Violation, "rule")) Violation {
    var line: usize = 1;
    var column: usize = 1;
    for (source[0..start]) |byte| {
        if (byte == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }

    return .{
        .rule = rule,
        .line = line,
        .column = column,
    };
}

test "an error named like a limit must be in a set, and an exemption says why" {
    const sets =
        \\pub const LimitError = error{
        \\    TooManyTabs,
        \\};
        \\pub const SystemError = error{
        \\    OutOfMemory,
        \\};
        \\pub const NotLimitError = error{
        \\    /// A test fixture.
        \\    FixtureClientLimit,
        \\    InvalidLimit,
        \\};
    ;
    var names: LimitErrorNames = .{};
    defer names.deinit(std.testing.allocator);
    const missing = try collect(std.testing.allocator, sets, &names);
    defer std.testing.allocator.free(missing);
    try std.testing.expectEqual(@as(usize, 1), missing.len);
    try std.testing.expectEqual(@as(usize, 10), missing[0].line);

    const source =
        \\fn a() !void {
        \\    return error.TooManyTabs;
        \\}
        \\fn b() !void {
        \\    return error.TooManyPanes;
        \\}
        \\fn c() !void {
        \\    return error.InvalidPath;
        \\}
    ;
    const violations = try lint(std.testing.allocator, source, &names);
    defer std.testing.allocator.free(violations);
    try std.testing.expectEqual(@as(usize, 1), violations.len);
    try std.testing.expectEqual(@as(usize, 5), violations[0].line);
    try std.testing.expectEqual(@as(usize, 18), violations[0].column);

    const unused = try unraised(std.testing.allocator, sets, &names);
    defer std.testing.allocator.free(unused);
    try std.testing.expectEqual(@as(usize, 0), unused.len);
}

test "a limit error nothing raises is reported where it is declared" {
    const sets =
        \\pub const LimitError = error{
        \\    TooManyTabs,
        \\    ImageTooLarge,
        \\};
    ;
    var names: LimitErrorNames = .{};
    defer names.deinit(std.testing.allocator);
    const missing = try collect(std.testing.allocator, sets, &names);
    defer std.testing.allocator.free(missing);

    const violations = try lint(std.testing.allocator, "const a = error.TooManyTabs;", &names);
    defer std.testing.allocator.free(violations);

    const unused = try unraised(std.testing.allocator, sets, &names);
    defer std.testing.allocator.free(unused);
    try std.testing.expectEqual(@as(usize, 1), unused.len);
    try std.testing.expectEqual(@as(usize, 3), unused[0].line);
}
