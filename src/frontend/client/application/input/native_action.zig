//! Application preflight for one source-independent native action.

const std = @import("std");
const input = @import("../../../input/root.zig");
const action_routing = @import("action_routing.zig");

const Action = input.action.Action;

pub const Authority = struct {
    copy_mode_active: bool,
};

pub const Control = action_routing.Control;

pub const Effects = struct {
    context: *anyopaque,
    leave_copy_mode: *const fn (*anyopaque) anyerror!void,
    deliver: *const fn (*anyopaque, Action) anyerror!Control,
};

pub const NativeActionHandler = struct {
    effects: Effects,

    /// Retires copy mode before delivering any other native action. This
    /// policy applies identically to host, Lua and plugin action sources.
    ///
    /// ```zig
    /// const control = try handler.execute(action, authority);
    /// ```
    pub fn execute(handler: *NativeActionHandler, value: Action, authority: Authority) !Control {
        const preserves_copy_mode = switch (value) {
            .enter_copy_mode => true,
            else => false,
        };
        if (authority.copy_mode_active and !preserves_copy_mode) {
            try handler.effects.leave_copy_mode(handler.effects.context);
        }

        return handler.effects.deliver(handler.effects.context, value);
    }
};

const Event = enum {
    leave_copy_mode,
    deliver,
};

const Failure = enum {
    none,
    leave_copy_mode,
    deliver,
};

const Capture = struct {
    events: [2]Event = undefined,
    event_count: usize = 0,
    delivered: ?Action = null,
    control: Control = .continue_routing,
    failure: Failure = .none,

    fn effects(capture: *Capture) Effects {
        return .{
            .context = capture,
            .leave_copy_mode = leaveCopyMode,
            .deliver = deliver,
        };
    }

    fn leaveCopyMode(raw_context: *anyopaque) !void {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        capture.record(.leave_copy_mode);

        if (capture.failure == .leave_copy_mode) {
            return error.CopyModeLeaveFailed;
        }
    }

    fn deliver(raw_context: *anyopaque, value: Action) !Control {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        capture.record(.deliver);
        capture.delivered = value;

        if (capture.failure == .deliver) {
            return error.NativeActionDeliveryFailed;
        }

        return capture.control;
    }

    fn record(capture: *Capture, event: Event) void {
        capture.events[capture.event_count] = event;
        capture.event_count += 1;
    }

    fn eventSlice(capture: *const Capture) []const Event {
        return capture.events[0..capture.event_count];
    }
};

test "NativeActionHandler retires active copy mode before native delivery" {
    var capture: Capture = .{ .control = .stop };
    var handler: NativeActionHandler = .{ .effects = capture.effects() };
    const action = Action.detach;

    try std.testing.expectEqual(
        Control.stop,
        try handler.execute(action, .{ .copy_mode_active = true }),
    );

    try std.testing.expectEqualSlices(Event, &.{ .leave_copy_mode, .deliver }, capture.eventSlice());
    try std.testing.expectEqualDeep(action, capture.delivered.?);
}

test "NativeActionHandler preserves copy mode for entry and inactive state" {
    var capture: Capture = .{};
    var handler: NativeActionHandler = .{ .effects = capture.effects() };

    try std.testing.expectEqual(
        Control.continue_routing,
        try handler.execute(.enter_copy_mode, .{ .copy_mode_active = true }),
    );
    try std.testing.expectEqualSlices(Event, &.{.deliver}, capture.eventSlice());

    capture = .{};
    handler = .{ .effects = capture.effects() };
    _ = try handler.execute(.toggle_sidebar, .{ .copy_mode_active = false });
    try std.testing.expectEqualSlices(Event, &.{.deliver}, capture.eventSlice());
}

test "NativeActionHandler stops before delivery when copy-mode retirement fails" {
    var capture: Capture = .{ .failure = .leave_copy_mode };
    var handler: NativeActionHandler = .{ .effects = capture.effects() };

    try std.testing.expectError(
        error.CopyModeLeaveFailed,
        handler.execute(.toggle_sidebar, .{ .copy_mode_active = true }),
    );

    try std.testing.expectEqualSlices(Event, &.{.leave_copy_mode}, capture.eventSlice());
    try std.testing.expect(capture.delivered == null);
}

test "NativeActionHandler retains completed preflight when delivery fails" {
    var capture: Capture = .{ .failure = .deliver };
    var handler: NativeActionHandler = .{ .effects = capture.effects() };

    try std.testing.expectError(
        error.NativeActionDeliveryFailed,
        handler.execute(.toggle_sidebar, .{ .copy_mode_active = true }),
    );

    try std.testing.expectEqualSlices(Event, &.{ .leave_copy_mode, .deliver }, capture.eventSlice());
    try std.testing.expectEqualDeep(Action.toggle_sidebar, capture.delivered.?);
}
