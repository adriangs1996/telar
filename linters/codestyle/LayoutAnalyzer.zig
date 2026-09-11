const std = @import("std");
const Violation = @import("Violation.zig");
const Rule = @import("diagnostic.zig").Rule;
const naming = @import("layout_naming.zig");
const LayoutAnalyzer = @This();

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

    for (self.tree.rootDecls()) |node| {
        if (self.tree.fullContainerField(node) != null) {
            implicit_struct = true;
        }

        if (self.tree.fullVarDecl(node)) |variable| {
            if (variable.ast.init_node.unwrap()) |value| {
                if (std.mem.eql(u8, self.tree.getNodeSource(value), "@This()")) {
                    implicit_struct = true;
                }

                layout_count += try self.checkLayout(value, variable.ast.mut_token);
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
    } else if (implicit_struct or layout_count != 0) {
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

fn append(self: LayoutAnalyzer, token: std.zig.Ast.TokenIndex, rule: Rule) !void {
    const location = self.tree.tokenLocation(0, token);
    try self.violations.append(self.allocator, .{
        .rule = rule,
        .line = location.line + 1,
        .column = location.column + 1,
    });
}
