const types = @import("types.zig");
const TargetType = @import("AttachmentTarget.zig");
const path_marker = @import("path_marker.zig");
const std = @import("std");
const PendingDeletionType = @import("PendingDeletion.zig");
const catalog = @import("catalog.zig");
const SnapshotType = @import("AttachmentSnapshot.zig");
const ItemType = @import("Item.zig");
const CaptureType = @import("Capture.zig");
const MarkerScreenType = @import("MarkerScreen.zig");
const MarkerRemovalType = @import("MarkerRemoval.zig");
const markers = @import("markers.zig");
const DeletionProbeType = @import("DeletionProbe.zig");
const MarkerType = @import("Marker.zig");
const BufferType = @import("telar-core").Buffer;
const MarkerScanType = @import("MarkerScan.zig");

/// Creates an attachment catalog with presentation-owned slot resources.
/// Example: `var catalog = Catalog(Delivery).init(gpa);`.
pub fn Type(comptime Delivery: type) type {
    return struct {
        const Self = @This();
        pub const Slot = struct {
            delivery: Delivery.SlotState,

            id: types.Id,
            target: TargetType,
            png: []u8,
            width: u32,
            height: u32,
            marker_policy: types.MarkerPolicy,
            marker: ?types.MarkerIdentity = null,
            retire_pending: bool = false,

            pub fn markerNumber(slot: *const Slot) ?u16 {
                const marker = slot.marker orelse return null;

                return switch (marker) {
                    .number => |number| number,
                    .path => null,
                };
            }

            pub fn markerPath(slot: *const Slot) ?path_marker.Uuid {
                const marker = slot.marker orelse return null;

                return switch (marker) {
                    .number => null,
                    .path => |uuid| uuid,
                };
            }

            pub fn owns(slot: *const Slot, target: TargetType) bool {
                return !slot.retire_pending and std.meta.eql(slot.target, target);
            }
        };

        pub const TargetChange = struct {
            changed: bool = false,
            layout_changed: bool = false,
        };

        gpa: std.mem.Allocator,
        slots: [types.max_items]?Slot = @splat(null),
        active_target: ?TargetType = null,
        marker_deletion_pending: ?PendingDeletionType = null,
        modal: ?types.Id = null,
        total_bytes: usize = 0,
        ingress_version: u64 = 0,

        delivery: Delivery.State = .{},
        pub fn init(gpa: std.mem.Allocator) Self {
            return .{ .gpa = gpa };
        }

        pub fn deinit(store: *Self) void {
            for (&store.slots) |*slot| store.freeSlot(slot);
        }

        pub fn retainedBytes(store: *const Self) usize {
            return store.total_bytes;
        }

        pub fn ingressVersion(store: *const Self) u64 {
            return store.ingress_version;
        }

        pub fn cleanupPending(store: *const Self) bool {
            for (store.slots) |maybe_slot| if (maybe_slot) |slot|
                if (slot.retire_pending) return true;
            return false;
        }

        pub fn reapRetired(store: *Self) void {
            for (&store.slots) |*maybe_slot| {
                if (maybe_slot.* == null or !maybe_slot.*.?.retire_pending or !Delivery.canRelease(&maybe_slot.*.?)) {
                    continue;
                }
                store.freeSlot(maybe_slot);
            }
        }

        pub fn setTarget(store: *Self, target: ?TargetType) TargetChange {
            const previous_pane = if (store.visibleCount() != 0)
                if (store.active_target) |active| active.pane_id else null
            else
                null;
            if (catalog.optionalTargetEql(store.active_target, target)) {
                return .{};
            }
            store.active_target = target;
            store.marker_deletion_pending = null;
            store.modal = null;
            Delivery.targetChanged(store);
            const current_pane = if (store.visibleCount() != 0)
                if (target) |active| active.pane_id else null
            else
                null;

            return .{
                .changed = true,
                .layout_changed = previous_pane != current_pane,
            };
        }

        pub fn hasVisibleItems(store: *const Self) bool {
            return store.visibleCount() != 0;
        }

        pub fn visibleTarget(store: *const Self) ?TargetType {
            if (store.visibleCount() == 0) {
                return null;
            }

            return store.active_target;
        }

        pub fn hasModal(store: *const Self) bool {
            return store.modal != null;
        }

        pub fn snapshot(store: *const Self) SnapshotType {
            var result: SnapshotType = .{ .modal = store.modal };
            for (store.slots) |maybe_slot| if (maybe_slot) |slot| {
                if (!store.slotVisible(&slot)) {
                    continue;
                }
                result.items[result.len] = .{
                    .id = slot.id,
                    .width = slot.width,
                    .height = slot.height,
                };
                result.len += 1;
            };
            // Slot reuse must not reorder the shelf. Four-element insertion sort
            // is cheaper and clearer than making storage order authoritative.
            if (result.len > 1) {
                for (1..result.len) |index| {
                    var at = index;
                    while (at != 0 and @intFromEnum(result.items[at - 1].id) >
                        @intFromEnum(result.items[at].id)) : (at -= 1)
                    {
                        std.mem.swap(ItemType, &result.items[at - 1], &result.items[at]);
                    }
                }
            }
            if (result.modal) |id| {
                var found = false;
                for (result.slice()) |item| found = found or item.id == id;
                if (!found) {
                    result.modal = null;
                }
            }
            return result;
        }

        pub fn adopt(store: *Self, capture: *CaptureType) !void {
            if (capture.png.len == 0 or capture.png.len > types.max_png_bytes or
                capture.width == 0 or capture.height == 0)
            {
                return error.InvalidClipboardImage;
            }
            const pixels = std.math.mul(u64, capture.width, capture.height) catch
                return error.ClipboardImageTooLarge;
            if (pixels > types.max_pixels) {
                return error.ClipboardImageTooLarge;
            }
            while (store.total_bytes + capture.png.len > types.max_retained_bytes or
                store.freeIndex() == null)
            {
                store.evictOldest() orelse return error.AttachmentSelfFull;
            }
            const delivery = try Delivery.createSlot(store);
            const index = store.freeIndex().?;
            const request = capture.request;
            const width = capture.width;
            const height = capture.height;
            const png = capture.png;
            capture.png = &.{};
            store.gpa.destroy(capture);
            store.slots[index] = .{
                .id = @enumFromInt(request.sequence),
                .target = request.target,
                .png = png,
                .width = width,
                .height = height,
                .delivery = delivery,
                .marker_policy = request.marker_policy,
            };
            store.total_bytes += png.len;
            store.ingress_version +%= 1;
        }

        pub fn remove(store: *Self, id: types.Id) bool {
            for (&store.slots, 0..) |*slot, index| {
                if (slot.* == null or slot.*.?.id != id or slot.*.?.retire_pending) {
                    continue;
                }
                store.retireAt(index);
                if (store.modal == id) {
                    store.modal = null;
                }
                return true;
            }
            return false;
        }

        pub fn removeVisible(store: *Self, target: TargetType) u8 {
            var removed: u8 = 0;
            for (&store.slots, 0..) |*slot, index| {
                if (slot.* == null or slot.*.?.retire_pending or !std.meta.eql(slot.*.?.target, target)) {
                    continue;
                }

                store.retireAt(index);
                removed += 1;
            }
            if (removed != 0) {
                store.modal = null;
            }
            if (store.pendingDeletionFor(target)) {
                store.marker_deletion_pending = null;
            }

            return removed;
        }

        pub fn planMarkerRemoval(store: *const Self, id: types.Id, screen: MarkerScreenType) ?MarkerRemovalType {
            const visible = store.snapshot();
            const ordinal = snapshotOrdinal(&visible, id) orelse return null;
            const slot = store.findConst(id) orelse return null;
            const removal = switch (slot.marker_policy) {
                .ordered, .stable_number => markers.planPlaceholderRemoval(slot.markerNumber(), ordinal, screen),
                .pasted_path => markers.planPathRemoval(slot.markerPath(), screen),
            } orelse return null;
            if (removal.keyCount() > types.max_removal_keys) {
                return null;
            }

            return removal;
        }

        pub fn idAtMarkerDeletion(store: *const Self, screen: MarkerScreenType, deletion: types.MarkerDeletion) ?types.Id {
            const visible = store.snapshot();
            for (visible.slice(), 0..) |item, index| {
                const slot = store.findConst(item.id) orelse continue;
                const touches = switch (slot.marker_policy) {
                    .ordered, .stable_number => screen.cursor.visible and markers.markerTouchesCursor(screen.buffer, .{
                        .ordinal = slot.markerNumber() orelse @as(u16, @intCast(index + 1)),
                        .cursor = screen.cursor,
                        .deletion = deletion,
                    }),
                    .pasted_path => markers.pathTouchesCursor(slot.markerPath() orelse continue, screen, deletion),
                };
                if (touches) {
                    return item.id;
                }
            }

            return null;
        }

        pub fn pendingMarkerAtDeletion(store: *const Self, screen: MarkerScreenType, probe: DeletionProbeType) bool {
            const visible = store.snapshot();
            if (visible.len >= types.max_items) {
                return false;
            }

            switch (probe.policy) {
                .ordered, .stable_number => {
                    if (!screen.cursor.visible) {
                        return false;
                    }

                    return markers.markerTouchesCursor(screen.buffer, .{
                        .ordinal = @as(u16, visible.len) + 1,
                        .cursor = screen.cursor,
                        .deletion = probe.deletion,
                    });
                },
                .pasted_path => {
                    const target = store.active_target orelse return false;
                    var found: [types.max_items * 2]MarkerType = undefined;
                    const count = path_marker.collect(screen.buffer, &found);
                    for (found[0..count]) |marker| {
                        if (store.pathClaimed(target, marker.uuid)) {
                            continue;
                        }
                        if (markers.markerCursorTouches(marker, screen, probe.deletion)) {
                            return true;
                        }
                    }

                    return false;
                },
            }
        }

        pub fn expectMarkerDeletion(store: *Self, target: TargetType) void {
            for (store.slots) |maybe_slot| {
                const slot = maybe_slot orelse continue;
                if (slot.owns(target) and slot.marker_policy.learnsIdentity()) {
                    store.marker_deletion_pending = .{ .target = target, .frames = types.deletion_watch_frames };
                    return;
                }
            }
        }

        pub fn reconcileMarkers(store: *Self, target: TargetType, screen: MarkerScreenType) u8 {
            const visible = store.snapshot();
            for (visible.slice()) |item| {
                const slot = store.find(item.id) orelse continue;
                if (slot.marker != null or !slot.owns(target)) {
                    continue;
                }

                slot.marker = switch (slot.marker_policy) {
                    .ordered => null,
                    .stable_number => if (markerForNextUnpaired(store, target, screen.buffer)) |number|
                        .{ .number = number }
                    else
                        null,
                    .pasted_path => if (pathForNextUnpaired(store, target, screen.buffer)) |uuid|
                        .{ .path = uuid }
                    else
                        null,
                };
            }

            if (!store.pendingDeletionFor(target)) {
                return 0;
            }

            var removed: u8 = 0;
            for (&store.slots, 0..) |*maybe_slot, index| {
                const slot = if (maybe_slot.*) |*value| value else continue;
                const marker = slot.marker orelse continue;
                if (!slot.owns(target)) {
                    continue;
                }

                const present = switch (marker) {
                    .number => |number| markers.markerPresent(screen.buffer, number),
                    .path => |uuid| path_marker.find(screen.buffer, uuid) != null,
                };
                if (present) {
                    continue;
                }

                const id = slot.id;
                store.retireAt(index);
                if (store.modal == id) {
                    store.modal = null;
                }
                removed += 1;
            }

            const pending = &store.marker_deletion_pending.?;
            pending.frames -= 1;
            if (removed != 0 or pending.frames == 0) {
                store.marker_deletion_pending = null;
            }

            return removed;
        }

        fn pendingDeletionFor(store: *const Self, target: TargetType) bool {
            const pending = store.marker_deletion_pending orelse return false;

            return std.meta.eql(pending.target, target);
        }

        fn pathClaimed(store: *const Self, target: TargetType, uuid: path_marker.Uuid) bool {
            for (store.slots) |maybe_slot| {
                const slot = maybe_slot orelse continue;
                const claimed = slot.markerPath() orelse continue;
                if (slot.owns(target) and std.mem.eql(u8, &claimed, &uuid)) {
                    return true;
                }
            }

            return false;
        }

        pub fn openModal(store: *Self, id: types.Id) bool {
            const slot = store.find(id) orelse return false;
            if (!store.slotVisible(slot)) {
                return false;
            }
            if (store.modal == id) {
                return false;
            }
            store.modal = id;
            return true;
        }

        pub fn closeModal(store: *Self) bool {
            if (store.modal == null) {
                return false;
            }
            store.modal = null;
            return true;
        }

        fn visibleCount(store: *const Self) usize {
            var count: usize = 0;
            for (store.slots) |maybe_slot| if (maybe_slot) |slot| {
                count += @intFromBool(store.slotVisible(&slot));
            };
            return count;
        }

        pub fn slotVisible(store: *const Self, slot: *const Slot) bool {
            if (slot.retire_pending) {
                return false;
            }
            const target = store.active_target orelse return false;
            return std.meta.eql(target, slot.target);
        }

        pub fn find(store: *Self, id: types.Id) ?*Slot {
            for (&store.slots) |*maybe_slot| if (maybe_slot.*) |*slot| {
                if (slot.id == id) {
                    return slot;
                }
            };
            return null;
        }

        pub fn findConst(store: *const Self, id: types.Id) ?*const Slot {
            for (&store.slots) |*maybe_slot| if (maybe_slot.*) |*slot| {
                if (slot.id == id) {
                    return slot;
                }
            };
            return null;
        }

        fn freeIndex(store: *const Self) ?usize {
            for (store.slots, 0..) |slot, index| if (slot == null) return index;
            return null;
        }

        fn evictOldest(store: *Self) ?void {
            var oldest_index: ?usize = null;
            var oldest: u64 = std.math.maxInt(u64);
            for (store.slots, 0..) |maybe_slot, index| if (maybe_slot) |slot| {
                if (!Delivery.canRelease(&slot)) {
                    continue;
                }
                const value = @intFromEnum(slot.id);
                if (value < oldest) {
                    oldest = value;
                    oldest_index = index;
                }
            };
            store.removeAt(oldest_index orelse return null);
            return {};
        }

        fn removeAt(store: *Self, index: usize) void {
            Delivery.retireSlot(store, index);
            store.freeSlot(&store.slots[index]);
        }

        fn retireAt(store: *Self, index: usize) void {
            const slot = &store.slots[index].?;
            Delivery.retireSlot(store, index);
            slot.retire_pending = true;
        }

        fn freeSlot(store: *Self, maybe_slot: *?Slot) void {
            if (maybe_slot.*) |*slot| {
                std.debug.assert(Delivery.canRelease(slot));
                store.total_bytes -= slot.png.len;
                std.crypto.secureZero(u8, slot.png);
                store.gpa.free(slot.png);
            }
            maybe_slot.* = null;
        }
        pub fn snapshotOrdinal(projection: *const SnapshotType, id: types.Id) ?u8 {
            for (projection.slice(), 0..) |item, index| {
                if (item.id == id) {
                    return @intCast(index);
                }
            }

            return null;
        }

        pub fn pathForNextUnpaired(store: *const Self, target: TargetType, buffer: *const BufferType) ?path_marker.Uuid {
            var found: [types.max_items * 2]MarkerType = undefined;
            const count = path_marker.collect(buffer, &found);
            var candidates: [types.max_items * 2]path_marker.Uuid = undefined;
            var candidate_count: usize = 0;
            for (found[0..count]) |marker| {
                if (store.pathClaimed(target, marker.uuid)) {
                    continue;
                }

                candidates[candidate_count] = marker.uuid;
                candidate_count += 1;
            }

            const unpaired = unpairedPathCount(store, target);
            if (unpaired == 0 or candidate_count < unpaired) {
                return null;
            }

            return candidates[candidate_count - unpaired];
        }

        pub fn unpairedPathCount(store: *const Self, target: TargetType) u8 {
            var count: u8 = 0;
            for (store.slots) |maybe_slot| {
                const slot = maybe_slot orelse continue;
                if (slot.owns(target) and slot.marker_policy == .pasted_path and slot.marker == null) {
                    count += 1;
                }
            }

            return count;
        }

        pub fn markerForNextUnpaired(store: *const Self, target: TargetType, buffer: *const BufferType) ?u16 {
            var candidates: [types.max_items]u16 = @splat(0);
            var candidate_count: u8 = 0;
            var scan: MarkerScanType = .{ .buffer = buffer };
            while (scan.next()) |marker| {
                if (markerNumberClaimed(store, target, marker.number)) {
                    continue;
                }

                var duplicate = false;
                for (candidates[0..candidate_count]) |candidate| {
                    duplicate = duplicate or candidate == marker.number;
                }
                if (duplicate) {
                    continue;
                }

                var at: usize = candidate_count;
                if (candidate_count < candidates.len) {
                    candidate_count += 1;
                } else if (marker.number <= candidates[candidates.len - 1]) {
                    continue;
                } else {
                    at = candidates.len - 1;
                }
                while (at != 0 and candidates[at - 1] < marker.number) : (at -= 1) {
                    if (at < candidates.len) {
                        candidates[at] = candidates[at - 1];
                    }
                }
                if (at < candidates.len) {
                    candidates[at] = marker.number;
                }
            }

            const unpaired = unpairedStableCount(store, target);
            if (unpaired == 0 or candidate_count < unpaired) {
                return null;
            }

            return candidates[unpaired - 1];
        }

        pub fn unpairedStableCount(store: *const Self, target: TargetType) u8 {
            var count: u8 = 0;
            for (store.slots) |maybe_slot| {
                const slot = maybe_slot orelse continue;
                if (slot.owns(target) and slot.marker_policy == .stable_number and slot.marker == null) {
                    count += 1;
                }
            }

            return count;
        }

        pub fn markerNumberClaimed(store: *const Self, target: TargetType, number: u16) bool {
            for (store.slots) |maybe_slot| {
                const slot = maybe_slot orelse continue;
                if (slot.owns(target) and slot.markerNumber() == number) {
                    return true;
                }
            }

            return false;
        }
    };
}
