const std = @import("std");
const ViolationType = @import("Violation.zig");
const analyzer_support = @import("analysis.zig");
const syntax = @import("syntax.zig");
const Finding = @import("Finding.zig");
const Analyzer = @This();

allocator: std.mem.Allocator,
tree: *const std.zig.Ast,
violations: *std.ArrayList(ViolationType),

pub fn lintFunction(self: Analyzer, node: std.zig.Ast.Node.Index) !void {
    var buffer: [1]std.zig.Ast.Node.Index = undefined;
    const function = self.tree.fullFnProto(&buffer, node).?;
    const function_token = function.name_token orelse function.ast.fn_token;

    if (function.extern_export_inline_token) |token| {
        if (self.tree.tokenTag(token) == .keyword_extern) {
            return;
        }
    }

    var parameters = function.iterate(self.tree);
    var parameter_count: usize = 0;
    while (parameters.next() != null) {
        parameter_count += 1;
    }

    if (parameter_count > 3 and !analyzer_support.allowsExcessParameters(self.tree, function.firstToken())) {
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

pub fn lintIf(self: Analyzer, node: std.zig.Ast.Node.Index) !void {
    const conditional = self.tree.fullIf(node).?;

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

fn append(self: Analyzer, token: std.zig.Ast.TokenIndex, finding: Finding) !void {
    const location = self.tree.tokenLocation(0, token);

    try self.violations.append(self.allocator, .{
        .rule = finding.rule,
        .line = location.line + 1,
        .column = location.column + 1,
        .detail = finding.detail,
    });
}
