const std = @import("std");
const Edit = @import("Edit.zig");
const syntax = @import("syntax.zig");
const Fixer = @This();

allocator: std.mem.Allocator,
tree: *const std.zig.Ast,
edits: *std.ArrayList(Edit),
needs_render: *bool,

pub fn inspectFunction(self: Fixer, node: std.zig.Ast.Node.Index) !void {
    var buffer: [1]std.zig.Ast.Node.Index = undefined;
    const function = self.tree.fullFnProto(&buffer, node).?;
    if (syntax.hasMultilineSignature(self.tree, function)) {
        self.needs_render.* = true;
    }

    const rparen = syntax.closingParen(self.tree, function.lparen);
    if (self.tree.tokenTag(rparen - 1) == .comma) {
        const comma_start = self.tree.tokenStart(rparen - 1);
        try self.edits.append(self.allocator, .{
            .start = comma_start,
            .end = comma_start + self.tree.tokenSlice(rparen - 1).len,
            .replacement = "",
        });
        self.needs_render.* = true;
    }
}

pub fn fixStatementIf(self: Fixer, node: std.zig.Ast.Node.Index) !void {
    const conditional = self.tree.fullIf(node).?;
    const then_tag = self.tree.nodeTag(conditional.ast.then_expr);

    // A nested `if` in then position is wrapped as a whole; the next pass
    // braces its own branches once it has become a block statement.
    if (!syntax.isBlock(then_tag)) {
        try self.wrapBranch(conditional.ast.then_expr, conditional.ast.else_expr != .none);
    }

    if (conditional.ast.else_expr.unwrap()) |else_expr| {
        const else_tag = self.tree.nodeTag(else_expr);
        if (!syntax.isBlock(else_tag) and else_tag != .if_simple and else_tag != .@"if") {
            try self.wrapBranch(else_expr, false);
        }
    }
}

fn wrapBranch(self: Fixer, node: std.zig.Ast.Node.Index, closes_before_else: bool) !void {
    const first_token = self.tree.firstToken(node);
    const last_token = self.tree.lastToken(node);
    const start = self.tree.tokenStart(first_token);
    const expression_end = self.tree.tokenStart(last_token) + self.tree.tokenSlice(last_token).len;

    // A branch such as `switch (x) {}` becomes a brace-terminated statement
    // inside the new block, so any semicolon after it must go. Every other
    // branch keeps its semicolon inside the block, or gains one before `else`.
    const ends_with_block = syntax.endsWithBlock(self.tree, node);
    const semicolon = last_token + 1;
    const has_semicolon = !closes_before_else and self.tree.tokenTag(semicolon) == .semicolon;

    if (!closes_before_else and !has_semicolon and !ends_with_block) {
        return;
    }

    const branch_end = if (has_semicolon) self.tree.tokenStart(semicolon) + self.tree.tokenSlice(semicolon).len else expression_end;
    const close_edit: Edit = .{
        .start = if (ends_with_block) expression_end else branch_end,
        .end = branch_end,
        .replacement = if (closes_before_else and !ends_with_block) "; }" else " }",
    };

    try self.edits.append(self.allocator, .{
        .start = start,
        .end = start,
        .replacement = "{ ",
    });
    try self.edits.append(self.allocator, close_edit);

    self.needs_render.* = true;
}
