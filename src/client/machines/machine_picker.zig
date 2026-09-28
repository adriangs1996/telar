//! The command palette's `:` mode: the window's machines filtered by the
//! query, best match first and slot order among equal scores, disabled ones
//! included, then an "Add machine" row. The palette draws these rows and the
//! submission takes the chosen one, so both read the same list. Enter shows
//! a machine or enables a disabled one, Shift+Enter enables or disables,
//! Ctrl+R renames and Ctrl+D removes; each change is written to
//! `machines.json`, which the window then follows. Enter on a machine that
//! failed for want of telar, or for another build, sets telar up there.
const core = @import("telar-core");
const std = @import("std");
const Machines = @import("Machines.zig");
const MachineResults = @import("MachineResults.zig");
const machine_profiles = @import("machine_profiles.zig");
const name_prompt = @import("../input/name_prompt.zig");
const Client = @import("../execution/Client.zig");

/// Fills `results` with every machine whose label or destination matches.
///
/// ```zig
/// var results: MachineResults = .{};
/// machine_picker.collect(machines, "box", &results);
/// ```
pub fn collect(machines: *const Machines, query: []const u8, results: *MachineResults) void {
    results.len = 0;
    for (0..Machines.capacity) |index| {
        const slot: u8 = @intCast(index);
        if (!machines.used[slot]) {
            continue;
        }

        const item_score = core.score(machines.label(slot), query) orelse core.score(machines.destination(slot), query) orelse continue;
        var at: usize = results.len;
        while (at > 0 and results.scores[at - 1] < item_score) {
            at -= 1;
        }

        var move: usize = results.len;
        while (move > at) : (move -= 1) {
            results.slots[move] = results.slots[move - 1];
            results.scores[move] = results.scores[move - 1];
        }

        results.slots[at] = slot;
        results.scores[at] = item_score;
        results.len += 1;
    }
}

/// Takes the row the person chose: shows the machine, or with `alternate`
/// enables or disables it. A disabled machine is enabled first; the "Add
/// machine" row asks for the new machine.
///
/// ```zig
/// try machine_picker.choose(client, results.slotAt(row), false);
/// ```
pub fn choose(client: *Client, chosen: ?u8, alternate: bool) !void {
    const machines = client.machines orelse return;
    const slot = chosen orelse {
        _ = name_prompt.openNamePrompt(&client.model, .add_machine);
        return;
    };

    if (slot == Machines.local_slot) {
        if (!alternate) {
            try client.model.to_host.push(.{ .machine = .{ .slot = slot } });
        }

        return;
    }

    if (!alternate and machines.needs_setup[slot]) {
        try client.model.to_host.push(.{ .machine = .{ .setup = slot } });
        return;
    }

    const enabled = machines.enabled[slot];
    if (alternate or !enabled) {
        // Disabling is the person's decision, so a machine a flag kept open
        // closes even when its profile was already disabled.
        if (enabled) {
            try client.model.to_host.push(.{ .machine = .{ .unpin = slot } });
        }

        return machine_profiles.start(client, .{
            .kind = if (enabled) .disable else .enable,
            .label = machines.label(slot),
        });
    }

    try client.model.to_host.push(.{ .machine = .{ .slot = slot } });
}

/// Removes the chosen saved machine from `machines.json`.
///
/// ```zig
/// try machine_picker.remove(client, results.slotAt(row));
/// ```
pub fn remove(client: *Client, chosen: ?u8) !void {
    const machines = client.machines orelse return;
    const slot = chosen orelse return;
    if (slot == Machines.local_slot) {
        return;
    }

    try machine_profiles.start(client, .{
        .kind = .remove,
        .label = machines.label(slot),
    });
}

/// Asks for a new label for the chosen saved machine.
///
/// ```zig
/// try machine_picker.rename(client, results.slotAt(row));
/// ```
pub fn rename(client: *Client, chosen: ?u8) void {
    const machines = client.machines orelse return;
    const slot = chosen orelse return;
    if (slot == Machines.local_slot) {
        return;
    }

    _ = name_prompt.openNamePrompt(&client.model, .{ .rename_machine = .{
        .slot = slot,
        .label = machines.label(slot),
    } });
}

test "machines match by label or destination" {
    var machines: Machines = .{};
    _ = try machines.add(.{ .label = "laptop" }, Machines.local_slot);
    _ = try machines.add(.{ .label = "box", .destination = "dev@build-box" }, null);
    _ = try machines.add(.{ .label = "gpu", .destination = "dev@gpu-rig" }, null);

    var results: MachineResults = .{};
    collect(&machines, "", &results);
    try std.testing.expectEqual(@as(u8, 3), results.len);

    collect(&machines, "build", &results);
    try std.testing.expectEqualSlices(u8, &.{1}, results.slice());

    collect(&machines, "zzz", &results);
    try std.testing.expectEqual(@as(u8, 0), results.len);
}
