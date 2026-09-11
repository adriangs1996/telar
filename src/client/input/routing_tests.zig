const std = @import("std");
const input = @import("root.zig");
pub const keybind = input.keybind;
pub const Action = enum { next, detach };
const Binding = keybind.Binding(Action, 4);
const Router = keybind.Router(Action, .{ .max_bindings = 8, .max_keys = 4, .input_capacity = 64, .held_capacity = 32 }, struct {});

const Capture = @import("Capture.zig");

test "native key routing needs no decoder and retains binding ownership through release" {
    var router = try Router.init(&.{try Binding.parse(&.{"ctrl+n"}, .next)});
    var capture: Capture = .{};
    var event = try keybind.parseKey("ctrl+n");
    event.physical = .{ .value = 'n' };
    _ = try router.routeEvent(.{ .key = event, .raw = "", .now_ns = 1 }, &capture);
    try std.testing.expectEqualSlices(Action, &.{.next}, capture.actions[0..capture.action_count]);

    event.phase = .repeat;
    _ = try router.routeEvent(.{ .key = event, .raw = "", .now_ns = 2 }, &capture);
    event.phase = .release;
    event.mods = .{};
    _ = try router.routeEvent(.{ .key = event, .raw = "", .now_ns = 3 }, &capture);
    try std.testing.expectEqual(@as(usize, 1), capture.action_count);
    try std.testing.expectEqual(@as(usize, 0), capture.key_count);
    try std.testing.expect(router.inputDeadline() == null);
}

test "native persistent prefix consumes unmatched keys without forwarding bytes" {
    const prefix = try keybind.parseKey("ctrl+b");
    var router = try Router.initWithPrefix(&.{try Binding.parse(&.{ "ctrl+b", "n" }, .next)}, prefix);
    var capture: Capture = .{};
    _ = try router.routeEvent(.{ .key = prefix, .raw = "", .now_ns = 1 }, &capture);
    try std.testing.expect(router.prefixPending());
    const other = try keybind.parseKey("x");
    _ = try router.routeEvent(.{ .key = other, .raw = "", .now_ns = 2 }, &capture);
    // Persistent-prefix misses are consumed, just as on the terminal adapter.
    try std.testing.expectEqual(@as(usize, 0), capture.key_count);
    try std.testing.expectEqual(@as(usize, 0), capture.action_count);
    try std.testing.expect(!router.prefixPending());
    _ = try router.routeEvent(.{ .key = other, .raw = "", .now_ns = 3 }, &capture);
    try std.testing.expectEqual(@as(usize, 1), capture.key_count);
    try std.testing.expectEqualDeep(other, capture.keys[0]);
}
