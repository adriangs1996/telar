const PaneStore = @This();
const source_namespace = @import("root.zig");
const Pane = @import("Pane.zig");
const core = @import("telar-core");
const std = @import("std");
const PaneKey = @import("PaneKey.zig");
const pty = @import("../pty/root.zig");
const PaneExitTransition = @import("PaneExitTransition.zig");
items: [source_namespace.max_panes]?*Pane = [_]?*Pane{null} ** source_namespace.max_panes,
count: usize = 0,
/// Panes whose child has exited but which have not been collected yet.
/// `collectFinished` runs on every event; this makes the common case -
/// nothing exited - one branch instead of a store scan.
exited_count: usize = 0,
index: source_namespace.SlotIndex(2 * source_namespace.max_panes) = .{},
next_id: u64 = 1,
next_generation: u64 = 1,
graphics_limits: source_namespace.GraphicsLimits = .{},
graphics_budget: source_namespace.GraphicsBudget = .init(core.graphics.max_image_bytes_global),

pub fn find(store: *PaneStore, pane_id: source_namespace.schema.PaneId) ?*Pane {
    const slot = store.index.get(source_namespace.schema.id.raw(pane_id)) orelse return null;
    const pane = store.items[slot].?;
    std.debug.assert(pane.id == pane_id);
    return pane;
}

pub fn findRunning(store: *PaneStore, pane_id: source_namespace.schema.PaneId) ?*Pane {
    const pane = store.find(pane_id) orelse return null;
    return if (pane.launch_state.discoverable()) pane else null;
}

pub fn resolve(store: *PaneStore, key: PaneKey) ?*Pane {
    const pane = store.find(key.id) orelse return null;
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
pub fn resolveControl(store: *PaneStore, key: PaneKey) ?*Pane {
    if (key.generation == 0) {
        return store.find(key.id);
    }

    return store.resolve(key);
}

pub fn resolveConst(store: *const PaneStore, key: PaneKey) ?*const Pane {
    const slot = store.index.get(source_namespace.schema.id.raw(key.id)) orelse return null;
    const pane = store.items[slot].?;
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
pub fn resolveControlConst(store: *const PaneStore, key: PaneKey) ?*const Pane {
    const slot = store.index.get(source_namespace.schema.id.raw(key.id)) orelse return null;
    const pane = store.items[slot].?;
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
pub fn completeExit(store: *PaneStore, key: PaneKey, exit: pty.Exit) ?PaneExitTransition {
    const pane = store.resolve(key) orelse return null;
    pane.completeExitWait(exit);
    store.exited_count += 1;
    return .{
        .pane = pane,
        .exit = exit,
        .launch_aborting = pane.launch_state == .aborting,
        .output_done = pane.output_done,
    };
}

pub fn firstAt(store: *PaneStore, location: source_namespace.schema.TabLocation) ?*Pane {
    for (store.items) |slot| {
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
pub fn descriptorsAt(store: *const PaneStore, location: source_namespace.schema.TabLocation, output: *[source_namespace.max_panes]source_namespace.schema.PaneDescriptor) []const source_namespace.schema.PaneDescriptor {
    var len: usize = 0;
    for (store.items) |slot| {
        const pane = slot orelse continue;
        if (!pane.launch_state.discoverable() or pane.close_requested or pane.exit != null or
            !std.meta.eql(pane.location, location))
        {
            continue;
        }
        output[len] = .{
            .pane_id = pane.id,
            .lifecycle = .running,
        };
        len += 1;
    }
    return output[0..len];
}

pub fn positionAt(store: *const PaneStore, wanted: *const Pane) ?u16 {
    var position: u16 = 0;
    for (store.items) |slot| {
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

pub fn countAt(store: *const PaneStore, location: source_namespace.schema.TabLocation) u16 {
    var count: u16 = 0;
    for (store.items) |slot| {
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
pub fn hasAt(store: *const PaneStore, location: source_namespace.schema.TabLocation) bool {
    for (store.items) |slot| {
        const pane = slot orelse continue;
        if (std.meta.eql(pane.location, location)) {
            return true;
        }
    }
    return false;
}

pub fn closeAt(store: *PaneStore, location: source_namespace.schema.TabLocation) void {
    for (store.items) |slot| {
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
pub fn reserveRestoredKey(store: *PaneStore, pane_id: u64, generation: u64) !void {
    if (pane_id == 0 or generation == 0 or pane_id < store.next_id) {
        return error.InvalidCheckpointIdentity;
    }
    store.next_id = pane_id;
    store.next_generation = @max(store.next_generation, generation);
}

/// Advances the id counters past everything a checkpoint recorded.
///
/// ```zig
/// store.advanceCounters(next_pane_id, next_generation);
/// ```
pub fn advanceCounters(store: *PaneStore, next_pane_id: u64, next_generation: u64) void {
    store.next_id = @max(store.next_id, next_pane_id);
    store.next_generation = @max(store.next_generation, next_generation);
}

pub fn allocateKey(store: *PaneStore) !PaneKey {
    if (store.count == source_namespace.max_panes) {
        return error.PaneLimitReached;
    }
    const pane_id = try source_namespace.schema.id.pane(store.next_id);
    if (store.next_generation == 0 or store.next_generation == std.math.maxInt(u64)) {
        return error.PaneGenerationExhausted;
    }
    const generation = store.next_generation;
    store.next_id += 1;
    store.next_generation += 1;
    return .{ .id = pane_id, .generation = generation };
}

pub fn insert(store: *PaneStore, pane: *Pane) !void {
    for (&store.items, 0..) |*slot, position| {
        if (slot.* == null) {
            slot.* = pane;
            store.index.put(source_namespace.schema.id.raw(pane.id), position);
            store.count += 1;
            return;
        }
    }
    return error.PaneLimitReached;
}

pub fn removeAndDestroy(store: *PaneStore, pane: *Pane) void {
    for (&store.items) |*slot| {
        if (slot.* == pane) {
            store.index.remove(source_namespace.schema.id.raw(pane.id));
            if (pane.exit != null) {
                store.exited_count -= 1;
            }
            slot.* = null;
            store.count -= 1;
            pane.destroy();
            return;
        }
    }
    unreachable;
}

pub fn shutdown(store: *PaneStore) void {
    for (store.items) |slot| if (slot) |pane| pane.session.shutdown();
}

pub fn deinit(store: *PaneStore) void {
    for (&store.items) |*slot| {
        if (slot.*) |pane| {
            pane.destroy();
        }
        slot.* = null;
    }
    store.index.reset();
    store.exited_count = 0;
    store.count = 0;
}
