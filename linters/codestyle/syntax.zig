const std = @import("std");

const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;

/// Detects line breaks across a complete function prototype.
///
/// ```zig
/// const multiline = hasMultilineSignature(&tree, function);
/// ```
pub fn hasMultilineSignature(tree: *const Ast, function: Ast.full.FnProto) bool {
    const first_token = function.firstToken();
    const last_token = tree.lastToken(function.ast.proto_node);
    const start = tree.tokenStart(first_token);
    const end = tree.tokenStart(last_token) + tree.tokenSlice(last_token).len;

    return std.mem.indexOfScalar(u8, tree.source[start..end], '\n') != null;
}

/// Finds the parenthesis matching a function prototype's opening parenthesis.
///
/// ```zig
/// const rparen = closingParen(&tree, function.lparen);
/// ```
pub fn closingParen(tree: *const Ast, lparen: Ast.TokenIndex) Ast.TokenIndex {
    var depth: usize = 1;
    var token = lparen + 1;

    while (depth != 0) : (token += 1) {
        switch (tree.tokenTag(token)) {
            .l_paren => depth += 1,
            .r_paren => depth -= 1,
            .eof => unreachable,
            else => {},
        }
    }

    return token - 1;
}

/// Recognizes every block representation emitted by the Zig parser.
///
/// ```zig
/// if (isBlock(tree.nodeTag(node))) {}
/// ```
pub fn isBlock(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .block, .block_semicolon, .block_two, .block_two_semicolon => true,
        else => false,
    };
}

/// Returns every `if` used as a statement, including `else if` continuations.
///
/// ```zig
/// const nodes = try statementIfNodes(allocator, &tree);
/// defer allocator.free(nodes);
/// ```
pub fn statementIfNodes(allocator: Allocator, tree: *const Ast) ![]Ast.Node.Index {
    var nodes: std.ArrayList(Ast.Node.Index) = .empty;
    errdefer nodes.deinit(allocator);

    var node_number: usize = 0;
    while (node_number < tree.nodes.len) : (node_number += 1) {
        const node: Ast.Node.Index = @enumFromInt(node_number);
        if (!isBlock(tree.nodeTag(node))) {
            continue;
        }

        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, node).?;

        for (statements) |statement| {
            var conditional_node = statement;

            while (isIf(tree.nodeTag(conditional_node))) {
                try nodes.append(allocator, conditional_node);

                const conditional = tree.fullIf(conditional_node).?;
                const else_node = conditional.ast.else_expr.unwrap() orelse break;
                conditional_node = else_node;
            }
        }
    }

    return nodes.toOwnedSlice(allocator);
}

fn isIf(tag: Ast.Node.Tag) bool {
    return tag == .if_simple or tag == .@"if";
}

test "classifies statement if chains without classifying if expressions" {
    const source: [:0]const u8 =
        \\fn choose(first: bool, second: bool) u8 {
        \\    if (first) {}
        \\    if (first) return 1 else if (second) return 2 else return 3;
        \\}
        \\fn expression(value: bool) u8 {
        \\    return if (value) 1 else 2;
        \\}
    ;
    var tree = try Ast.parse(std.testing.allocator, source, .zig);
    defer tree.deinit(std.testing.allocator);

    const nodes = try statementIfNodes(std.testing.allocator, &tree);
    defer std.testing.allocator.free(nodes);

    try std.testing.expectEqual(@as(usize, 3), nodes.len);
}
