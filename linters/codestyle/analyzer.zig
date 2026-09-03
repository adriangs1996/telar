const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const syntax = @import("syntax.zig");

const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;

const Finding = struct {
    rule: diagnostic.Rule,
    detail: usize = 0,
};

const Analyzer = struct {
    allocator: Allocator,
    tree: *const Ast,
    violations: *std.ArrayList(diagnostic.Violation),

    fn lintFunction(self: Analyzer, node: Ast.Node.Index) !void {
        var buffer: [1]Ast.Node.Index = undefined;
        const function = self.tree.fullFnProto(&buffer, node).?;
        const function_token = function.name_token orelse function.ast.fn_token;

        var parameters = function.iterate(self.tree);
        var parameter_count: usize = 0;
        while (parameters.next() != null) {
            parameter_count += 1;
        }

        if (parameter_count > 3) {
            try self.append(function_token, .{ .rule = .maximum_parameter_count, .detail = parameter_count });
        }

        if (syntax.hasMultilineSignature(self.tree, function)) {
            try self.append(function_token, .{ .rule = .single_line_function_signature });
        }

        const rparen = syntax.closingParen(self.tree, function.lparen);
        if (self.tree.tokenTag(rparen - 1) == .comma) {
            try self.append(rparen - 1, .{ .rule = .trailing_parameter_comma });
        }
    }

    fn lintIf(self: Analyzer, node: Ast.Node.Index) !void {
        const conditional = self.tree.fullIf(node).?;

        if (!self.isStatementIf(conditional.ast.if_token)) {
            return;
        }

        if (!syntax.isBlock(self.tree.nodeTag(conditional.ast.then_expr))) {
            try self.append(conditional.ast.if_token, .{ .rule = .braced_if_branch });
        }

        if (conditional.ast.else_expr.unwrap()) |else_expr| {
            const else_tag = self.tree.nodeTag(else_expr);
            if (!syntax.isBlock(else_tag) and else_tag != .if_simple and else_tag != .@"if") {
                try self.append(conditional.else_token, .{ .rule = .braced_if_branch });
            }
        }
    }

    fn isStatementIf(self: Analyzer, if_token: Ast.TokenIndex) bool {
        if (if_token == 0) {
            return false;
        }

        return switch (self.tree.tokenTag(if_token - 1)) {
            .l_brace, .semicolon => true,
            else => false,
        };
    }

    fn append(self: Analyzer, token: Ast.TokenIndex, finding: Finding) !void {
        const location = self.tree.tokenLocation(0, token);

        try self.violations.append(self.allocator, .{
            .rule = finding.rule,
            .line = location.line + 1,
            .column = location.column + 1,
            .detail = finding.detail,
        });
    }
};

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
            .if_simple, .@"if" => try analyzer.lintIf(node),
            else => {},
        }
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
