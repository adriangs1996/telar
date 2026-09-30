//! Optional observer methods. A relay calls a hook only when the observer
//! it was given declares it, so observers that ignore an event stay empty.

/// Whether an observer, passed by value or by pointer, declares `name`.
///
/// ```zig
/// if (comptime observer_hooks.declares(@TypeOf(observer), "headTooLarge")) {
///     observer.headTooLarge();
/// }
/// ```
pub fn declares(comptime Observer: type, comptime name: []const u8) bool {
    const Declared = switch (@typeInfo(Observer)) {
        .pointer => |pointer| pointer.child,
        else => Observer,
    };

    return switch (@typeInfo(Declared)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(Declared, name),
        else => false,
    };
}

const std = @import("std");

/// An observer with one hook, for the tests.
const Hooked = struct {
    pub fn headTooLarge(_: Hooked) void {}
};

test "a hook is declared by value, by pointer, and never by a non-container" {
    try std.testing.expect(declares(Hooked, "headTooLarge"));
    try std.testing.expect(declares(*Hooked, "headTooLarge"));
    try std.testing.expect(!declares(Hooked, "lineTooLong"));
    try std.testing.expect(!declares(void, "headTooLarge"));
}
