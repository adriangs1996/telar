const std = @import("std");
const ViolationType = @import("Violation.zig");
const Analyzer = @import("Analyzer.zig");
const syntax = @import("syntax.zig");
const diagnostic = @import("diagnostic.zig");
const Violation = @import("Violation.zig");
const naming = @import("layout_naming.zig");
const receivers = @import("receivers.zig");

pub fn allowsExcessParameters(tree: *const std.zig.Ast, declaration_token: std.zig.Ast.TokenIndex) bool {
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
pub fn lintSource(allocator: std.mem.Allocator, source: [:0]const u8) ![]ViolationType {
    return lint(allocator, source, null);
}

/// Checks both source style and filename-dependent ownership rules.
/// Example: `const violations = try lintFile(gpa, source, "Pane.zig");`.
pub fn lintFile(allocator: std.mem.Allocator, source: [:0]const u8, path: []const u8) ![]ViolationType {
    return lint(allocator, source, path);
}

fn lint(allocator: std.mem.Allocator, source: [:0]const u8, path: ?[]const u8) ![]ViolationType {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);

    var violations: std.ArrayList(ViolationType) = .empty;
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
        const node: std.zig.Ast.Node.Index = @enumFromInt(node_number);

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

    const misnamed = try receivers.find(allocator, &tree);
    defer allocator.free(misnamed);

    for (misnamed) |receiver| {
        const location = tree.tokenLocation(0, receiver.name_token);
        try violations.append(allocator, .{
            .rule = .receiver_name,
            .line = location.line + 1,
            .column = location.column + 1,
        });
    }

    if (path) |filename| {
        const layout: LayoutAnalyzer = .{
            .allocator = allocator,
            .tree = &tree,
            .path = filename,
            .violations = &violations,
        };
        try layout.check();
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

test "rejects functions with more than five parameters" {
    try expectRules(&.{.maximum_parameter_count},
        \\fn combine(first: u8, second: u8, third: u8, fourth: u8, fifth: u8, sixth: u8) u8 {
        \\    return first + second + third + fourth + fifth + sixth;
        \\}
    );
}

test "counts anytype parameters" {
    try expectRules(&.{.maximum_parameter_count},
        \\fn combine(first: anytype, second: anytype, third: anytype, fourth: anytype, fifth: anytype, sixth: anytype) void {
        \\    _ = .{ first, second, third, fourth, fifth, sixth };
        \\}
    );
}

test "accepts extern functions with more than five parameters" {
    try expectRules(&.{},
        \\extern "c" fn open(first: u8, second: u8, third: u8, fourth: u8, fifth: u8, sixth: u8) void;
    );
}

test "accepts an explicit maximum parameter count exception" {
    try expectRules(&.{},
        \\// codestyle: allow(maximum-parameter-count)
        \\fn callback(first: u8, second: u8, third: u8, fourth: u8, fifth: u8, sixth: u8) void {
        \\    _ = .{ first, second, third, fourth, fifth, sixth };
        \\}
    );
}

test "requires the maximum parameter count exception beside the declaration" {
    try expectRules(&.{.maximum_parameter_count},
        \\// codestyle: allow(maximum-parameter-count)
        \\
        \\fn callback(first: u8, second: u8, third: u8, fourth: u8, fifth: u8, sixth: u8) void {
        \\    _ = .{ first, second, third, fourth, fifth, sixth };
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

const LayoutAnalyzer = struct {
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    path: []const u8,
    violations: *std.ArrayList(Violation),

    /// Checks file ownership and the public constructor shape using parsed declarations.
    /// Example: `try analyzer.check();`.
    pub fn check(self: LayoutAnalyzer) !void {
        const stem = std.fs.path.stem(self.path);
        const generic_file = std.mem.startsWith(u8, stem, "Generic");
        var implicit_struct = false;
        var layout_count: usize = 0;
        var public_functions: usize = 0;
        var constructors: usize = 0;
        var named_value_types: usize = 0;
        var matching_value_type = false;

        for (self.tree.rootDecls()) |node| {
            if (self.tree.fullContainerField(node) != null) {
                implicit_struct = true;
            }

            if (self.tree.fullVarDecl(node)) |variable| {
                if (variable.ast.init_node.unwrap()) |value| {
                    if (std.mem.eql(u8, self.tree.getNodeSource(value), "@This()")) {
                        implicit_struct = true;
                    }

                    var container_buffer: [2]std.zig.Ast.Node.Index = undefined;
                    if (self.tree.fullContainerDecl(&container_buffer, value)) |container| {
                        const kind = self.tree.tokenTag(container.ast.main_token);
                        if (kind == .keyword_enum or kind == .keyword_union) {
                            named_value_types += 1;
                            matching_value_type = matching_value_type or std.mem.eql(
                                u8,
                                stem,
                                self.tree.tokenSlice(variable.ast.mut_token + 1),
                            );
                        }
                    }

                    // Private helper types stay in their owner's file.
                    if (variable.visib_token != null) {
                        layout_count += try self.checkLayout(value, variable.ast.mut_token);
                    }
                }
            }

            var buffer: [1]std.zig.Ast.Node.Index = undefined;
            if (self.tree.fullFnProto(&buffer, node)) |function| {
                if (function.visib_token != null) {
                    public_functions += 1;
                }

                const return_type = function.ast.return_type.unwrap() orelse continue;
                if (!std.mem.eql(u8, self.tree.getNodeSource(return_type), "type")) {
                    continue;
                }

                const name_token = function.name_token orelse continue;
                if (function.visib_token != null) {
                    constructors += 1;
                    if (!generic_file or !std.mem.eql(u8, self.tree.tokenSlice(name_token), "Type")) {
                        try self.append(name_token, .generic_constructor);
                    }
                }
            }
        }

        if (generic_file) {
            if (!naming.pascalCase(stem) or stem.len == "Generic".len or !std.ascii.isUpper(stem["Generic".len]) or constructors != 1 or public_functions != 1 or implicit_struct) {
                try self.append(0, .generic_file);
            }
        } else if (implicit_struct or layout_count != 0 or (named_value_types == 1 and matching_value_type and public_functions == 0)) {
            if (!naming.pascalCase(stem)) {
                try self.append(0, .type_file_name);
            }
        } else if (!naming.snakeCase(stem)) {
            try self.append(0, .namespace_file_name);
        }

        if (layout_count != 0 and (layout_count != 1 or implicit_struct or public_functions != 0)) {
            try self.append(0, .dedicated_layout_file);
        }

        try self.checkConstructorImports();
    }

    fn checkLayout(self: LayoutAnalyzer, node: std.zig.Ast.Node.Index, token: std.zig.Ast.TokenIndex) std.mem.Allocator.Error!usize {
        var buffer: [2]std.zig.Ast.Node.Index = undefined;
        if (self.tree.fullContainerDecl(&buffer, node)) |container| {
            if (self.tree.tokenTag(container.ast.main_token) == .keyword_struct) {
                if (container.layout_token != null) {
                    return 1;
                }

                try self.append(token, .ordinary_struct_declaration);
            }

            return 0;
        }

        if (self.tree.nodeTag(node) == .grouped_expression) {
            return self.checkLayout(self.tree.nodeData(node).node_and_token[0], token);
        }

        if (self.tree.fullIf(node)) |conditional| {
            var count = try self.checkLayout(conditional.ast.then_expr, token);
            if (conditional.ast.else_expr.unwrap()) |alternative| {
                count += try self.checkLayout(alternative, token);
            }

            return count;
        }

        if (self.tree.fullSwitch(node)) |selection| {
            var count: usize = 0;
            for (selection.ast.cases) |case_node| {
                const case = self.tree.fullSwitchCase(case_node) orelse continue;
                count += try self.checkLayout(case.ast.target_expr, token);
            }

            return count;
        }

        return 0;
    }

    fn checkConstructorImports(self: LayoutAnalyzer) !void {
        var number: usize = 0;
        while (number < self.tree.nodes.len) : (number += 1) {
            const node: std.zig.Ast.Node.Index = @enumFromInt(number);
            const variable = self.tree.fullVarDecl(node) orelse continue;
            const value = variable.ast.init_node.unwrap() orelse continue;
            const first = self.tree.firstToken(value);
            const last = self.tree.lastToken(value);
            if (self.tree.tokenTag(first) != .builtin or !std.mem.eql(u8, self.tree.tokenSlice(first), "@import")) {
                continue;
            }

            if (first + 3 > last or self.tree.tokenTag(first + 2) != .string_literal) {
                continue;
            }

            const literal = self.tree.tokenSlice(first + 2);
            const path = literal[1 .. literal.len - 1];
            const direct_file = std.mem.endsWith(u8, path, ".zig") and std.mem.startsWith(u8, std.fs.path.stem(path), "Generic");
            const module_constructor = !std.mem.endsWith(u8, path, ".zig") and first + 5 == last and self.tree.tokenTag(first + 4) == .period and std.mem.startsWith(u8, self.tree.tokenSlice(last), "Generic");
            if (!direct_file and !module_constructor) {
                continue;
            }

            const name = variable.ast.mut_token + 1;
            const selected_constructor = first + 5 == last and self.tree.tokenTag(first + 4) == .period and std.mem.eql(u8, self.tree.tokenSlice(last), "Type");
            if (!std.mem.startsWith(u8, self.tree.tokenSlice(name), "Generic") or (direct_file and !selected_constructor)) {
                try self.append(name, .generic_import);
            }
        }
    }

    fn append(self: LayoutAnalyzer, token: std.zig.Ast.TokenIndex, rule: diagnostic.Rule) !void {
        const location = self.tree.tokenLocation(0, token);
        try self.violations.append(self.allocator, .{
            .rule = rule,
            .line = location.line + 1,
            .column = location.column + 1,
        });
    }
};
