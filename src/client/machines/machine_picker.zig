//! The command palette's `:` mode: the window's machines filtered by the
//! query, best match first and slot order among equal scores. The palette
//! draws these rows and the submission takes the chosen one, so both read
//! the same list.
const core = @import("telar-core");
const std = @import("std");
const Machines = @import("Machines.zig");
const MachineResults = @import("MachineResults.zig");

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
        if (!machines.shown(slot)) {
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
