//! Every pane this client knows, across all tabs of its workspace. A pane's
//! tab is `record.location.tab_id`; tabs never hold their panes.
const core = @import("telar-core");
const std = @import("std");
const Pane = @import("Pane.zig");
const Spec = @import("Spec.zig");
const Panes = @This();

/// A workspace may hold every pane the runtime keeps alive, so one client
/// never mirrors more.
pub const capacity = core.max_panes;

/// Records live on the heap so their addresses survive tab moves. Removing a
/// pane invalidates every borrow of its record.
record: [capacity]?*Pane = @splat(null),
index: core.GenericSlotIndex(2 * capacity) = .{},
count: usize = 0,

/// Releases every record.
/// Example: `model.panes.deinit();`
pub fn deinit(self: *Panes) void {
    for (&self.record) |*slot| {
        if (slot.*) |pane| {
            destroy(pane);
        }

        slot.* = null;
    }

    self.index.reset();
    self.count = 0;
}

/// Allocates and publishes one pane. Failure leaves the table unchanged.
/// Example: `const pane = try model.panes.add(gpa, spec, true);`
pub fn add(self: *Panes, gpa: std.mem.Allocator, spec: Spec, attached: bool) !*Pane {
    if (self.find(spec.pane_id) != null) {
        return error.DuplicatePane;
    }

    if (self.count == capacity) {
        return error.PaneLimitReached;
    }

    const pane = try create(gpa, spec, attached);
    self.insert(pane);
    return pane;
}

/// Allocates one pane record without publishing it, so a caller can build
/// a replacement before retiring the panes it replaces.
/// Example: `const pane = try Panes.create(gpa, spec, true);`
pub fn create(gpa: std.mem.Allocator, spec: Spec, attached: bool) !*Pane {
    if (spec.pane_id == .invalid) {
        return error.InvalidPaneId;
    }

    const pane = try gpa.create(Pane);
    errdefer gpa.destroy(pane);
    pane.* = try Pane.init(gpa, .{
        .spec = spec,
        .attached = attached,
    });
    return pane;
}

/// Publishes a record from `create`. The table takes ownership.
/// Example: `model.panes.insert(pane);`
pub fn insert(self: *Panes, pane: *Pane) void {
    std.debug.assert(self.count < capacity);
    std.debug.assert(self.find(pane.id) == null);

    const slot = std.mem.findScalar(?*Pane, &self.record, null).?;
    self.record[slot] = pane;
    self.index.put(core.raw(pane.id), @intCast(slot));
    self.count += 1;
}

/// Frees a record from `create` that was never published.
/// Example: `errdefer Panes.destroy(pane);`
pub fn destroy(pane: *Pane) void {
    const gpa = pane.gpa;
    pane.deinit();
    gpa.destroy(pane);
}

/// Frees one pane and reports whether it existed.
/// Example: `_ = model.panes.remove(pane_id);`
pub fn remove(self: *Panes, pane_id: core.PaneId) bool {
    if (pane_id == .invalid) {
        return false;
    }

    const slot = self.index.get(core.raw(pane_id)) orelse return false;
    destroy(self.record[slot].?);
    self.record[slot] = null;
    self.index.remove(core.raw(pane_id));
    self.count -= 1;
    return true;
}

/// Frees every pane of one tab.
/// Example: `model.panes.removeTab(tab_id);`
pub fn removeTab(self: *Panes, tab_id: core.TabId) void {
    for (self.record) |slot| {
        const pane = slot orelse continue;
        if (pane.location.tab_id == tab_id) {
            _ = self.remove(pane.id);
        }
    }
}

/// Example: `const pane = model.panes.find(pane_id) orelse return;`
pub fn find(self: *Panes, pane_id: core.PaneId) ?*Pane {
    core.profiling.add(.pane_find, 1);
    if (pane_id == .invalid) {
        return null;
    }

    const slot = self.index.get(core.raw(pane_id)) orelse return null;
    core.profiling.add(.pane_find_found, 1);
    return self.record[slot].?;
}

/// Example: `const pane = model.panes.findConst(pane_id) orelse return;`
pub fn findConst(self: *const Panes, pane_id: core.PaneId) ?*const Pane {
    core.profiling.add(.pane_find, 1);
    if (pane_id == .invalid) {
        return null;
    }

    const slot = self.index.get(core.raw(pane_id)) orelse return null;
    core.profiling.add(.pane_find_found, 1);
    return self.record[slot].?;
}

/// Finds a pane only when it belongs to `tab_id`.
/// Example: `const pane = model.panes.findIn(tab_id, pane_id) orelse return;`
pub fn findIn(self: *Panes, tab_id: core.TabId, pane_id: core.PaneId) ?*Pane {
    const pane = self.find(pane_id) orelse return null;
    return if (pane.location.tab_id == tab_id) pane else null;
}

/// Example: `const pane = model.panes.findInConst(tab_id, pane_id) orelse return;`
pub fn findInConst(self: *const Panes, tab_id: core.TabId, pane_id: core.PaneId) ?*const Pane {
    const pane = self.findConst(pane_id) orelse return null;
    return if (pane.location.tab_id == tab_id) pane else null;
}

/// Example: `if (model.panes.countIn(tab_id) == 0) return;`
pub fn countIn(self: *const Panes, tab_id: core.TabId) usize {
    var count: usize = 0;
    for (self.record) |slot| {
        const pane = slot orelse continue;
        if (pane.location.tab_id == tab_id) {
            count += 1;
        }
    }

    return count;
}

/// Iterates one tab's panes, or every pane when `tab_id` is null, in slot
/// order.
/// Example: `var panes = model.panes.iterate(tab_id); while (panes.next()) |pane| {}`
pub fn iterate(self: *Panes, tab_id: ?core.TabId) Iterator(*Pane) {
    return .{
        .records = &self.record,
        .tab_id = tab_id,
    };
}

/// Example: `var panes = model.panes.iterateConst(tab_id);`
pub fn iterateConst(self: *const Panes, tab_id: ?core.TabId) Iterator(*const Pane) {
    return .{
        .records = &self.record,
        .tab_id = tab_id,
    };
}

fn Iterator(comptime Pointer: type) type {
    return struct {
        records: *const [capacity]?*Pane,
        tab_id: ?core.TabId,
        slot: usize = 0,

        pub fn next(self: *@This()) ?Pointer {
            core.profiling.add(.pane_iterator, 1);
            while (self.slot < capacity) {
                const record = self.records[self.slot];
                self.slot += 1;
                const pane = record orelse continue;
                if (self.tab_id) |tab_id| {
                    if (pane.location.tab_id != tab_id) {
                        continue;
                    }
                }

                return pane;
            }

            return null;
        }
    };
}

test "adding a pane rolls back every allocation failure without touching existing panes" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAdd, .{});
}

fn exerciseAdd(gpa: std.mem.Allocator) !void {
    var panes: Panes = .{};
    defer panes.deinit();
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const size: core.TerminalSize = .{ .cols = 1, .rows = 1 };
    const first = try panes.add(gpa, .{ .pane_id = @enumFromInt(1), .location = location, .size = size }, true);
    _ = try first.setTitle("keep title");

    _ = panes.add(gpa, .{ .pane_id = @enumFromInt(2), .location = location, .size = size }, false) catch |err| {
        try std.testing.expectEqual(@as(usize, 1), panes.count);
        try std.testing.expect(panes.find(@enumFromInt(2)) == null);
        try std.testing.expectEqual(first, panes.find(@enumFromInt(1)).?);
        try std.testing.expectEqualStrings("keep title", first.titleSlice());
        return err;
    };

    try std.testing.expect(panes.remove(@enumFromInt(2)));
    try std.testing.expect(!panes.remove(@enumFromInt(2)));
    try std.testing.expect(!panes.remove(.invalid));
    try std.testing.expectEqualStrings("keep title", first.titleSlice());
}

test "pane slots bound membership and reuse holes without moving live records" {
    var accounting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = accounting.allocator();
    var panes: Panes = .{};
    defer panes.deinit();
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const size: core.TerminalSize = .{ .cols = 1, .rows = 1 };
    for (0..capacity) |index| {
        _ = try panes.add(gpa, .{ .pane_id = @enumFromInt(index + 1), .location = location, .size = size }, true);
    }

    const kept = panes.find(@enumFromInt(capacity)).?;
    const attempts = accounting.alloc_index;
    try std.testing.expectError(error.PaneLimitReached, panes.add(gpa, .{ .pane_id = @enumFromInt(capacity + 1), .location = location, .size = size }, true));
    try std.testing.expectEqual(attempts, accounting.alloc_index);
    try std.testing.expect(panes.remove(@enumFromInt(1)));
    _ = try panes.add(gpa, .{ .pane_id = @enumFromInt(capacity + 1), .location = location, .size = size }, true);
    try std.testing.expectEqual(kept, panes.find(@enumFromInt(capacity)).?);

    accounting.fail_index = accounting.alloc_index;
    var iterator = panes.iterateConst(location.tab_id);
    var count: usize = 0;
    while (iterator.next()) |_| {
        count += 1;
    }

    try std.testing.expectEqual(capacity, count);
    try std.testing.expect(!accounting.has_induced_failure);
}
