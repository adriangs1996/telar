//! Degrades a bar row by priority until it fits. The rule is shared by every
//! adapter; each one measures in its own unit and draws the levels it gets.
const BarFit = @import("BarFit.zig");
const FitInput = @import("FitInput.zig");
const FitLevel = @import("FitLevel.zig").FitLevel;
const Node = @import("Node.zig");
const model = @import("model.zig");
const std = @import("std");

const Candidate = struct {
    slot: usize,
    node: usize,
};

/// Visible row children per group, kept as the fit hides them, so a group
/// knows in constant time whether it may disappear.
const ChildCounts = [FitInput.max_slots][model.max_bar_nodes]u8;

/// Reduces the lowest-priority component one step at a time, the later one
/// on ties, until the row fits or nothing is left to reduce. A meter drops
/// its track before it disappears; a group disappears only after all of its
/// children did, and then counts towards the overflow chip.
///
/// ```zig
/// const levels = bar_fitting.fit(&input);
/// if (levels.isVisible(slot, index)) try drawNode(slot, index, levels.level(slot, index));
/// ```
pub fn fit(input: *const FitInput) BarFit {
    var result: BarFit = .{};
    var children: ChildCounts = @splat(@splat(0));
    for (input.slots, 0..) |content, slot| {
        const value = content orelse continue;
        for (value.slice(), 0..) |node, index| {
            if (node.in_tooltip) {
                result.levels[slot][index] = .hidden;
            } else if (!node.isRoot()) {
                children[slot][node.parent] += 1;
            }
        }
    }

    // Every node reduces at most twice, so the loop is bounded by the
    // number of nodes the row can hold; each step is linear in them.
    const step_limit = FitInput.max_slots * model.max_bar_nodes * 2;
    for (0..step_limit) |_| {
        measure(input, &result);
        if (result.width <= input.available) {
            return result;
        }

        const candidate = lowest(input, .{ .result = &result, .children = &children }) orelse return result;
        reduce(input, .{ .result = &result, .children = &children }, candidate);
    }

    measure(input, &result);
    return result;
}

/// The width of one top-level component at the levels of `fitted`.
/// Example: `const width = bar_fitting.rootWidth(&input, &levels, slot, index);`
pub fn rootWidth(input: *const FitInput, fitted: *const BarFit, slot: usize, index: usize) f32 {
    const content = input.slots[slot] orelse return 0;
    const node = content.slice()[index];
    if (node.kind != .group) {
        return leafWidth(input, fitted, slot, index);
    }

    var width = input.full[slot][index];
    for (content.slice(), 0..) |child, child_index| {
        if (child.parent != index or child.in_tooltip or !fitted.isVisible(slot, child_index)) {
            continue;
        }

        const child_width = leafWidth(input, fitted, slot, child_index);
        if (child_width > 0) {
            width += input.child_gap + child_width;
        }
    }

    return width;
}

fn leafWidth(input: *const FitInput, fitted: *const BarFit, slot: usize, index: usize) f32 {
    return switch (fitted.level(slot, index)) {
        .full => input.full[slot][index],
        .compact => input.compact[slot][index],
        .hidden => 0,
    };
}

/// One linear pass: children are stored after their group, so each adds its
/// width to its group's before the group is summed.
fn measure(input: *const FitInput, result: *BarFit) void {
    var total: f32 = 0;
    var visible_slots: usize = 0;
    var hidden: u8 = 0;
    for (input.slots, 0..) |content, slot| {
        const value = content orelse continue;
        var widths: [model.max_bar_nodes]f32 = undefined;
        for (value.slice(), 0..) |node, index| {
            widths[index] = if (node.kind == .group) input.full[slot][index] else leafWidth(input, result, slot, index);
            if (node.isRoot() or node.in_tooltip or !result.isVisible(slot, index)) {
                continue;
            }

            if (widths[index] > 0) {
                widths[node.parent] += input.child_gap + widths[index];
            }
        }

        var slot_width: f32 = 0;
        var units: usize = 0;
        for (value.slice(), 0..) |node, index| {
            if (!node.isRoot()) {
                continue;
            }
            if (!result.isVisible(slot, index)) {
                hidden += 1;
                continue;
            }

            const width = widths[index];
            if (width <= 0) {
                continue;
            }

            if (units > 0) {
                slot_width += input.unit_gap;
            }
            slot_width += width;
            units += 1;
        }
        if (units == 0) {
            continue;
        }

        if (visible_slots > 0) {
            total += input.slot_gap;
        }
        total += slot_width;
        visible_slots += 1;
    }

    if (hidden > 0) {
        total += input.overflow_width;
    }

    result.width = total;
    result.hidden = hidden;
}

const Progress = struct {
    result: *BarFit,
    children: *ChildCounts,
};

fn lowest(input: *const FitInput, progress: Progress) ?Candidate {
    var best: ?Candidate = null;
    var best_priority: u8 = std.math.maxInt(u8);
    for (input.slots, 0..) |content, slot| {
        const value = content orelse continue;
        for (value.slice(), 0..) |node, index| {
            if (!reducible(input, progress, .{ .slot = slot, .node = index })) {
                continue;
            }

            // `<=` keeps the later component on ties.
            const priority = node.effectivePriority();
            if (priority <= best_priority) {
                best_priority = priority;
                best = .{
                    .slot = slot,
                    .node = index,
                };
            }
        }
    }

    return best;
}

fn reducible(input: *const FitInput, progress: Progress, candidate: Candidate) bool {
    const node = input.slots[candidate.slot].?.slice()[candidate.node];
    if (node.in_tooltip or !progress.result.isVisible(candidate.slot, candidate.node)) {
        return false;
    }
    if (node.kind == .group) {
        return progress.children[candidate.slot][candidate.node] == 0;
    }

    return leafWidth(input, progress.result, candidate.slot, candidate.node) > 0;
}

fn reduce(input: *const FitInput, progress: Progress, candidate: Candidate) void {
    const node = input.slots[candidate.slot].?.slice()[candidate.node];
    const level = &progress.result.levels[candidate.slot][candidate.node];
    level.* = switch (level.*) {
        .full => if (node.kind == .meter) .compact else .hidden,
        .compact, .hidden => .hidden,
    };
    if (level.* == .hidden and !node.isRoot()) {
        progress.children[candidate.slot][node.parent] -= 1;
    }
}

fn testInput(content: *const model.Content, available: f32) FitInput {
    var input: FitInput = .{
        .available = available,
        .unit_gap = 10,
        .child_gap = 2,
        .overflow_width = 20,
    };
    input.slots[0] = content;
    for (content.slice(), 0..) |node, index| {
        input.full[0][index] = switch (node.kind) {
            .group => 10,
            .meter => 40,
            else => 30,
        };
        input.compact[0][index] = if (node.kind == .meter) 20 else 0;
    }

    return input;
}

test "a row that fits keeps every component at full level" {
    var content: model.Content = .{};
    _ = try content.append(.{
        .kind = .label,
        .text = "11:52",
    });
    _ = try content.append(.{
        .kind = .label,
        .text = "80%",
    });

    const input = testInput(&content, 100);
    const fitted = fit(&input);

    try std.testing.expectEqual(@as(f32, 70), fitted.width);
    try std.testing.expectEqual(@as(u8, 0), fitted.hidden);
    try std.testing.expectEqual(FitLevel.full, fitted.level(0, 1));
}

test "fitting drops a meter track before the meter and the lowest priority first" {
    var content: model.Content = .{};
    const group = try content.append(.{
        .kind = .group,
        .mark = .claude,
        .priority = 90,
    });
    _ = try content.append(.{
        .kind = .label,
        .parent = group,
        .text = "Claude",
        .priority = 10,
    });
    _ = try content.append(.{
        .kind = .meter,
        .parent = group,
        .text = "7d",
        .value = 490,
        .priority = 90,
    });

    const narrow = testInput(&content, 60);
    const fitted = fit(&narrow);

    try std.testing.expectEqual(FitLevel.hidden, fitted.level(0, 1));
    try std.testing.expectEqual(FitLevel.full, fitted.level(0, 2));
    try std.testing.expectEqual(@as(f32, 52), fitted.width);

    const tighter = testInput(&content, 40);
    const compacted = fit(&tighter);

    try std.testing.expectEqual(FitLevel.compact, compacted.level(0, 2));
    try std.testing.expectEqual(FitLevel.full, compacted.level(0, 0));
    try std.testing.expectEqual(@as(u8, 0), compacted.hidden);
}

test "attention outranks priority and hidden roots are counted for the overflow chip" {
    var content: model.Content = .{};
    _ = try content.append(.{
        .kind = .label,
        .text = "battery",
        .priority = 70,
    });
    _ = try content.append(.{
        .kind = .label,
        .text = "cpu",
        .priority = 60,
        .tone = .warning,
    });
    _ = try content.append(.{
        .kind = .label,
        .text = "memory",
        .priority = 40,
    });

    const input = testInput(&content, 60);
    const fitted = fit(&input);

    try std.testing.expectEqual(FitLevel.hidden, fitted.level(0, 0));
    try std.testing.expectEqual(FitLevel.full, fitted.level(0, 1));
    try std.testing.expectEqual(FitLevel.hidden, fitted.level(0, 2));
    try std.testing.expectEqual(@as(u8, 2), fitted.hidden);
    try std.testing.expectEqual(@as(f32, 50), fitted.width);
}

test "tooltip components never take room in the row" {
    var content: model.Content = .{};
    const group = try content.append(.{
        .kind = .group,
        .mark = .codex,
    });
    _ = try content.append(.{
        .kind = .meter,
        .parent = group,
        .in_tooltip = true,
        .text = "7d",
    });

    const input = testInput(&content, 100);
    const fitted = fit(&input);

    try std.testing.expectEqual(FitLevel.hidden, fitted.level(0, 1));
    try std.testing.expectEqual(@as(f32, 10), fitted.width);
}
