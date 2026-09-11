//! Shared pointer and focused-scroll policy after pane resolution.

const std = @import("std");
const core = @import("telar-core");
const input_capability = @import("../../input/root.zig");
const Mouse = @import("../../input/root.zig").Mouse;
const workspace_capability = @import("../../workspace/root.zig");

pub const mouse_protocol = input_capability.mouse_protocol;
pub const multiplexer = workspace_capability.multiplexer;
pub const schema = core.schema;

pub const PointerCommand = @import("PointerCommand.zig");

pub const Command = union(enum) {
    pointer: PointerCommand,
    focused_scroll: input_capability.action.ScrollDirection,
};

pub const ScrollEffect = @import("ScrollEffect.zig");

pub const ReportEffect = @import("ReportEffect.zig");

pub const Effect = union(enum) {
    viewport: ScrollEffect,
    alternate_scroll: ScrollEffect,
    report: ReportEffect,
    selection: ReportEffect,
};

pub const Outcome = enum {
    ignored,
    viewport_selected,
    alternate_scroll_selected,
    report_selected,
    selection_started,
};

pub const Resolved = @import("Resolved.zig");

pub const Plans = @import("Plans.zig");

pub const Effects = @import("PaneMouseEffects.zig");

pub const PaneMouseHandler = @import("PaneMouseHandler.zig");

const Capture = @import("PaneMouseCapture.zig");

fn testingPlan() multiplexer.PaneMousePlan {
    return .{
        .pane_id = @enumFromInt(3),
        .content = .{ .x = 10, .y = 4, .w = 20, .h = 8 },
        .protocol = .{},
        .alternate_scroll = false,
        .at_bottom = true,
    };
}

fn testingPointer(kind: Mouse.Kind) PointerCommand {
    return .{
        .event = .{
            .x = 12,
            .y = 6,
            .kind = kind,
            .button = switch (kind) {
                .scroll_up => 64,
                .scroll_down => 65,
                else => 0,
            },
        },
        .exterior_pixels = false,
        .cell_width_px = 0,
        .cell_height_px = 0,
    };
}

fn testingCommand(kind: Mouse.Kind) Command {
    return .{ .pointer = testingPointer(kind) };
}

fn testingResolved(kind: Mouse.Kind) Resolved {
    return .{ .plan = testingPlan(), .pointer = testingPointer(kind) };
}

test "PaneMouseHandler selects viewport or alternate scroll for untracked wheels" {
    const Case = struct {
        alternate_scroll: bool,
        at_bottom: bool,
        outcome: Outcome,
    };
    const cases = [_]Case{
        .{ .alternate_scroll = false, .at_bottom = true, .outcome = .viewport_selected },
        .{ .alternate_scroll = false, .at_bottom = false, .outcome = .viewport_selected },
        .{ .alternate_scroll = true, .at_bottom = true, .outcome = .alternate_scroll_selected },
        .{ .alternate_scroll = true, .at_bottom = false, .outcome = .viewport_selected },
    };

    for (cases) |case| {
        for ([_]Mouse.Kind{ .scroll_up, .scroll_down }) |kind| {
            var resolved = testingResolved(kind);
            resolved.plan.alternate_scroll = case.alternate_scroll;
            resolved.plan.at_bottom = case.at_bottom;
            var capture: Capture = .{ .resolved = resolved };
            var handler: PaneMouseHandler = .{ .plans = capture.plans(), .effects = capture.effects() };
            const command = testingCommand(kind);
            const scroll: ScrollEffect = .{
                .pane_id = resolved.plan.pane_id,
                .delta = if (kind == .scroll_up) -3 else 3,
            };
            const expected: Effect = if (case.outcome == .viewport_selected)
                .{ .viewport = scroll }
            else
                .{ .alternate_scroll = scroll };

            try std.testing.expectEqual(case.outcome, try handler.execute(command));
            try std.testing.expectEqualDeep(command, capture.received.?);
            try std.testing.expectEqualDeep(expected, capture.effect.?);
            try std.testing.expectEqual(@as(usize, 1), capture.effect_count);
        }
    }
}

test "PaneMouseHandler reports only child-tracked events" {
    const Case = struct {
        tracking: schema.frame.MouseTracking,
        sgr: bool = true,
        kind: Mouse.Kind,
        outcome: Outcome,
    };
    const cases = [_]Case{
        .{ .tracking = .x10, .kind = .press, .outcome = .report_selected },
        .{ .tracking = .x10, .kind = .release, .outcome = .ignored },
        .{ .tracking = .normal, .kind = .release, .outcome = .report_selected },
        .{ .tracking = .normal, .kind = .scroll_up, .outcome = .report_selected },
        .{ .tracking = .normal, .kind = .scroll_down, .outcome = .report_selected },
        .{ .tracking = .normal, .kind = .move, .outcome = .ignored },
        .{ .tracking = .none, .kind = .press, .outcome = .selection_started },
        .{ .tracking = .normal, .sgr = false, .kind = .press, .outcome = .ignored },
        .{ .tracking = .normal, .sgr = false, .kind = .scroll_up, .outcome = .viewport_selected },
    };

    for (cases) |case| {
        var resolved = testingResolved(case.kind);
        resolved.plan.protocol = .{ .tracking = case.tracking, .sgr = case.sgr, .pixels = true };
        var capture: Capture = .{ .resolved = resolved };
        var handler: PaneMouseHandler = .{ .plans = capture.plans(), .effects = capture.effects() };
        const command = testingCommand(case.kind);

        try std.testing.expectEqual(case.outcome, try handler.execute(command));
        try std.testing.expectEqualDeep(command, capture.received.?);

        if (case.outcome == .ignored) {
            try std.testing.expect(capture.effect == null);
            try std.testing.expectEqual(@as(usize, 0), capture.effect_count);
        } else {
            const expected: Effect = if (case.outcome == .report_selected)
                .{ .report = .{ .plan = resolved.plan, .command = resolved.pointer } }
            else if (case.outcome == .selection_started)
                .{ .selection = .{ .plan = resolved.plan, .command = resolved.pointer } }
            else
                .{ .viewport = .{ .pane_id = resolved.plan.pane_id, .delta = -3 } };

            try std.testing.expectEqualDeep(expected, capture.effect.?);
            try std.testing.expectEqual(@as(usize, 1), capture.effect_count);
        }
    }
}

test "PaneMouseHandler preserves the resolved report instead of the original pointer" {
    var resolved = testingResolved(.press);
    resolved.plan.protocol = .{ .tracking = .normal, .sgr = true, .pixels = true };
    resolved.pointer = .{
        .event = .{ .x = 14, .y = 7, .raw_x = 147, .raw_y = 151, .kind = .press, .button = 16 },
        .exterior_pixels = true,
        .cell_width_px = 10,
        .cell_height_px = 20,
    };
    var capture: Capture = .{ .resolved = resolved };
    var handler: PaneMouseHandler = .{ .plans = capture.plans(), .effects = capture.effects() };
    const command = testingCommand(.press);

    try std.testing.expectEqual(Outcome.report_selected, try handler.execute(command));
    try std.testing.expectEqualDeep(command, capture.received.?);
    try std.testing.expectEqualDeep(Effect{ .report = .{
        .plan = resolved.plan,
        .command = resolved.pointer,
    } }, capture.effect.?);
    try std.testing.expectEqual(@as(usize, 1), capture.effect_count);
}

test "PaneMouseHandler applies the shared wheel policy to focused scroll in both directions" {
    const Case = struct {
        alternate_scroll: bool,
        at_bottom: bool,
        tracked: bool = false,
        outcome: Outcome,
    };
    const cases = [_]Case{
        .{ .alternate_scroll = false, .at_bottom = true, .outcome = .viewport_selected },
        .{ .alternate_scroll = true, .at_bottom = true, .outcome = .alternate_scroll_selected },
        .{ .alternate_scroll = true, .at_bottom = false, .outcome = .viewport_selected },
        .{ .alternate_scroll = true, .at_bottom = true, .tracked = true, .outcome = .report_selected },
        .{ .alternate_scroll = true, .at_bottom = false, .tracked = true, .outcome = .report_selected },
    };

    for (cases) |case| {
        for ([_]input_capability.action.ScrollDirection{ .up, .down }) |direction| {
            var resolved = testingResolved(if (direction == .up) .scroll_up else .scroll_down);
            resolved.plan.alternate_scroll = case.alternate_scroll;
            resolved.plan.at_bottom = case.at_bottom;
            resolved.plan.protocol = .{ .tracking = if (case.tracked) .normal else .none, .sgr = true };
            var capture: Capture = .{ .resolved = resolved };
            var handler: PaneMouseHandler = .{ .plans = capture.plans(), .effects = capture.effects() };
            const command: Command = .{ .focused_scroll = direction };
            const scroll: ScrollEffect = .{
                .pane_id = resolved.plan.pane_id,
                .delta = if (direction == .up) -3 else 3,
            };
            const expected: Effect = if (case.tracked)
                .{ .report = .{ .plan = resolved.plan, .command = resolved.pointer } }
            else if (case.alternate_scroll and case.at_bottom)
                .{ .alternate_scroll = scroll }
            else
                .{ .viewport = scroll };

            try std.testing.expectEqual(case.outcome, try handler.execute(command));
            try std.testing.expectEqualDeep(command, capture.received.?);
            try std.testing.expectEqualDeep(expected, capture.effect.?);
            try std.testing.expectEqual(@as(usize, 1), capture.effect_count);
        }
    }
}

test "PaneMouseHandler ignores unresolved pointer and focused scroll commands" {
    const commands = [_]Command{ testingCommand(.press), .{ .focused_scroll = .up }, .{ .focused_scroll = .down } };

    for (commands) |command| {
        var capture: Capture = .{};
        var handler: PaneMouseHandler = .{ .plans = capture.plans(), .effects = capture.effects() };

        try std.testing.expectEqual(Outcome.ignored, try handler.execute(command));
        try std.testing.expectEqualDeep(command, capture.received.?);
        try std.testing.expect(capture.effect == null);
        try std.testing.expectEqual(@as(usize, 0), capture.effect_count);
    }
}

test "PaneMouseHandler propagates each selected effect failure without fallback" {
    const commands = [_]Command{ testingCommand(.scroll_up), .{ .focused_scroll = .up } };

    for (commands) |command| {
        for ([_]std.meta.Tag(Effect){ .viewport, .alternate_scroll, .report }) |effect_tag| {
            var resolved = testingResolved(.scroll_up);
            resolved.plan.alternate_scroll = effect_tag != .viewport;
            resolved.plan.protocol = .{ .tracking = if (effect_tag == .report) .normal else .none, .sgr = true };
            var capture: Capture = .{ .resolved = resolved, .fail = true };
            var handler: PaneMouseHandler = .{ .plans = capture.plans(), .effects = capture.effects() };

            try std.testing.expectError(error.PaneMouseEffectFailed, handler.execute(command));
            try std.testing.expectEqualDeep(command, capture.received.?);
            try std.testing.expectEqual(effect_tag, std.meta.activeTag(capture.effect.?));
            try std.testing.expectEqual(@as(usize, 1), capture.effect_count);
        }
    }
}
