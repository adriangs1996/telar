//! Degrades a bar row by priority until it fits. The rule is shared by every
//! adapter; each one measures in its own unit and draws the levels it gets.
const BarFit = @import("BarFit.zig");
const FitInput = @import("FitInput.zig");
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
