const cellgrid = @import("cellgrid");
const model_data = @import("model");
const std = @import("std");
const data = @import("model");
const catalog = @import("catalog.zig");
const AttachmentSnapshot = @import("AttachmentSnapshot.zig");
const Item = @import("Item.zig");
const MarkerScreen = @import("MarkerScreen.zig");
const markers = @import("markers.zig");
const DeletionProbe = @import("DeletionProbe.zig");
const MarkerScan = @import("MarkerScan.zig");

/// Creates an attachment catalog with presentation-owned slot resources.
/// Example: `var catalog = Catalog(Delivery).init(gpa);`.
pub fn Type(comptime Delivery: type) type {
    return struct {
        const Self = @This();
        pub const Slot = struct {
            delivery: Delivery.SlotState,

            id: model_data.AttachmentId,
            target: model_data.AttachmentTarget,
            png: []u8,
            width: u32,
            height: u32,
            marker_policy: model_data.AttachmentMarkerPolicy,
            marker: ?AttachmentMarkerIdentity = null,
            retire_pending: bool = false,

            pub fn markerNumber(self: *const Slot) ?u16 {
                const marker = self.marker orelse return null;

                return switch (marker) {
                    .number => |number| number,
                    .path => null,
                };
            }

            pub fn markerPath(self: *const Slot) ?model_data.attachments_path_marker.Uuid {
                const marker = self.marker orelse return null;

                return switch (marker) {
                    .number => null,
                    .path => |uuid| uuid,
                };
            }

            pub fn owns(self: *const Slot, target: model_data.AttachmentTarget) bool {
                return !self.retire_pending and std.meta.eql(self.target, target);
            }
        };

        pub const TargetChange = struct {
            changed: bool = false,
            layout_changed: bool = false,
        };

        gpa: std.mem.Allocator,
        slots: [model_data.attachment_types.max_items]?Slot = @splat(null),
        active_target: ?model_data.AttachmentTarget = null,
        marker_deletion_pending: ?PendingDeletion = null,
        modal: ?model_data.AttachmentId = null,
        total_bytes: usize = 0,
        ingress_version: u64 = 0,

        delivery: Delivery.State = .{},
        pub fn init(gpa: std.mem.Allocator) Self {
            return .{ .gpa = gpa };
        }

        pub fn deinit(self: *Self) void {
            for (&self.slots) |*slot| self.freeSlot(slot);
        }

        pub fn retainedBytes(self: *const Self) usize {
            return self.total_bytes;
        }

        pub fn ingressVersion(self: *const Self) u64 {
            return self.ingress_version;
        }

        pub fn cleanupPending(self: *const Self) bool {
            for (self.slots) |maybe_slot| if (maybe_slot) |slot|
                if (slot.retire_pending) return true;
            return false;
        }

        pub fn reapRetired(self: *Self) void {
            for (&self.slots) |*maybe_slot| {
                if (maybe_slot.* == null or !maybe_slot.*.?.retire_pending or !Delivery.canRelease(&maybe_slot.*.?)) {
                    continue;
                }
                self.freeSlot(maybe_slot);
            }
        }

        pub fn setTarget(self: *Self, target: ?model_data.AttachmentTarget) TargetChange {
            const previous_pane = if (self.visibleCount() != 0)
                if (self.active_target) |active| active.pane_id else null
            else
                null;
            if (catalog.optionalTargetEql(self.active_target, target)) {
                return .{};
            }
            self.active_target = target;
            self.marker_deletion_pending = null;
            self.modal = null;
            Delivery.targetChanged(self);
            const current_pane = if (self.visibleCount() != 0)
                if (target) |active| active.pane_id else null
            else
                null;

            return .{
                .changed = true,
                .layout_changed = previous_pane != current_pane,
            };
        }

        pub fn hasVisibleItems(self: *const Self) bool {
            return self.visibleCount() != 0;
        }

        pub fn visibleTarget(self: *const Self) ?model_data.AttachmentTarget {
            if (self.visibleCount() == 0) {
                return null;
            }

            return self.active_target;
        }

        pub fn hasModal(self: *const Self) bool {
            return self.modal != null;
        }

        pub fn snapshot(self: *const Self) AttachmentSnapshot {
            var result: AttachmentSnapshot = .{ .modal = self.modal };
            for (self.slots) |maybe_slot| if (maybe_slot) |slot| {
                if (!self.slotVisible(&slot)) {
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
                        std.mem.swap(Item, &result.items[at - 1], &result.items[at]);
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

        pub fn adopt(self: *Self, capture: *model_data.Capture) !void {
            if (capture.png.len == 0 or capture.png.len > model_data.attachment_types.max_png_bytes or
                capture.width == 0 or capture.height == 0)
            {
                return error.InvalidClipboardImage;
            }
            const pixels = std.math.mul(u64, capture.width, capture.height) catch
                return error.ClipboardImageTooLarge;
            if (pixels > model_data.attachment_types.max_pixels) {
                return error.ClipboardImageTooLarge;
            }
            while (self.total_bytes + capture.png.len > model_data.attachment_types.max_retained_bytes or
                self.freeIndex() == null)
            {
                self.evictOldest() orelse return error.AttachmentSelfFull;
            }
            const delivery = try Delivery.createSlot(self);
            const index = self.freeIndex().?;
            const request = capture.request;
            const width = capture.width;
            const height = capture.height;
            const png = capture.png;
            capture.png = &.{};
            self.gpa.destroy(capture);
            self.slots[index] = .{
                .id = @enumFromInt(request.sequence),
                .target = request.target,
                .png = png,
                .width = width,
                .height = height,
                .delivery = delivery,
                .marker_policy = request.marker_policy,
            };
            self.total_bytes += png.len;
            self.ingress_version +%= 1;
        }

        pub fn remove(self: *Self, id: model_data.AttachmentId) bool {
            for (&self.slots, 0..) |*slot, index| {
                if (slot.* == null or slot.*.?.id != id or slot.*.?.retire_pending) {
                    continue;
                }
                self.retireAt(index);
                if (self.modal == id) {
                    self.modal = null;
                }
                return true;
            }
            return false;
        }

        pub fn removeVisible(self: *Self, target: model_data.AttachmentTarget) u8 {
            var removed: u8 = 0;
            for (&self.slots, 0..) |*slot, index| {
                if (slot.* == null or slot.*.?.retire_pending or !std.meta.eql(slot.*.?.target, target)) {
                    continue;
                }

                self.retireAt(index);
                removed += 1;
            }
            if (removed != 0) {
                self.modal = null;
            }
            if (self.pendingDeletionFor(target)) {
                self.marker_deletion_pending = null;
            }

            return removed;
        }

        pub fn planMarkerRemoval(self: *const Self, id: model_data.AttachmentId, screen: MarkerScreen) ?model_data.MarkerRemoval {
            const visible = self.snapshot();
            const ordinal = snapshotOrdinal(&visible, id) orelse return null;
            const slot = self.findConst(id) orelse return null;
            const removal = switch (slot.marker_policy) {
                .ordered, .stable_number => markers.planPlaceholderRemoval(slot.markerNumber(), ordinal, screen),
                .pasted_path => markers.planPathRemoval(slot.markerPath(), screen),
            } orelse return null;
            if (removal.keyCount() > model_data.attachment_types.max_removal_keys) {
                return null;
            }

            return removal;
        }

        pub fn idAtMarkerDeletion(self: *const Self, screen: MarkerScreen, deletion: model_data.AttachmentMarkerDeletion) ?model_data.AttachmentId {
            const visible = self.snapshot();
            for (visible.slice(), 0..) |item, index| {
                const slot = self.findConst(item.id) orelse continue;
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

        pub fn pendingMarkerAtDeletion(self: *const Self, screen: MarkerScreen, probe: DeletionProbe) bool {
            const visible = self.snapshot();
            if (visible.len >= model_data.attachment_types.max_items) {
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
                    const target = self.active_target orelse return false;
                    var found: [model_data.attachment_types.max_items * 2]model_data.Marker = undefined;
                    const count = model_data.attachments_path_marker.collect(screen.buffer, &found);
                    for (found[0..count]) |marker| {
                        if (self.pathClaimed(target, marker.uuid)) {
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

        pub fn expectMarkerDeletion(self: *Self, target: model_data.AttachmentTarget) void {
            for (self.slots) |maybe_slot| {
                const slot = maybe_slot orelse continue;
                if (slot.owns(target) and slot.marker_policy.learnsIdentity()) {
                    self.marker_deletion_pending = .{ .target = target, .frames = model_data.attachment_types.deletion_watch_frames };
                    return;
                }
            }
        }

        pub fn reconcileMarkers(self: *Self, target: model_data.AttachmentTarget, screen: MarkerScreen) u8 {
            const visible = self.snapshot();
            for (visible.slice()) |item| {
                const slot = self.find(item.id) orelse continue;
                if (slot.marker != null or !slot.owns(target)) {
                    continue;
                }

                slot.marker = switch (slot.marker_policy) {
                    .ordered => null,
                    .stable_number => if (markerForNextUnpaired(self, target, screen.buffer)) |number|
                        .{ .number = number }
                    else
                        null,
                    .pasted_path => if (pathForNextUnpaired(self, target, screen.buffer)) |uuid|
                        .{ .path = uuid }
                    else
                        null,
                };
            }

            if (!self.pendingDeletionFor(target)) {
                return 0;
            }

            var removed: u8 = 0;
            for (&self.slots, 0..) |*maybe_slot, index| {
                const slot = if (maybe_slot.*) |*value| value else continue;
                const marker = slot.marker orelse continue;
                if (!slot.owns(target)) {
                    continue;
                }

                const present = switch (marker) {
                    .number => |number| markers.markerPresent(screen.buffer, number),
                    .path => |uuid| model_data.attachments_path_marker.find(screen.buffer, uuid) != null,
                };
                if (present) {
                    continue;
                }

                const id = slot.id;
                self.retireAt(index);
                if (self.modal == id) {
                    self.modal = null;
                }
                removed += 1;
            }

            const pending = &self.marker_deletion_pending.?;
            pending.frames -= 1;
            if (removed != 0 or pending.frames == 0) {
                self.marker_deletion_pending = null;
            }

            return removed;
        }

        fn pendingDeletionFor(self: *const Self, target: model_data.AttachmentTarget) bool {
            const pending = self.marker_deletion_pending orelse return false;

            return std.meta.eql(pending.target, target);
        }

        fn pathClaimed(self: *const Self, target: model_data.AttachmentTarget, uuid: model_data.attachments_path_marker.Uuid) bool {
            for (self.slots) |maybe_slot| {
                const slot = maybe_slot orelse continue;
                const claimed = slot.markerPath() orelse continue;
                if (slot.owns(target) and std.mem.eql(u8, &claimed, &uuid)) {
                    return true;
                }
            }

            return false;
        }

        pub fn openModal(self: *Self, id: model_data.AttachmentId) bool {
            const slot = self.find(id) orelse return false;
            if (!self.slotVisible(slot)) {
                return false;
            }
            if (self.modal == id) {
                return false;
            }
            self.modal = id;
            return true;
        }

        pub fn closeModal(self: *Self) bool {
            if (self.modal == null) {
                return false;
            }
            self.modal = null;
            return true;
        }

        fn visibleCount(self: *const Self) usize {
            var count: usize = 0;
            for (self.slots) |maybe_slot| if (maybe_slot) |slot| {
                count += @intFromBool(self.slotVisible(&slot));
            };
            return count;
        }

        pub fn slotVisible(self: *const Self, slot: *const Slot) bool {
            if (slot.retire_pending) {
                return false;
            }
            const target = self.active_target orelse return false;
            return std.meta.eql(target, slot.target);
        }

        pub fn find(self: *Self, id: model_data.AttachmentId) ?*Slot {
            for (&self.slots) |*maybe_slot| if (maybe_slot.*) |*slot| {
                if (slot.id == id) {
                    return slot;
                }
            };
            return null;
        }

        pub fn findConst(self: *const Self, id: model_data.AttachmentId) ?*const Slot {
            for (&self.slots) |*maybe_slot| if (maybe_slot.*) |*slot| {
                if (slot.id == id) {
                    return slot;
                }
            };
            return null;
        }

        fn freeIndex(self: *const Self) ?usize {
            for (self.slots, 0..) |slot, index| if (slot == null) return index;
            return null;
        }

        fn evictOldest(self: *Self) ?void {
            var oldest_index: ?usize = null;
            var oldest: u64 = std.math.maxInt(u64);
            for (self.slots, 0..) |maybe_slot, index| if (maybe_slot) |slot| {
                if (!Delivery.canRelease(&slot)) {
                    continue;
                }
                const value = @intFromEnum(slot.id);
                if (value < oldest) {
                    oldest = value;
                    oldest_index = index;
                }
            };
            self.removeAt(oldest_index orelse return null);
            return {};
        }

        fn removeAt(self: *Self, index: usize) void {
            Delivery.retireSlot(self, index);
            self.freeSlot(&self.slots[index]);
        }

        fn retireAt(self: *Self, index: usize) void {
            const slot = &self.slots[index].?;
            Delivery.retireSlot(self, index);
            slot.retire_pending = true;
        }

        fn freeSlot(self: *Self, maybe_slot: *?Slot) void {
            if (maybe_slot.*) |*slot| {
                std.debug.assert(Delivery.canRelease(slot));
                self.total_bytes -= slot.png.len;
                std.crypto.secureZero(u8, slot.png);
                self.gpa.free(slot.png);
            }
            maybe_slot.* = null;
        }
        pub fn snapshotOrdinal(projection: *const AttachmentSnapshot, id: model_data.AttachmentId) ?u8 {
            for (projection.slice(), 0..) |item, index| {
                if (item.id == id) {
                    return @intCast(index);
                }
            }

            return null;
        }

        pub fn pathForNextUnpaired(self: *const Self, target: model_data.AttachmentTarget, buffer: *const cellgrid.Buffer) ?model_data.attachments_path_marker.Uuid {
            var found: [model_data.attachment_types.max_items * 2]model_data.Marker = undefined;
            const count = model_data.attachments_path_marker.collect(buffer, &found);
            var candidates: [model_data.attachment_types.max_items * 2]model_data.attachments_path_marker.Uuid = undefined;
            var candidate_count: usize = 0;
            for (found[0..count]) |marker| {
                if (self.pathClaimed(target, marker.uuid)) {
                    continue;
                }

                candidates[candidate_count] = marker.uuid;
                candidate_count += 1;
            }

            const unpaired = unpairedPathCount(self, target);
            if (unpaired == 0 or candidate_count < unpaired) {
                return null;
            }

            return candidates[candidate_count - unpaired];
        }

        pub fn unpairedPathCount(self: *const Self, target: model_data.AttachmentTarget) u8 {
            var count: u8 = 0;
            for (self.slots) |maybe_slot| {
                const slot = maybe_slot orelse continue;
                if (slot.owns(target) and slot.marker_policy == .pasted_path and slot.marker == null) {
                    count += 1;
                }
            }

            return count;
        }

        pub fn markerForNextUnpaired(self: *const Self, target: model_data.AttachmentTarget, buffer: *const cellgrid.Buffer) ?u16 {
            var candidates: [model_data.attachment_types.max_items]u16 = @splat(0);
            var candidate_count: u8 = 0;
            var scan: MarkerScan = .{ .buffer = buffer };
            while (scan.next()) |marker| {
                if (markerNumberClaimed(self, target, marker.number)) {
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

            const unpaired = unpairedStableCount(self, target);
            if (unpaired == 0 or candidate_count < unpaired) {
                return null;
            }

            return candidates[unpaired - 1];
        }

        pub fn unpairedStableCount(self: *const Self, target: model_data.AttachmentTarget) u8 {
            var count: u8 = 0;
            for (self.slots) |maybe_slot| {
                const slot = maybe_slot orelse continue;
                if (slot.owns(target) and slot.marker_policy == .stable_number and slot.marker == null) {
                    count += 1;
                }
            }

            return count;
        }

        pub fn markerNumberClaimed(self: *const Self, target: model_data.AttachmentTarget, number: u16) bool {
            for (self.slots) |maybe_slot| {
                const slot = maybe_slot orelse continue;
                if (slot.owns(target) and slot.markerNumber() == number) {
                    return true;
                }
            }

            return false;
        }
    };
}

const PendingDeletion = struct {
    target: data.AttachmentTarget,
    frames: u8,
};

const AttachmentMarkerIdentity = union(enum) {
    number: u16,
    path: model_data.attachments_path_marker.Uuid,
};
