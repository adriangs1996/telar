//! An `@import` is the whole initializer of a `const` declaration (or a
//! `_ = @import(...)` test reference), never part of an expression. A
//! declaration may still choose between imports per platform, as in
//! `const impl = if (windows) @import("windows.zig") else @import("posix.zig");`.
const std = @import("std");
const Ast = std.zig.Ast;

/// Returns the `@import` tokens used inside expressions. The caller owns
/// the slice.
///
/// ```zig
/// const inline_imports = try find(allocator, &tree);
/// defer allocator.free(inline_imports);
/// ```
pub fn find(allocator: std.mem.Allocator, tree: *const Ast) ![]Ast.TokenIndex {
    var found: std.ArrayList(Ast.TokenIndex) = .empty;
    errdefer found.deinit(allocator);

    var token: Ast.TokenIndex = 0;
    while (token < tree.tokens.len) : (token += 1) {
        if (tree.tokenTag(token) != .builtin or !std.mem.eql(u8, tree.tokenSlice(token), "@import")) {
            continue;
        }

        if (!declares(tree, token)) {
            try found.append(allocator, token);
        }
    }

    return found.toOwnedSlice(allocator);
}

fn declares(tree: *const Ast, token: Ast.TokenIndex) bool {
    if (token < 2) {
        return false;
    }

    switch (tree.tokenTag(token - 1)) {
        .keyword_else, .r_paren, .equal_angle_bracket_right => return true,
        .equal => {},
        else => return false,
    }

    const target = token - 2;
    const introduced = tree.tokenTag(target) == .identifier and target > 0 and tree.tokenTag(target - 1) == .keyword_const;
    const discarded = tree.tokenTag(target) == .identifier and std.mem.eql(u8, tree.tokenSlice(target), "_");
    if (!introduced and !discarded) {
        return false;
    }

    // `@import ( "path" )` then any `.member` chain, then `;`.
    var next = token + 4;
    if (next > tree.tokens.len or tree.tokenTag(token + 3) != .r_paren) {
        return false;
    }

    while (next + 1 < tree.tokens.len and tree.tokenTag(next) == .period and tree.tokenTag(next + 1) == .identifier) {
        next += 2;
    }

    return next < tree.tokens.len and tree.tokenTag(next) == .semicolon;
}

fn expectInline(expected: usize, source: [:0]const u8) !void {
    var tree = try Ast.parse(std.testing.allocator, source, .zig);
    defer tree.deinit(std.testing.allocator);
    const tokens = try find(std.testing.allocator, &tree);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(expected, tokens.len);
}

test "declared and discarded imports are accepted" {
    try expectInline(0,
        \\const std = @import("std");
        \\const Router = @import("GenericRouter.zig").Type;
        \\test {
        \\    _ = @import("tests.zig");
        \\}
    );
}

test "a declaration may choose between imports per platform" {
    try expectInline(0,
        \\const Native = if (true) @import("Native.zig") else @import("Fallback.zig");
        \\const impl = switch (1) { 1 => @import("windows.zig"), else => @import("posix.zig") };
    );
}

test "imports inside expressions are reported" {
    try expectInline(2,
        \\var label: @import("Label.zig") = .{};
        \\fn size() usize { return @sizeOf(@import("Cache.zig")); }
    );
}
