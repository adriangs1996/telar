//! Application policy for routing one pointer event inside a pane.

const std = @import("std");
const core = @import("telar-core");
const input_capability = @import("../../../input/root.zig");
const presentation = @import("../../../presentation/root.zig");
const workspace_capability = @import("../../../workspace/root.zig");

const mouse_protocol = input_capability.mouse_protocol;
const multiplexer = workspace_capability.multiplexer;
const schema = core.schema;
const term = presentation.screen;

pub const Command = struct {
    event: term.Event.Mouse,
    exterior_pixels: bool,
    cell_width_px: u16,
    cell_height_px: u16,
};

pub const ScrollEffect = struct {
    pane_id: schema.PaneId,
    delta: i32,
};

pub const ReportEffect = struct {
    plan: multiplexer.PaneMousePlan,
    command: Command,
};

pub const Effect = union(enum) {
    viewport: ScrollEffect,
    alternate_scroll: ScrollEffect,
    report: ReportEffect,
};

pub const Outcome = enum {
    ignored,
    viewport_selected,
    alternate_scroll_selected,
    report_selected,
};

pub const Plans = struct {
    context: *anyopaque,
    resolve: *const fn (*anyopaque, term.Event.Mouse) ?multiplexer.PaneMousePlan,
};

pub const Effects = struct {
    context: *anyopaque,
    apply: *const fn (*anyopaque, Effect) anyerror!void,
};

pub const PaneMouseHandler = struct {
    plans: Plans,
    effects: Effects,

    /// Resolves one pane snapshot, then selects exactly one viewport,
    /// alternate-scroll or child mouse-report effect.
    ///
    /// ```zig
    /// const outcome = try handler.execute(command);
    /// ```
    pub fn execute(handler: *PaneMouseHandler, command: Command) !Outcome {
        const plan = handler.plans.resolve(handler.plans.context, command.event) orelse return .ignored;
        const wheel_delta: ?i32 = switch (command.event.kind) {
            .scroll_up => -3,
            .scroll_down => 3,
            else => null,
        };
        const tracked = plan.protocol.sgr and
            mouse_protocol.tracked(plan.protocol.tracking, command.event.kind);

        if (wheel_delta) |delta| {
            if (!tracked) {
                if (plan.alternate_scroll and plan.at_bottom) {
                    try handler.effects.apply(handler.effects.context, .{ .alternate_scroll = .{
                        .pane_id = plan.pane_id,
                        .delta = delta,
                    } });
                    return .alternate_scroll_selected;
                }

                try handler.effects.apply(handler.effects.context, .{ .viewport = .{
                    .pane_id = plan.pane_id,
                    .delta = delta,
                } });
                return .viewport_selected;
            }
        }

        if (!tracked) {
            return .ignored;
        }

        try handler.effects.apply(handler.effects.context, .{ .report = .{
            .plan = plan,
            .command = command,
        } });
        return .report_selected;
    }
};

const Capture = struct {
    plan: ?multiplexer.PaneMousePlan = null,
    effect: ?Effect = null,
    effect_count: usize = 0,
    fail: bool = false,

    fn plans(capture: *Capture) Plans {
        return .{ .context = capture, .resolve = resolve };
    }

    fn effects(capture: *Capture) Effects {
        return .{ .context = capture, .apply = apply };
    }

    fn resolve(raw_context: *anyopaque, _: term.Event.Mouse) ?multiplexer.PaneMousePlan {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));

        return capture.plan;
    }

    fn apply(raw_context: *anyopaque, effect: Effect) !void {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        capture.effect = effect;
        capture.effect_count += 1;

        if (capture.fail) {
            return error.PaneMouseEffectFailed;
        }
    }
};

fn testingPlan() multiplexer.PaneMousePlan {
    return .{
        .pane_id = @enumFromInt(3),
        .content = .{ .x = 10, .y = 4, .w = 20, .h = 8 },
        .protocol = .{},
        .alternate_scroll = false,
        .at_bottom = true,
    };
}

fn testingCommand(kind: term.Event.Mouse.Kind) Command {
    return .{
        .event = .{ .x = 12, .y = 6, .kind = kind },
        .exterior_pixels = false,
        .cell_width_px = 0,
        .cell_height_px = 0,
    };
}

test "PaneMouseHandler selects viewport or alternate scroll for untracked wheels" {
    var capture: Capture = .{ .plan = testingPlan() };
    var handler: PaneMouseHandler = .{
        .plans = capture.plans(),
        .effects = capture.effects(),
    };

    try std.testing.expectEqual(Outcome.viewport_selected, try handler.execute(testingCommand(.scroll_up)));
    try std.testing.expectEqual(@as(i32, -3), capture.effect.?.viewport.delta);

    var alternate_plan = testingPlan();
    alternate_plan.alternate_scroll = true;
    capture = .{ .plan = alternate_plan };
    handler = .{ .plans = capture.plans(), .effects = capture.effects() };

    try std.testing.expectEqual(Outcome.alternate_scroll_selected, try handler.execute(testingCommand(.scroll_down)));
    try std.testing.expectEqual(@as(i32, 3), capture.effect.?.alternate_scroll.delta);

    alternate_plan.at_bottom = false;
    capture = .{ .plan = alternate_plan };
    handler = .{ .plans = capture.plans(), .effects = capture.effects() };
    try std.testing.expectEqual(Outcome.viewport_selected, try handler.execute(testingCommand(.scroll_down)));
}

test "PaneMouseHandler reports only child-tracked events" {
    var plan = testingPlan();
    plan.protocol = .{ .tracking = .x10, .sgr = true, .pixels = true };
    var capture: Capture = .{ .plan = plan };
    var handler: PaneMouseHandler = .{
        .plans = capture.plans(),
        .effects = capture.effects(),
    };

    try std.testing.expectEqual(Outcome.report_selected, try handler.execute(testingCommand(.press)));
    try std.testing.expectEqualDeep(plan, capture.effect.?.report.plan);

    capture.effect = null;
    capture.effect_count = 0;
    try std.testing.expectEqual(Outcome.ignored, try handler.execute(testingCommand(.release)));
    try std.testing.expectEqual(@as(usize, 0), capture.effect_count);

    plan.protocol.tracking = .normal;
    capture = .{ .plan = plan };
    handler = .{ .plans = capture.plans(), .effects = capture.effects() };
    try std.testing.expectEqual(Outcome.report_selected, try handler.execute(testingCommand(.scroll_up)));
}

test "PaneMouseHandler ignores missing plans and propagates selected effect failures" {
    var capture: Capture = .{};
    var handler: PaneMouseHandler = .{
        .plans = capture.plans(),
        .effects = capture.effects(),
    };

    try std.testing.expectEqual(Outcome.ignored, try handler.execute(testingCommand(.press)));
    try std.testing.expectEqual(@as(usize, 0), capture.effect_count);

    capture = .{ .plan = testingPlan(), .fail = true };
    handler = .{ .plans = capture.plans(), .effects = capture.effects() };
    try std.testing.expectError(error.PaneMouseEffectFailed, handler.execute(testingCommand(.scroll_up)));
    try std.testing.expectEqual(@as(usize, 1), capture.effect_count);
}
