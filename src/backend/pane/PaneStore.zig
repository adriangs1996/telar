const revisions = @import("../revisions.zig");
const core = @import("telar-core");
const Pane = @import("Pane.zig");
const GraphicsLimits = @import("../media/GraphicsLimits.zig");
const GraphicsBudget = @import("../media/GraphicsBudget.zig");
const std = @import("std");
const PaneKey = @import("PaneKey.zig");
const pty = @import("pty");
const exit_module = pty.exit;
const PaneExitTransition = @import("PaneExitTransition.zig");
const ExitedPanes = @import("ExitedPanes.zig");
const PaneStore = @This();

/// Panes the whole runtime holds. It equals the wire's per-tab bound, so a
/// tab can hold every pane; it bounds all tabs and workspaces together.
pub const capacity = core.max_panes_per_tab;

items: [capacity]?*Pane = [_]?*Pane{null} ** capacity,
shell_markers: [capacity]bool = @splat(false),
count: usize = 0,
/// Panes whose child has exited but which have not been collected yet.
/// `collectFinished` runs on every event; this makes the common case -
/// nothing exited - one branch instead of a store scan.
exited_count: usize = 0,
/// Final text of the panes that exited last, readable after they are gone.
exited: ExitedPanes = .{},
index: core.GenericSlotIndex(2 * capacity) = .{},
next_id: u64 = 1,
next_generation: u64 = 1,
/// Advances when a pane joins, leaves or exits and when a flow changes pane
/// metadata other projections read (cwd). Zero stays unseen.
revision: u64 = 1,
graphics_limits: GraphicsLimits = .{},
graphics_budget: GraphicsBudget = .init(core.max_image_bytes_global),

pub fn find(self: *PaneStore, pane_id: core.PaneId) ?*Pane {
    const slot = self.index.get(core.raw(pane_id)) orelse return null;
    const pane = self.items[slot].?;
    std.debug.assert(pane.id == pane_id);
    return pane;
}

pub fn findRunning(self: *PaneStore, pane_id: core.PaneId) ?*Pane {
    const pane = self.find(pane_id) orelse return null;
    return if (pane.launch_state.discoverable()) pane else null;
}

pub fn resolve(self: *PaneStore, key: PaneKey) ?*Pane {
    const pane = self.find(key.id) orelse return null;
    if (pane.generation != key.generation) {
        return null;
    }
    return pane;
}

/// Resolves a control-API pane reference. Generation 0 addresses the
/// pane's current generation, so control clients can target panes that
/// never appeared in the agent snapshot.
///
/// ```zig
/// const pane = store.resolveControl(key) orelse return .pane_not_found;
/// ```
pub fn resolveControl(self: *PaneStore, key: PaneKey) ?*Pane {
    if (key.generation == 0) {
        return self.find(key.id);
    }

    return self.resolve(key);
}

pub fn resolveConst(self: *const PaneStore, key: PaneKey) ?*const Pane {
    const slot = self.index.get(core.raw(key.id)) orelse return null;
    const pane = self.items[slot].?;
    std.debug.assert(pane.id == key.id);
    if (pane.generation != key.generation) {
        return null;
    }
    return pane;
}

/// Read-only counterpart of `resolveControl`: generation 0 addresses the
/// pane's current generation.
///
/// ```zig
/// const pane = store.resolveControlConst(key) orelse return null;
/// ```
pub fn resolveControlConst(self: *const PaneStore, key: PaneKey) ?*const Pane {
    const slot = self.index.get(core.raw(key.id)) orelse return null;
    const pane = self.items[slot].?;
    std.debug.assert(pane.id == key.id);
    if (key.generation != 0 and pane.generation != key.generation) {
        return null;
    }
    return pane;
}

/// Commits one generation-matched child exit together with the repository
/// counter that enables later collection. Stale completions return null.
///
/// ```zig
/// const exited = store.completeExit(key, exit) orelse return;
/// ```
pub fn completeExit(self: *PaneStore, key: PaneKey, exit: exit_module.Exit) ?PaneExitTransition {
    const pane = self.resolve(key) orelse return null;
    pane.completeExitWait(exit);
    self.exited_count += 1;
    revisions.advance(&self.revision);
    return .{
        .pane = pane,
        .exit = exit,
        .launch_aborting = pane.launch_state == .aborting,
        .output_done = pane.output_done,
    };
}

pub fn firstAt(self: *PaneStore, location: core.TabLocation) ?*Pane {
    for (self.items) |slot| {
        const pane = slot orelse continue;
        if (pane.launch_state.discoverable() and
            !pane.close_requested and pane.exit == null and
            std.meta.eql(pane.location, location))
        {
            return pane;
        }
    }
    return null;
}

/// Projects discoverable panes at one tab into caller-owned fixed storage.
///
/// ```zig
/// const descriptors = store.descriptorsAt(location, &storage);
/// ```
pub fn descriptorsAt(self: *const PaneStore, location: core.TabLocation, output: *[core.max_panes_per_tab]core.PaneDescriptor) []const core.PaneDescriptor {
    var len: usize = 0;
    for (self.items) |slot| {
        const pane = slot orelse continue;
        if (!pane.launch_state.discoverable() or pane.close_requested or pane.exit != null or
            !std.meta.eql(pane.location, location))
        {
            continue;
        }
        output[len] = .{
            .pane_id = pane.id,
            .lifecycle = .running,
            .pane_generation = pane.generation,
        };
        len += 1;
    }
    return output[0..len];
}

pub fn positionAt(self: *const PaneStore, wanted: *const Pane) ?u16 {
    var position: u16 = 0;
    for (self.items) |slot| {
        const pane = slot orelse continue;
        if (!pane.launch_state.discoverable() or pane.close_requested or pane.exit != null or
            !std.meta.eql(pane.location, wanted.location))
        {
            continue;
        }
        position += 1;
        if (pane == wanted) {
            return position;
        }
    }
    return null;
}

pub fn countAt(self: *const PaneStore, location: core.TabLocation) u16 {
    var count: u16 = 0;
    for (self.items) |slot| {
        const pane = slot orelse continue;
        if (pane.launch_state.discoverable() and
            !pane.close_requested and pane.exit == null and
            std.meta.eql(pane.location, location))
        {
            count += 1;
        }
    }
    return count;
}

/// Unlike `firstAt`/`countAt`, deliberately counts closing and exited
/// panes too: `collectFinished` uses it to decide whether a tab is truly
/// empty, and a pane that is merely not yet reaped still holds its tab.
///
/// ```zig
/// if (!store.hasAt(location)) {
///     removeTab(location);
/// }
/// ```
pub fn hasAt(self: *const PaneStore, location: core.TabLocation) bool {
    for (self.items) |slot| {
        const pane = slot orelse continue;
        if (std.meta.eql(pane.location, location)) {
            return true;
        }
    }
    return false;
}

pub fn closeAt(self: *PaneStore, location: core.TabLocation) void {
    for (self.items) |slot| {
        const pane = slot orelse continue;
        if (!std.meta.eql(pane.location, location)) {
            continue;
        }

        _ = pane.requestClose();
    }
}

/// Prepares the next allocation for a restored pane so it keeps the
/// identity a checkpoint recorded. Valid only while no live pane has an
/// id at or above `pane_id`.
///
/// ```zig
/// try store.reserveRestoredKey(pane_id, generation);
/// ```
pub fn reserveRestoredKey(self: *PaneStore, pane_id: u64, generation: u64) !void {
    if (pane_id == 0 or generation == 0 or pane_id < self.next_id) {
        return error.InvalidCheckpointIdentity;
    }
    self.next_id = pane_id;
    self.next_generation = @max(self.next_generation, generation);
}

/// Advances the id counters past everything a checkpoint recorded.
///
/// ```zig
/// store.advanceCounters(next_pane_id, next_generation);
/// ```
pub fn advanceCounters(self: *PaneStore, next_pane_id: u64, next_generation: u64) void {
    self.next_id = @max(self.next_id, next_pane_id);
    self.next_generation = @max(self.next_generation, next_generation);
}

pub fn allocateKey(self: *PaneStore) !PaneKey {
    if (self.count == capacity) {
        return error.PaneLimitReached;
    }
    const pane_id = try core.pane(self.next_id);
    if (self.next_generation == 0 or self.next_generation == std.math.maxInt(u64)) {
        return error.PaneGenerationExhausted;
    }
    const generation = self.next_generation;
    self.next_id += 1;
    self.next_generation += 1;
    return .{ .id = pane_id, .generation = generation };
}

pub fn insert(self: *PaneStore, pane: *Pane) !void {
    for (&self.items, 0..) |*slot, position| {
        if (slot.* == null) {
            slot.* = pane;
            self.shell_markers[position] = false;
            self.index.put(core.raw(pane.id), position);
            self.count += 1;
            revisions.advance(&self.revision);
            return;
        }
    }
    return error.PaneLimitReached;
}

pub fn removeAndDestroy(self: *PaneStore, pane: *Pane) void {
    for (&self.items) |*slot| {
        if (slot.* == pane) {
            self.index.remove(core.raw(pane.id));
            if (pane.exit != null) {
                self.exited_count -= 1;
            }
            slot.* = null;
            self.count -= 1;
            revisions.advance(&self.revision);
            pane.destroy();
            return;
        }
    }
    unreachable;
}

/// Removes a collected exited pane from the table and returns it for
/// destruction by the caller.
///
/// ```zig
/// const pane = store.removeExitedAt(slot);
/// pane.destroy();
/// ```
pub fn removeExitedAt(self: *PaneStore, slot: usize) *Pane {
    const pane = self.items[slot].?;
    std.debug.assert(pane.exit != null);
    self.index.remove(core.raw(pane.id));
    self.exited_count -= 1;
    self.items[slot] = null;
    self.count -= 1;
    revisions.advance(&self.revision);
    return pane;
}

pub fn shutdown(self: *PaneStore) void {
    for (self.items) |slot| if (slot) |pane| pane.session.shutdown();
}

pub fn deinit(self: *PaneStore) void {
    for (&self.items) |*slot| {
        if (slot.*) |pane| {
            pane.destroy();
        }
        slot.* = null;
    }
    self.index.reset();
    self.exited_count = 0;
    self.count = 0;
}
