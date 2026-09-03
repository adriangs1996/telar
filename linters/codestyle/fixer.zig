const std = @import("std");
const syntax = @import("syntax.zig");

const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Edit = struct {
    start: usize,
    end: usize,
    replacement: []const u8,
};

const Fixer = struct {
    allocator: Allocator,
    tree: *const Ast,
    edits: *std.ArrayList(Edit),
    needs_render: *bool,

    fn inspectFunction(self: Fixer, node: Ast.Node.Index) !void {
        var buffer: [1]Ast.Node.Index = undefined;
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

    fn fixStatementIf(self: Fixer, node: Ast.Node.Index) !void {
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

    fn wrapBranch(self: Fixer, node: Ast.Node.Index, closes_before_else: bool) !void {
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
};

/// Applies only deterministic fixes and returns null when the source is unchanged.
///
/// Fixes are applied until the source stops changing, because bracing a branch
/// can expose statements that were not reachable in the previous shape.
///
/// ```zig
/// const fixed = try fixSource(allocator, "fn run(value: u8,) void {}\n");
/// defer if (fixed) |source| allocator.free(source);
/// ```
pub fn fixSource(allocator: Allocator, source: [:0]const u8) !?[:0]u8 {
    var current = try fixOnce(allocator, source) orelse return null;
    errdefer allocator.free(current);

    while (try fixOnce(allocator, current)) |next| {
        allocator.free(current);
        current = next;
    }

    return current;
}

fn fixOnce(allocator: Allocator, source: [:0]const u8) !?[:0]u8 {
    var tree = try Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);

    if (tree.errors.len != 0) {
        return null;
    }

    var edits: std.ArrayList(Edit) = .empty;
    defer edits.deinit(allocator);

    var needs_render = false;
    const fixer: Fixer = .{
        .allocator = allocator,
        .tree = &tree,
        .edits = &edits,
        .needs_render = &needs_render,
    };

    var node_number: usize = 0;
    while (node_number < tree.nodes.len) : (node_number += 1) {
        const node: Ast.Node.Index = @enumFromInt(node_number);

        switch (tree.nodeTag(node)) {
            .fn_proto, .fn_proto_multi, .fn_proto_one, .fn_proto_simple => try fixer.inspectFunction(node),
            else => {},
        }
    }

    const statement_ifs = try syntax.statementIfNodes(allocator, &tree);
    defer allocator.free(statement_ifs);

    for (statement_ifs) |statement_if| {
        try fixer.fixStatementIf(statement_if);
    }

    if (!needs_render) {
        return null;
    }

    std.sort.insertion(Edit, edits.items, {}, editBefore);
    const edited = try applyEdits(allocator, source, edits.items);
    defer allocator.free(edited);

    var edited_tree = try Ast.parse(allocator, edited, .zig);
    defer edited_tree.deinit(allocator);

    if (edited_tree.errors.len != 0) {
        return error.InvalidGeneratedSource;
    }

    const rendered = try edited_tree.renderAlloc(allocator);
    defer allocator.free(rendered);

    if (std.mem.eql(u8, source, rendered)) {
        return null;
    }

    return @as(?[:0]u8, try allocator.dupeZ(u8, rendered));
}

fn applyEdits(allocator: Allocator, source: []const u8, edits: []const Edit) ![:0]u8 {
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var cursor: usize = 0;
    for (edits) |edit| {
        if (edit.start < cursor or edit.end < edit.start or edit.end > source.len) {
            return error.OverlappingEdits;
        }

        try output.writer.writeAll(source[cursor..edit.start]);
        try output.writer.writeAll(edit.replacement);
        cursor = edit.end;
    }

    try output.writer.writeAll(source[cursor..]);
    return output.toOwnedSliceSentinel(0);
}

fn editBefore(_: void, left: Edit, right: Edit) bool {
    if (left.start == right.start) {
        return left.end > right.end;
    }

    return left.start < right.start;
}

fn expectFixed(expected: []const u8, source: [:0]const u8) !void {
    const fixed = (try fixSource(std.testing.allocator, source)).?;
    defer std.testing.allocator.free(fixed);

    try std.testing.expectEqualStrings(expected, fixed);
}

test "fixes multiline signatures and trailing parameter commas" {
    try expectFixed(
        \\fn combine(first: u8, second: u8) u8 {
        \\    return first + second;
        \\}
        \\
    ,
        \\fn combine(
        \\    first: u8,
        \\    second: u8,
        \\) u8 {
        \\    return first + second;
        \\}
    );
}

test "fixes multiline signatures without trailing parameter commas" {
    try expectFixed(
        \\fn identity(value: u8) u8 {
        \\    return value;
        \\}
        \\
    ,
        \\fn identity(
        \\    value: u8
        \\) u8 {
        \\    return value;
        \\}
    );
}

test "wraps an if statement branch" {
    try expectFixed(
        \\fn choose(value: bool) bool {
        \\    if (value) {
        \\        return true;
        \\    }
        \\    return false;
        \\}
        \\
    ,
        \\fn choose(value: bool) bool {
        \\    if (value) return true;
        \\    return false;
        \\}
    );
}

test "wraps both branches of an if statement" {
    try expectFixed(
        \\fn choose(value: bool) bool {
        \\    if (value) {
        \\        return true;
        \\    } else {
        \\        return false;
        \\    }
        \\}
        \\
    ,
        \\fn choose(value: bool) bool {
        \\    if (value) return true else return false;
        \\}
    );
}

test "wraps statement branches across an else if chain" {
    try expectFixed(
        \\fn choose(first: bool, second: bool) u8 {
        \\    if (first) {
        \\        return 1;
        \\    } else if (second) {
        \\        return 2;
        \\    } else {
        \\        return 3;
        \\    }
        \\}
        \\
    ,
        \\fn choose(first: bool, second: bool) u8 {
        \\    if (first) return 1 else if (second) return 2 else return 3;
        \\}
    );
}

test "wraps nested if statements across passes" {
    try expectFixed(
        \\fn run(first: ?u8, second: bool) bool {
        \\    if (first) |_| {
        \\        if (second) {
        \\            return true;
        \\        }
        \\    }
        \\    return false;
        \\}
        \\
    ,
        \\fn run(first: ?u8, second: bool) bool {
        \\    if (first) |_| if (second) return true;
        \\    return false;
        \\}
    );
}

test "wraps a switch branch without keeping its semicolon" {
    try expectFixed(
        \\fn run(value: bool) void {
        \\    if (value) {
        \\        switch (value) {
        \\            else => {},
        \\        }
        \\    }
        \\}
        \\
    ,
        \\fn run(value: bool) void {
        \\    if (value) switch (value) { else => {} };
        \\}
    );
}

test "wraps a switch branch followed by else" {
    try expectFixed(
        \\fn run(value: bool) void {
        \\    if (value) {
        \\        switch (value) {
        \\            else => {},
        \\        }
        \\    } else {
        \\        return;
        \\    }
        \\}
        \\
    ,
        \\fn run(value: bool) void {
        \\    if (value) switch (value) { else => {} } else return;
        \\}
    );
}

test "wraps an else branch holding an error switch" {
    try expectFixed(
        \\fn run(value: anyerror!void) !void {
        \\    if (value) |_| {
        \\        return;
        \\    } else |err| {
        \\        switch (err) {
        \\            else => return err,
        \\        }
        \\    }
        \\}
        \\
    ,
        \\fn run(value: anyerror!void) !void {
        \\    if (value) |_| {
        \\        return;
        \\    } else |err| switch (err) {
        \\        else => return err,
        \\    }
        \\}
    );
}

test "wraps loop branches according to their body" {
    try expectFixed(
        \\fn run(value: bool, items: []const u8) void {
        \\    if (value) {
        \\        for (items) |_| {}
        \\    }
        \\    if (value) {
        \\        for (items) |item| _ = item;
        \\    }
        \\}
        \\
    ,
        \\fn run(value: bool, items: []const u8) void {
        \\    if (value) for (items) |_| {};
        \\    if (value) for (items) |item| _ = item;
        \\}
    );
}

test "keeps if expressions unchanged" {
    const source = "fn choose(value: bool) bool { return if (value) true else false; }\n";
    const fixed = try fixSource(std.testing.allocator, source);

    try std.testing.expectEqual(@as(?[:0]u8, null), fixed);
}

test "keeps excessive parameter counts unchanged" {
    const source = "fn combine(a: u8, b: u8, c: u8, d: u8) void { _ = .{ a, b, c, d }; }\n";
    const fixed = try fixSource(std.testing.allocator, source);

    try std.testing.expectEqual(@as(?[:0]u8, null), fixed);
}
