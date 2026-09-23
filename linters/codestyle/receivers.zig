//! Receiver naming: a method of a type names its receiver `self`, and a
//! procedure over a process model (`ClientModel`, `RuntimeModel`) names it
//! `model`. A method is a function declared in a container whose first
//! parameter is that container, by value or by pointer.
const std = @import("std");
const Ast = std.zig.Ast;

const process_models = [_][]const u8{ "ClientModel", "RuntimeModel" };

const Receiver = @import("Receiver.zig");

/// Lists every misnamed receiver in the tree. The caller owns the slice.
///
/// ```zig
/// const receivers = try find(allocator, &tree);
/// defer allocator.free(receivers);
/// ```
pub fn find(allocator: std.mem.Allocator, tree: *const Ast) ![]Receiver {
    var found: std.ArrayList(Receiver) = .empty;
    errdefer found.deinit(allocator);

    try inspectContainer(allocator, tree, tree.rootDecls(), null, &found);

    var node_number: usize = 0;
    while (node_number < tree.nodes.len) : (node_number += 1) {
        const node: Ast.Node.Index = @enumFromInt(node_number);
        if (tree.nodeTag(node) == .root) {
            continue;
        }

        var buffer: [2]Ast.Node.Index = undefined;
        const container = tree.fullContainerDecl(&buffer, node) orelse continue;
        try inspectContainer(allocator, tree, container.ast.members, declaredName(tree, node), &found);
    }

    return found.toOwnedSlice(allocator);
}

fn inspectContainer(allocator: std.mem.Allocator, tree: *const Ast, members: []const Ast.Node.Index, name: ?[]const u8, found: *std.ArrayList(Receiver)) !void {
    var self_names: [8][]const u8 = undefined;
    var self_count: usize = 0;
    if (name) |value| {
        self_names[0] = value;
        self_count = 1;
    }

    for (members) |member| {
        const declaration = tree.fullVarDecl(member) orelse continue;
        const init = declaration.ast.init_node.unwrap() orelse continue;
        if (isThis(tree, init) and self_count < self_names.len) {
            self_names[self_count] = tree.tokenSlice(declaration.ast.mut_token + 1);
            self_count += 1;
        }
    }

    for (members) |member| {
        if (tree.nodeTag(member) != .fn_decl) {
            continue;
        }

        const receiver = misnamedReceiver(tree, member, self_names[0..self_count]) orelse continue;
        try found.append(allocator, receiver);
    }
}

fn misnamedReceiver(tree: *const Ast, function: Ast.Node.Index, self_names: []const []const u8) ?Receiver {
    const proto, _ = tree.nodeData(function).node_and_node;
    var buffer: [1]Ast.Node.Index = undefined;
    const prototype = tree.fullFnProto(&buffer, proto) orelse return null;
    var parameters = prototype.iterate(tree);
    const first = parameters.next() orelse return null;
    const name_token = first.name_token orelse return null;
    const type_expression = first.type_expr orelse return null;
    const type_name = baseTypeName(tree, type_expression) orelse return null;
    const expected = expectedName(type_name, self_names) orelse return null;
    const actual = tree.tokenSlice(name_token);
    if (std.mem.eql(u8, actual, expected) or std.mem.eql(u8, actual, "_")) {
        return null;
    }

    return .{
        .function = function,
        .name_token = name_token,
        .expected = expected,
    };
}

fn expectedName(type_name: []const u8, self_names: []const []const u8) ?[]const u8 {
    for (process_models) |model| {
        if (std.mem.eql(u8, type_name, model)) {
            return "model";
        }
    }

    for (self_names) |self_name| {
        if (std.mem.eql(u8, type_name, self_name)) {
            return "self";
        }
    }

    return null;
}

/// The type a receiver names: `T`, `*T`, `*const T` or `module.T`.
fn baseTypeName(tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    const target = if (tree.fullPtrType(node)) |pointer| pointer.ast.child_type else node;
    switch (tree.nodeTag(target)) {
        .identifier, .field_access => {},
        else => return null,
    }

    const token = tree.lastToken(target);
    if (tree.tokenTag(token) != .identifier) {
        return null;
    }

    return tree.tokenSlice(token);
}

fn isThis(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma => std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@This"),
        else => false,
    };
}

/// The name a container is bound to, as in `const Name = struct { ... };`.
fn declaredName(tree: *const Ast, container: Ast.Node.Index) ?[]const u8 {
    var node_number: usize = 0;
    while (node_number < tree.nodes.len) : (node_number += 1) {
        const node: Ast.Node.Index = @enumFromInt(node_number);
        const declaration = tree.fullVarDecl(node) orelse continue;
        const init = declaration.ast.init_node.unwrap() orelse continue;
        if (init == container) {
            return tree.tokenSlice(declaration.ast.mut_token + 1);
        }
    }

    return null;
}

/// Whether `name` already appears as an identifier in the function, so a
/// rename to it would shadow or collide.
///
/// ```zig
/// if (usesName(tree, receiver.function, receiver.expected)) continue;
/// ```
pub fn usesName(tree: *const Ast, function: Ast.Node.Index, name: []const u8) bool {
    var token = tree.firstToken(function);
    const last = tree.lastToken(function);
    while (token <= last) : (token += 1) {
        if (tree.tokenTag(token) == .identifier and std.mem.eql(u8, tree.tokenSlice(token), name) and !isField(tree, token)) {
            return true;
        }
    }

    return false;
}

/// Whether an identifier token names a field (`.name`, or a field declared
/// in a container) rather than a binding.
pub fn isField(tree: *const Ast, token: Ast.TokenIndex) bool {
    if (token > 0 and tree.tokenTag(token - 1) == .period) {
        return true;
    }

    // A container field is `name: Type` whose name no `const`, `var`, `(`
    // or `|` introduces; a parameter follows `(` or `,` inside a prototype.
    if (tree.tokenTag(token + 1) != .colon or token == 0) {
        return false;
    }

    return switch (tree.tokenTag(token - 1)) {
        .l_brace, .semicolon, .doc_comment, .keyword_pub => true,
        .comma => !insideParentheses(tree, token),
        else => false,
    };
}

/// Whether the nearest unclosed bracket before `token` is a parenthesis.
fn insideParentheses(tree: *const Ast, token: Ast.TokenIndex) bool {
    var depth: usize = 0;
    var index = token;
    while (index > 0) {
        index -= 1;
        switch (tree.tokenTag(index)) {
            .r_paren, .r_brace, .r_bracket => depth += 1,
            .l_paren => {
                if (depth == 0) {
                    return true;
                }

                depth -= 1;
            },
            .l_brace, .l_bracket => {
                if (depth == 0) {
                    return false;
                }

                depth -= 1;
            },
            else => {},
        }
    }

    return false;
}

fn expectReceivers(expected: []const []const u8, source: [:0]const u8) !void {
    var tree = try Ast.parse(std.testing.allocator, source, .zig);
    defer tree.deinit(std.testing.allocator);
    const receivers = try find(std.testing.allocator, &tree);
    defer std.testing.allocator.free(receivers);

    try std.testing.expectEqual(expected.len, receivers.len);
    for (expected, receivers) |name, receiver| {
        try std.testing.expectEqualStrings(name, tree.tokenSlice(receiver.name_token));
    }
}

test "methods of a file type and of a nested struct name their receiver self" {
    try expectReceivers(&.{ "outbox", "item" },
        \\const Outbox = @This();
        \\len: u8,
        \\pub fn count(outbox: *const Outbox) u8 { return outbox.len; }
        \\pub fn clear(self: *Outbox) void { self.len = 0; }
        \\pub fn init() Outbox { return .{ .len = 0 }; }
        \\const Item = struct {
        \\    value: u8,
        \\    fn get(item: Item) u8 { return item.value; }
        \\};
    );
}

test "procedures over a process model name it model" {
    try expectReceivers(&.{"client_model"},
        \\const data = @import("model");
        \\pub fn receive(client_model: *data.ClientModel) void { _ = client_model; }
        \\pub fn refresh(model: *const data.ClientModel) void { _ = model; }
    );
}

test "container fields that share the receiver name are not bindings" {
    var tree = try Ast.parse(std.testing.allocator,
        \\const Tracker = @This();
        \\fn feed(tracker: *Tracker) void {
        \\    const Relay = struct {
        \\        tracker: *Tracker,
        \\        count: u8,
        \\    };
        \\    _ = Relay{ .tracker = tracker, .count = 0 };
        \\}
    , .zig);
    defer tree.deinit(std.testing.allocator);

    var fields: usize = 0;
    var token: Ast.TokenIndex = 0;
    while (token < tree.tokens.len) : (token += 1) {
        if (tree.tokenTag(token) == .identifier and std.mem.eql(u8, tree.tokenSlice(token), "tracker") and isField(&tree, token)) {
            fields += 1;
        }
    }

    try std.testing.expectEqual(@as(usize, 2), fields);
}

test "functions whose first parameter is another type are not methods" {
    try expectReceivers(&.{},
        \\const Pane = @This();
        \\pub fn fromBuffer(buffer: *Buffer) Pane { _ = buffer; return undefined; }
        \\const Buffer = struct {};
    );
}
