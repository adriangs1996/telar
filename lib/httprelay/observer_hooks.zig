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
