const GenericBinding = @import("GenericBinding.zig").Type;
const chord = @import("chord.zig");
const GenericRouter = @import("GenericRouter.zig").Type;
const Capture = @import("RoutingCapture.zig");
const RouterLimits = @import("RouterLimits.zig");
const std = @import("std");

pub const Action = enum { next, detach };

/// Bounds shared by the router's tests; the timeout is arbitrary.
pub const limits: RouterLimits = .{
    .max_bindings = 8,
    .max_keys = 4,
    .max_physical_leases = 64,
    .sequence_timeout_ns = 1000 * std.time.ns_per_ms,
};
const Binding = GenericBinding(Action, 4);
const Router = GenericRouter(Action, limits);

test "native key routing needs no decoder and retains binding ownership through release" {
    var router = try Router.init(&.{try Binding.parse(&.{"ctrl+n"}, .next)});
    var capture: Capture = .{};
    var event = try chord.parseKey("ctrl+n");
    event.physical = .{ .value = 'n' };
    _ = try capture.apply(router.routeEvent(.{ .key = event, .now_ns = 1 }, .{}));
    try std.testing.expectEqualSlices(Action, &.{.next}, capture.actions[0..capture.action_count]);

    event.phase = .repeat;
    _ = try capture.apply(router.routeEvent(.{ .key = event, .now_ns = 2 }, .{}));
    event.phase = .release;
    event.mods = .{};
    _ = try capture.apply(router.routeEvent(.{ .key = event, .now_ns = 3 }, .{}));
    try std.testing.expectEqual(@as(usize, 1), capture.action_count);
    try std.testing.expectEqual(@as(usize, 0), capture.key_count);
}

test "binding timer expiries with nothing pending are a no-op" {
    var router = try Router.init(&.{try Binding.parse(&.{ "a", "b" }, .next)});
    var capture: Capture = .{};

    try std.testing.expect(router.expireBinding(std.math.maxInt(u64)) == .pending);
    try std.testing.expect(router.bindingDeadline() == null);

    const first = try chord.parseKey("a");
    _ = try capture.apply(router.routeEvent(.{ .key = first, .now_ns = 1 }, .{}));
    const deadline = router.bindingDeadline().?;
    try std.testing.expect(router.expireBinding(deadline - 1) == .pending);
    try std.testing.expectEqual(@as(usize, 0), capture.key_count);

    _ = try capture.apply(router.expireBinding(deadline));
    try std.testing.expectEqual(@as(usize, 1), capture.key_count);
    try std.testing.expectEqualDeep(first, capture.keys[0]);
    try std.testing.expect(router.bindingDeadline() == null);

    _ = try capture.apply(router.expireBinding(deadline));
    try std.testing.expectEqual(@as(usize, 1), capture.key_count);
    try std.testing.expectEqual(@as(usize, 0), capture.action_count);
}

test "native persistent prefix consumes unmatched keys without forwarding bytes" {
    const prefix = try chord.parseKey("ctrl+b");
    var router = try Router.initWithPrefix(&.{try Binding.parse(&.{ "ctrl+b", "n" }, .next)}, prefix);
    var capture: Capture = .{};
    _ = try capture.apply(router.routeEvent(.{ .key = prefix, .now_ns = 1 }, .{}));
    try std.testing.expect(router.prefixPending());
    const other = try chord.parseKey("x");
    _ = try capture.apply(router.routeEvent(.{ .key = other, .now_ns = 2 }, .{}));
    // Persistent-prefix misses are consumed, just as on the terminal adapter.
    try std.testing.expectEqual(@as(usize, 0), capture.key_count);
    try std.testing.expectEqual(@as(usize, 0), capture.action_count);
    try std.testing.expect(!router.prefixPending());
    _ = try capture.apply(router.routeEvent(.{ .key = other, .now_ns = 3 }, .{}));
    try std.testing.expectEqual(@as(usize, 1), capture.key_count);
    try std.testing.expectEqualDeep(other, capture.keys[0]);
}

test "semantic paste replays ordinary chords while pointer admission discards them" {
    const bindings = [_]Binding{try Binding.parse(&.{ "a", "b" }, .next)};
    const first = try chord.parseKey("a");
    var router = try Router.init(&bindings);
    var capture: Capture = .{};
    _ = try capture.apply(router.routeEvent(.{ .key = first, .now_ns = 1 }, .{}));
    _ = try capture.apply(router.interrupt());
    try std.testing.expectEqual(@as(usize, 1), capture.key_count);
    try std.testing.expectEqualDeep(first, capture.keys[0]);
    try std.testing.expect(router.bindingDeadline() == null);

    _ = try capture.apply(router.routeEvent(.{ .key = first, .now_ns = 2 }, .{}));
    router.cancelSequence();
    try std.testing.expectEqual(@as(usize, 1), capture.key_count);
    try std.testing.expect(router.bindingDeadline() == null);
    _ = try capture.apply(router.routeEvent(.{ .key = try chord.parseKey("b"), .now_ns = 3 }, .{}));
    try std.testing.expectEqual(@as(usize, 0), capture.action_count);
}

test "action decisions arm repeats only after execution with the resulting owner policy" {
    var router = try Router.init(&.{try Binding.parse(&.{"ctrl+n"}, .next)});
    var key = try chord.parseKey("ctrl+n");
    key.physical = .{ .value = 42 };
    const decision = router.routeEvent(.{ .key = key, .now_ns = 0 }, .{});
    try std.testing.expect(decision == .action);
    try std.testing.expect(router.repeatAction() == null);

    router.actionCompleted(decision.action, .{ .interval_ns = 100, .context = 7 });
    key.phase = .repeat;
    const due = router.routeEvent(.{ .key = key, .now_ns = 100 }, .{ .repeat_policy = .{ .interval_ns = 100, .context = 7 } });
    try std.testing.expect(due == .action);
    try std.testing.expect(due.action.repeated);
    const changed_owner = router.routeEvent(.{ .key = key, .now_ns = 200 }, .{ .repeat_policy = .{ .interval_ns = 100, .context = 8 } });
    try std.testing.expect(changed_owner == .discard);
    try std.testing.expect(router.repeatAction() == null);
}
