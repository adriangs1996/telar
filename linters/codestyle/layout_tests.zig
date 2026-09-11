const std = @import("std");
const analysis = @import("analysis.zig");
const Rule = @import("diagnostic.zig").Rule;

fn expectRules(expected: []const Rule, path: []const u8, source: [:0]const u8) !void {
    const violations = try analysis.lintFile(std.testing.allocator, source, path);
    defer std.testing.allocator.free(violations);

    try std.testing.expectEqual(expected.len, violations.len);
    for (expected, violations) |rule, violation| {
        try std.testing.expectEqual(rule, violation.rule);
    }
}

test "implicit structs use PascalCase including stateless handlers" {
    try expectRules(&.{}, "Counter.zig", "const Counter = @This();\nvalue: u64 = 0,\n");
    try expectRules(&.{}, "Handler.zig", "const Handler = @This();\npub fn execute() void {}\n");
    try expectRules(&.{.type_file_name}, "counter.zig", "value: u64 = 0,\n");
}

test "ordinary top-level structs and auxiliary structs require their own files" {
    try expectRules(&.{.ordinary_struct_declaration}, "counter.zig", "pub const Counter = struct { value: u64 = 0 };\n");
    try expectRules(&.{.ordinary_struct_declaration}, "Counter.zig", "const Counter = @This();\npub const Options = struct { enabled: bool };\n");
}

test "conditional and parenthesized type declarations cannot hide ordinary structs" {
    try expectRules(&.{.ordinary_struct_declaration}, "options.zig", "const Options = (struct {});\n");
    try expectRules(&.{.ordinary_struct_declaration}, "options.zig", "const Options = if (true) struct {} else void;\n");
    try expectRules(&.{ .ordinary_struct_declaration, .ordinary_struct_declaration }, "platform.zig", "const Native = switch (1) { 1 => struct {}, else => struct {} };\n");
    try expectRules(&.{}, "platform.zig", "const Native = if (true) @import(\"Native.zig\") else @import(\"Fallback.zig\");\n");
}

test "namespaces contain functions enums unions and value initializers" {
    try expectRules(&.{}, "events.zig",
        \\pub const Event = union(enum) { ready, value: u8 };
        \\pub const Mode = enum { idle, active };
        \\pub const defaults = .{ .enabled = true };
        \\pub fn run() void {}
    );
    try expectRules(&.{.namespace_file_name}, "Events.zig", "pub const Event = enum { ready };\n");
}

test "comments and strings do not declare structs or constructor imports" {
    try expectRules(&.{}, "examples.zig",
        \\// const Counter = struct {};
        \\const text = "const Router = @import(\"GenericRouter.zig\");";
        \\const sample =
        \\    \\pub const Counter = struct {};
        \\;
    );
}

test "a generic family exposes one public Type function not one public method" {
    try expectRules(&.{}, "GenericSlot.zig",
        \\pub fn Type(comptime T: type) type {
        \\    return struct {
        \\        value: T,
        \\        pub fn init(value: T) @This() { return .{ .value = value }; }
        \\        pub fn get(self: @This()) T { return self.value; }
        \\    };
        \\}
        \\fn helper() type { return u8; }
        \\test "instantiation" { _ = Type(u8); }
    );
}

test "generic constructors require their family filename and Type spelling" {
    try expectRules(&.{.generic_constructor}, "generic_slot.zig", "pub fn Type(comptime T: type) type { return T; }\n");
    try expectRules(&.{.generic_constructor}, "GenericSlot.zig", "pub fn buildType(comptime T: type) type { return T; }\n");
    try expectRules(&.{.generic_file}, "Generic.zig", "pub fn Type(comptime T: type) type { return T; }\n");
    try expectRules(&.{.generic_file}, "Genericslot.zig", "pub fn Type(comptime T: type) type { return T; }\n");
}

test "generic files reject missing private and non-type factories" {
    try expectRules(&.{.generic_file}, "GenericSlot.zig", "");
    try expectRules(&.{.generic_file}, "GenericSlot.zig", "fn Type(comptime T: type) type { return T; }\n");
    try expectRules(&.{.generic_file}, "GenericSlot.zig", "pub fn Type() u8 { return 0; }\n");
}

test "generic files reject a second public top-level function" {
    try expectRules(&.{.generic_file}, "GenericSlot.zig",
        \\pub fn Type(comptime T: type) type { return T; }
        \\pub fn helper() void {}
    );
}

test "generic constructor imports retain the prefix and select Type directly" {
    try expectRules(&.{}, "input.zig",
        \\const GenericSlot = @import("GenericSlot.zig").Type;
        \\const Slot = GenericSlot(u8);
    );
    try expectRules(&.{.generic_import}, "input.zig", "const Slot = @import(\"GenericSlot.zig\").Type;\n");
    try expectRules(&.{.generic_import}, "input.zig", "const GenericSlot = @import(\"GenericSlot.zig\");\n");
}

test "constructor naming also applies to local imports and module exports" {
    try expectRules(&.{.generic_import}, "input.zig", "fn run() void { const Slot = @import(\"GenericSlot.zig\").Type; _ = Slot; }\n");
    try expectRules(&.{}, "input.zig", "const GenericSlot = @import(\"telar-core\").GenericSlot;\n");
    try expectRules(&.{.generic_import}, "input.zig", "const Slot = @import(\"telar-core\").GenericSlot;\n");
}

test "explicit ABI and packed layouts use dedicated PascalCase files" {
    try expectRules(&.{}, "Flags.zig", "pub const Flags = packed struct(u8) { bits: u8 };\n");
    try expectRules(&.{}, "Coordinate.zig", "pub const Coordinate = extern struct { x: i16, y: i16 };\n");
    try expectRules(&.{.type_file_name}, "flags.zig", "pub const Flags = packed struct(u8) { bits: u8 };\n");
    try expectRules(&.{.dedicated_layout_file}, "Layouts.zig", "pub const A = extern struct { x: i16 };\npub const B = extern struct { x: i16 };\n");
    try expectRules(&.{.dedicated_layout_file}, "Key.zig", "const Key = @This();\npub const Mods = packed struct(u8) { bits: u8 };\n");
}

test "malformed input reports syntax instead of guessing a filename category" {
    const violations = try analysis.lintFile(std.testing.allocator, "fn broken( void {}\n", "Broken.zig");
    defer std.testing.allocator.free(violations);

    try std.testing.expect(violations.len != 0);
    for (violations) |violation| {
        try std.testing.expectEqual(Rule.invalid_syntax, violation.rule);
    }
}
