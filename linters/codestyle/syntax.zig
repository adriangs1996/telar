const std = @import("std");

const Ast = std.zig.Ast;

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
