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
const limit_words = [_][]const u8{ "TooMany", "TooLarge", "TooLong", "TooDeep", "TooSmall", "Depth", "Full", "Exceeded", "Exhausted", "Limit", "Capacity", "Overflow", "Busy", "Quota" };
/// Files whose errors belong to tests, fuzz targets included: their own
/// errors never reach a net, so they need no set, and what they raise does
/// not keep a `LimitError` member alive.
const test_path_parts = [_][]const u8{ "/tests/", "client_tests/", "_test.zig", "/test.zig" };

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

/// Returns every error of one file named like a limit and in no set, both
/// `error.X` and the members of an `error{...}` it declares, and notes
/// which `LimitError` members the file raises. Test files and `test`
/// blocks raise their own fixtures' errors, which no net sees, so they are
/// neither checked nor count as raising.
///
/// ```zig
/// const violations = try limit_errors.lint(gpa, path, source, &names);
/// ```
pub fn lint(allocator: std.mem.Allocator, path: []const u8, source: [:0]const u8, names: *LimitErrorNames) ![]Violation {
    var violations: std.ArrayList(Violation) = .empty;
    errdefer violations.deinit(allocator);

    var tokens = try tokenize(allocator, source);
    defer tokens.deinit(allocator);

    const tags = tokens.items(.tag);
    const starts = tokens.items(.start);
    const test_file = isTestPath(path);
    const sets_file = std.mem.endsWith(u8, path, sets_path_suffix);
    var test_depth: usize = 0;
    var depth: usize = 0;
    var index: usize = 0;
    while (index < tokens.len) : (index += 1) {
        switch (tags[index]) {
            .l_brace => depth += 1,
            .r_brace => {
                depth -|= 1;
                if (test_depth != 0 and depth < test_depth) {
                    test_depth = 0;
                }
            },
            .keyword_test => if (test_depth == 0) {
                test_depth = depth + 1;
            },
            else => {},
        }

        if (tags[index] != .keyword_error or index + 1 >= tokens.len) {
            continue;
        }

        const in_test = test_file or test_depth != 0;
        if (tags[index + 1] == .period and index + 2 < tokens.len and tags[index + 2] == .identifier) {
            try check(allocator, .{ .source = source, .start = starts[index + 2], .raises = !in_test }, names, &violations);
            continue;
        }

        // The sets themselves declare every name; checking them is `collect`'s.
        if (tags[index + 1] != .l_brace or sets_file) {
            continue;
        }

        var member = index + 2;
        while (member < tokens.len and tags[member] != .r_brace) : (member += 1) {
            if (tags[member] == .identifier) {
                try check(allocator, .{ .source = source, .start = starts[member], .raises = !in_test }, names, &violations);
            }
        }
    }

    return violations.toOwnedSlice(allocator);
}

/// One error name where a file raises or declares it.
const Occurrence = struct {
    source: [:0]const u8,
    start: usize,
    /// Whether it keeps a `LimitError` member alive: not in a test.
    raises: bool,
};

fn check(allocator: std.mem.Allocator, occurrence: Occurrence, names: *LimitErrorNames, violations: *std.ArrayList(Violation)) !void {
    const name = text(occurrence.source, occurrence.start);
    if (names.members.getPtr(name)) |member| {
        member.raised = member.raised or occurrence.raises;
        return;
    }

    if (occurrence.raises and looksLikeLimit(name)) {
        try violations.append(allocator, at(occurrence.source, occurrence.start, .limit_error_set));
    }
}

fn isTestPath(path: []const u8) bool {
    for (test_path_parts) |part| {
        if (std.mem.indexOf(u8, path, part) != null) {
            return true;
        }
    }

    return false;
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
    const violations = try lint(std.testing.allocator, "src/a.zig", source, &names);
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

    const test_only = try lint(std.testing.allocator, "src/tests/a.zig", "const a = error.TooManyTabs;", &names);
    defer std.testing.allocator.free(test_only);
    const in_test_block = try lint(std.testing.allocator, "src/b.zig", "test \"t\" { _ = error.TooManyTabs; }", &names);
    defer std.testing.allocator.free(in_test_block);
    const still_unraised = try unraised(std.testing.allocator, sets, &names);
    defer std.testing.allocator.free(still_unraised);
    try std.testing.expectEqual(@as(usize, 2), still_unraised.len);

    const violations = try lint(std.testing.allocator, "src/c.zig", "const Set = error{TooManyTabs}; const b = Set.TooManyTabs;", &names);
    defer std.testing.allocator.free(violations);

    const unused = try unraised(std.testing.allocator, sets, &names);
    defer std.testing.allocator.free(unused);
    try std.testing.expectEqual(@as(usize, 1), unused.len);
    try std.testing.expectEqual(@as(usize, 3), unused[0].line);
}

test "an error set's members named like limits are checked too" {
    const sets =
        \\pub const LimitError = error{
        \\    TooManyTabs,
        \\};
    ;
    var names: LimitErrorNames = .{};
    defer names.deinit(std.testing.allocator);
    const missing = try collect(std.testing.allocator, sets, &names);
    defer std.testing.allocator.free(missing);

    const violations = try lint(std.testing.allocator, "src/a.zig", "const Set = error{ TooManyTabs, TooDeepNesting, Invalid };", &names);
    defer std.testing.allocator.free(violations);
    try std.testing.expectEqual(@as(usize, 1), violations.len);
    try std.testing.expectEqual(@as(usize, 33), violations[0].column);
}

test "test code keeps its own fixtures' errors out of the sets" {
    var names: LimitErrorNames = .{};
    defer names.deinit(std.testing.allocator);

    const fuzz = try lint(std.testing.allocator, "src/core/schema/messages/server_fuzz_test.zig", "const a = error.OwnedViewFull;", &names);
    defer std.testing.allocator.free(fuzz);
    try std.testing.expectEqual(@as(usize, 0), fuzz.len);

    const block = try lint(std.testing.allocator, "src/a.zig", "test \"t\" { _ = error.FixtureQueueFull; }", &names);
    defer std.testing.allocator.free(block);
    try std.testing.expectEqual(@as(usize, 0), block.len);

    const code = try lint(std.testing.allocator, "src/a.zig", "const a = error.QueueFull;", &names);
    defer std.testing.allocator.free(code);
    try std.testing.expectEqual(@as(usize, 1), code.len);
}
