const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const syntax = @import("syntax.zig");

pub const Ast = std.zig.Ast;
pub const Allocator = std.mem.Allocator;

const Finding = @import("Finding.zig");

const Analyzer = @import("Analyzer.zig");

pub fn allowsExcessParameters(tree: *const Ast, declaration_token: Ast.TokenIndex) bool {
    const declaration_start = tree.tokenStart(declaration_token);
    const prefix = std.mem.trimEnd(u8, tree.source[0..declaration_start], " \t");
    if (prefix.len == 0 or prefix[prefix.len - 1] != '\n') {
        return false;
    }

    var previous_line_end = prefix.len - 1;
    if (previous_line_end != 0 and prefix[previous_line_end - 1] == '\r') {
        previous_line_end -= 1;
    }

    const previous_line_start = if (std.mem.lastIndexOfScalar(u8, prefix[0..previous_line_end], '\n')) |newline| newline + 1 else 0;
    const previous_line = std.mem.trim(u8, prefix[previous_line_start..previous_line_end], " \t");

    return std.mem.eql(u8, previous_line, "// codestyle: allow(maximum-parameter-count)");
}

/// Checks one Zig source file and returns every deterministic style violation.
///
/// ```zig
/// const violations = try lintSource(allocator, "fn run() void {}\n");
/// defer allocator.free(violations);
/// ```
pub fn lintSource(allocator: Allocator, source: [:0]const u8) ![]diagnostic.Violation {
    var tree = try Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);

    var violations: std.ArrayList(diagnostic.Violation) = .empty;
    errdefer violations.deinit(allocator);

    for (tree.errors) |parse_error| {
        const location = tree.tokenLocation(0, parse_error.token);

        try violations.append(allocator, .{
            .rule = .invalid_syntax,
            .line = location.line + 1,
            .column = location.column + tree.errorOffset(parse_error) + 1,
        });
    }

    if (tree.errors.len != 0) {
        return violations.toOwnedSlice(allocator);
    }

    const analyzer: Analyzer = .{
        .allocator = allocator,
        .tree = &tree,
        .violations = &violations,
    };

    var node_number: usize = 0;
    while (node_number < tree.nodes.len) : (node_number += 1) {
        const node: Ast.Node.Index = @enumFromInt(node_number);

        switch (tree.nodeTag(node)) {
            .fn_proto, .fn_proto_multi, .fn_proto_one, .fn_proto_simple => try analyzer.lintFunction(node),
            else => {},
        }
    }

    const statement_ifs = try syntax.statementIfNodes(allocator, &tree);
    defer allocator.free(statement_ifs);

    for (statement_ifs) |statement_if| {
        try analyzer.lintIf(statement_if);
    }

    return violations.toOwnedSlice(allocator);
}

fn expectRules(expected: []const diagnostic.Rule, source: [:0]const u8) !void {
    const violations = try lintSource(std.testing.allocator, source);
    defer std.testing.allocator.free(violations);

    try std.testing.expectEqual(expected.len, violations.len);
    for (expected, violations) |expected_rule, violation| {
        try std.testing.expectEqual(expected_rule, violation.rule);
    }
}

test "accepts conforming functions and conditionals" {
    try expectRules(&.{},
        \\fn choose(first: bool, second: bool, fallback: bool) bool {
        \\    if (first) {
        \\        return true;
        \\    } else if (second) {
        \\        return true;
        \\    } else {
        \\        return fallback;
        \\    }
        \\}
    );
}

test "rejects functions with more than three parameters" {
    try expectRules(&.{.maximum_parameter_count},
        \\fn combine(first: u8, second: u8, third: u8, fourth: u8) u8 {
        \\    return first + second + third + fourth;
        \\}
    );
}

test "counts anytype parameters" {
    try expectRules(&.{.maximum_parameter_count},
        \\fn combine(first: anytype, second: anytype, third: anytype, fourth: anytype) void {
        \\    _ = .{ first, second, third, fourth };
        \\}
    );
}

test "accepts extern functions with more than three parameters" {
    try expectRules(&.{},
        \\extern "c" fn open(first: u8, second: u8, third: u8, fourth: u8) void;
    );
}

test "accepts an explicit maximum parameter count exception" {
    try expectRules(&.{},
        \\// codestyle: allow(maximum-parameter-count)
        \\fn callback(first: u8, second: u8, third: u8, fourth: u8) void {
        \\    _ = .{ first, second, third, fourth };
        \\}
    );
}

test "requires the maximum parameter count exception beside the declaration" {
    try expectRules(&.{.maximum_parameter_count},
        \\// codestyle: allow(maximum-parameter-count)
        \\
        \\fn callback(first: u8, second: u8, third: u8, fourth: u8) void {
        \\    _ = .{ first, second, third, fourth };
        \\}
    );
}

test "rejects multiline function signatures" {
    try expectRules(&.{ .single_line_function_signature, .trailing_parameter_comma },
        \\fn combine(
        \\    first: u8,
        \\    second: u8,
        \\) u8 {
        \\    return first + second;
        \\}
    );
}

test "rejects a trailing parameter comma on one line" {
    try expectRules(&.{.trailing_parameter_comma},
        \\fn identity(value: u8,) u8 {
        \\    return value;
        \\}
    );
}

test "rejects unbraced if branches" {
    try expectRules(&.{.braced_if_branch},
        \\fn choose(value: bool) bool {
        \\    if (value) return true;
        \\    return false;
        \\}
    );
}

test "rejects unbraced else branches" {
    try expectRules(&.{.braced_if_branch},
        \\fn choose(value: bool) bool {
        \\    if (value) {
        \\        return true;
        \\    } else return false;
        \\}
    );
}

test "rejects an unbraced if statement after a block" {
    try expectRules(&.{.braced_if_branch},
        \\fn choose(first: bool, second: bool) bool {
        \\    if (first) {}
        \\    if (second) return true;
        \\    return false;
        \\}
    );
}

test "rejects unbraced branches in an else if continuation" {
    try expectRules(&.{ .braced_if_branch, .braced_if_branch },
        \\fn choose(first: bool, second: bool) bool {
        \\    if (first) {} else if (second) return true else return false;
        \\}
    );
}

test "accepts unbraced if expression branches" {
    try expectRules(&.{},
        \\fn choose(value: bool) u8 {
        \\    const result = if (value) 1 else 2;
        \\    return result;
        \\}
    );
}

test "reports invalid syntax without inspecting an incomplete tree" {
    const violations = try lintSource(std.testing.allocator, "fn broken( void {}\n");
    defer std.testing.allocator.free(violations);

    try std.testing.expect(violations.len > 0);
    try std.testing.expectEqual(diagnostic.Rule.invalid_syntax, violations[0].rule);
}
