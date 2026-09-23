//! One receiver whose name differs from the receiver rule.
const std = @import("std");
const Ast = std.zig.Ast;

/// The `fn_decl` node that owns the receiver.
function: Ast.Node.Index,
name_token: Ast.TokenIndex,
expected: []const u8,
