//! Local clipboard capture and bounded client-owned image previews.
//!
//! Clipboard access runs only in a concurrent media task. The interactive
//! path forwards the triggering key before it schedules that task. Captured
//! bytes are disposable presentation state: the agent remains the authority
//! for whether an attachment was accepted.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("telar-core");
const kitty = @import("../graphics/kitty.zig");
pub const path_marker = @import("path_marker.zig");

const Io = std.Io;
const schema = core.schema;
const ui = core.ui;

pub const max_items: usize = 4;
pub const max_source_bytes: usize = 32 * 1024 * 1024;
pub const max_png_bytes: usize = 16 * 1024 * 1024;
pub const max_pixels: u64 = 16 * 1024 * 1024;
pub const max_retained_bytes: usize = 32 * 1024 * 1024;
pub const max_marker_navigation_steps: u8 = 120;
/// Keys one marker removal may enqueue as a single pane-input transaction.
/// The pane-input boundary encodes at most this many keys per transaction.
pub const max_removal_keys: usize = 256;
/// Committed frames inspected for a marker's disappearance after a deletion
/// key. The child may publish an unrelated frame before it redraws its editor.
pub const deletion_watch_frames: u8 = 3;

const marker_prefix = "[Image #";
const marker_prefix_width: u16 = marker_prefix.len;
const minimum_marker_width: u16 = marker_prefix_width + 2;

pub fn platformSupported() bool {
    return builtin.os.tag == .macos;
}

pub const Target = struct {
    pane_id: schema.PaneId,
    pane_generation: u64,

    pub fn validate(target: Target) !void {
        if (target.pane_id == .invalid or target.pane_generation == 0) {
            return error.InvalidAttachmentTarget;
        }
    }
};

pub const CaptureRequest = struct {
    target: Target,
    sequence: u64,
    marker_policy: MarkerPolicy = .ordered,
};

/// How the child's prompt identifies one pasted image.
///
/// - `ordered`: Codex renumbers `[Image #N]` after deletion, so the preview's
///   shelf position is its marker.
/// - `stable_number`: Claude keeps increasing `[Image #N]`, so the number
///   rendered for each preview is learned and retained.
/// - `pasted_path`: Pi inserts `<tmpdir>/pi-clipboard-<uuid>.<ext>` as plain
///   text, so the file UUID is learned and the whole path is the marker.
pub const MarkerPolicy = enum {
    ordered,
    stable_number,
    pasted_path,

    pub fn learnsIdentity(policy: MarkerPolicy) bool {
        return policy != .ordered;
    }
};

const MarkerIdentity = union(enum) {
    number: u16,
    path: path_marker.Uuid,
};

pub const Capture = struct {
    request: CaptureRequest,
    png: []u8,
    width: u32,
    height: u32,

    pub fn deinit(capture: *Capture, gpa: std.mem.Allocator) void {
        if (capture.png.len != 0) {
            std.crypto.secureZero(u8, capture.png);
            gpa.free(capture.png);
        }
        gpa.destroy(capture);
    }
};

/// Owns only the result pointer that can outlive a cancelled capture worker.
/// The client model owns the active capture identity and target.
pub const CaptureResources = struct {
    orphan: ?*Capture = null,

    /// Transfers one completed worker result to the client event handler.
    ///
    /// ```zig
    /// const owned = resources.take(completed);
    /// ```
    pub fn take(resources: *CaptureResources, capture: *Capture) *Capture {
        std.debug.assert(resources.orphan == capture);
        resources.orphan = null;
        return capture;
    }

    /// Frees a result published before its worker was cancelled.
    ///
    /// ```zig
    /// defer resources.deinit(gpa);
    /// ```
    pub fn deinit(resources: *CaptureResources, gpa: std.mem.Allocator) void {
        if (resources.orphan) |capture| {
            capture.deinit(gpa);
        }

        resources.* = .{};
    }
};

pub const Id = enum(u64) {
    invalid = 0,
    _,
};

pub const Item = struct {
    id: Id,
    width: u32,
    height: u32,
};

pub const Snapshot = struct {
    items: [max_items]Item = undefined,
    len: u8 = 0,
    modal: ?Id = null,

    pub fn slice(snapshot: *const Snapshot) []const Item {
        return snapshot.items[0..snapshot.len];
    }
};

pub const MarkerScreen = struct {
    buffer: *const ui.Buffer,
    cursor: schema.frame.Cursor,
};

pub const MarkerDeletion = enum {
    backward,
    forward,
};

pub const MarkerRemoval = struct {
    direction: enum {
        left,
        right,
    },
    steps: u8,
    deletion: MarkerDeletion,
    /// Deletion keys needed: one for an atomic placeholder, one per grapheme
    /// for a pasted path.
    deletions: u8 = 1,

    pub fn keyCount(removal: MarkerRemoval) usize {
        return @as(usize, removal.steps) * 2 + removal.deletions;
    }
};

/// Names the deletion being probed for a preview that has no slot yet.
pub const DeletionProbe = struct {
    deletion: MarkerDeletion,
    policy: MarkerPolicy = .ordered,
};

const PendingDeletion = struct {
    target: Target,
    frames: u8,
};

pub const PlanItem = struct {
    id: Id,
    area: ui.Rect,
};

pub const Plan = struct {
    thumbnails: [max_items]PlanItem = undefined,
    thumbnail_count: u8 = 0,
    modal: ?PlanItem = null,

    pub fn thumbnailSlice(plan: *const Plan) []const PlanItem {
        return plan.thumbnails[0..plan.thumbnail_count];
    }
};

const PlacementState = struct {
    id: u32,
    z: i32,
    desired: ?kitty.OutputPlacement = null,
    emitted: ?kitty.OutputPlacement = null,

    fn wanted(placement: *const PlacementState) bool {
        return placement.desired != null;
    }

    fn damaged(placement: *const PlacementState) bool {
        return !optionalPlacementEql(placement.desired, placement.emitted);
    }

    fn write(placement: *PlacementState, writer: *Io.Writer, image_id: u32) Io.Writer.Error!usize {
        if (!placement.damaged()) {
            return 0;
        }

        var written: usize = 0;
        if (placement.emitted != null) {
            written += try kitty.writeDeletePlacement(writer, image_id, placement.id);
        }

        if (placement.desired) |desired| {
            written += try kitty.writeUiPlacement(writer, image_id, placement.id, desired, placement.z);
        }

        placement.emitted = placement.desired;

        return written;
    }
};

const Slot = struct {
    id: Id,
    target: Target,
    png: []u8,
    width: u32,
    height: u32,
    image_id: u32,
    thumbnail: PlacementState,
    modal: PlacementState,
    image_emitted: bool = false,
    image_dirty: bool = true,
    transfer_offset: usize = 0,
    marker_policy: MarkerPolicy,
    marker: ?MarkerIdentity = null,
    retire_pending: bool = false,

    fn markerNumber(slot: *const Slot) ?u16 {
        const marker = slot.marker orelse return null;

        return switch (marker) {
            .number => |number| number,
            .path => null,
        };
    }

    fn markerPath(slot: *const Slot) ?path_marker.Uuid {
        const marker = slot.marker orelse return null;

        return switch (marker) {
            .number => null,
            .path => |uuid| uuid,
        };
    }

    fn owns(slot: *const Slot, target: Target) bool {
        return !slot.retire_pending and std.meta.eql(slot.target, target);
    }
};

/// Bounded, disposable presentation state for images the focused local agent
/// saw on the system clipboard. The child remains responsible for accepting
/// the actual paste; this store only mirrors it visually.
pub const Store = struct {
    pub const TargetChange = struct {
        changed: bool = false,
        layout_changed: bool = false,
    };
    const first_image_id: u32 = 0x90000000;
    const first_thumbnail_placement_id: u32 = 0xa0000000;
    const first_modal_placement_id: u32 = 0xb0000000;
    const max_host_ids: u32 = 0x0fffffff;
    const thumbnail_z: i32 = 1500;
    const modal_z: i32 = 2000;

    gpa: std.mem.Allocator,
    slots: [max_items]?Slot = @splat(null),
    active_target: ?Target = null,
    marker_deletion_pending: ?PendingDeletion = null,
    modal: ?Id = null,
    supported: bool = false,
    cell_width: u16 = 0,
    cell_height: u16 = 0,
    total_bytes: usize = 0,
    next_host_id: u32 = 1,
    ingress_version: u64 = 0,
    partial: ?u8 = null,
    abort_pending: bool = false,
    delete_ids: [max_items * 2]u32 = undefined,
    delete_count: u8 = 0,
    delete_all_pending: bool = false,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(store: *Store) void {
        for (&store.slots) |*slot| store.freeSlot(slot);
    }

    pub fn retainedBytes(store: *const Store) usize {
        return store.total_bytes;
    }

    /// Returns the revision advanced by each accepted clipboard image.
    ///
    /// ```zig
    /// const revision = store.ingressVersion();
    /// ```
    pub fn ingressVersion(store: *const Store) u64 {
        return store.ingress_version;
    }

    pub fn cleanupPending(store: *const Store) bool {
        for (store.slots) |maybe_slot| if (maybe_slot) |slot|
            if (slot.retire_pending) return true;
        return false;
    }

    /// Runs only from the media event. Large private buffers are never wiped
    /// on the mouse/input path that requested their dismissal.
    pub fn reapRetired(store: *Store) void {
        for (&store.slots) |*maybe_slot| {
            if (maybe_slot.* == null or !maybe_slot.*.?.retire_pending) {
                continue;
            }
            store.freeSlot(maybe_slot);
        }
    }

    /// Applies host graphics support and cell dimensions, returning whether
    /// attachment rendering state changed.
    ///
    /// ```zig
    /// const changed = store.configure(.{ .support = .supported, .cell_width = 8, .cell_height = 16 });
    /// ```
    pub fn configure(store: *Store, configuration: kitty.Configuration) bool {
        const supported = configuration.support == .supported;
        if (store.supported == supported and store.cell_width == configuration.cell_width and
            store.cell_height == configuration.cell_height)
        {
            return false;
        }
        if (!supported and store.partial != null) {
            store.cancelPartial();
        }
        store.supported = supported;
        store.cell_width = configuration.cell_width;
        store.cell_height = configuration.cell_height;
        if (supported) {
            for (&store.slots) |*maybe_slot| {
                if (maybe_slot.*) |*slot| {
                    slot.image_dirty = !slot.image_emitted;
                }
            }
        }
        return true;
    }

    /// Returns whether the shelf appeared, disappeared or moved to another
    /// pane. Those transitions change pane geometry.
    pub fn setTarget(store: *Store, target: ?Target) TargetChange {
        const previous_pane = if (store.visibleCount() != 0)
            if (store.active_target) |active| active.pane_id else null
        else
            null;
        if (optionalTargetEql(store.active_target, target)) {
            return .{};
        }
        store.active_target = target;
        store.marker_deletion_pending = null;
        store.modal = null;
        if (store.partial) |index| {
            const slot = &store.slots[index].?;
            if (!store.slotVisible(slot)) {
                store.cancelPartial();
            }
        }
        const current_pane = if (store.visibleCount() != 0)
            if (target) |active| active.pane_id else null
        else
            null;

        return .{
            .changed = true,
            .layout_changed = previous_pane != current_pane,
        };
    }

    pub fn hasVisibleItems(store: *const Store) bool {
        return store.visibleCount() != 0;
    }

    /// Returns the pane that owns the visible shelf. A target with no matching
    /// previews has no reservation.
    ///
    /// ```zig
    /// const target = store.visibleTarget() orelse return;
    /// ```
    pub fn visibleTarget(store: *const Store) ?Target {
        if (store.visibleCount() == 0) {
            return null;
        }

        return store.active_target;
    }

    pub fn hasModal(store: *const Store) bool {
        return store.modal != null;
    }

    pub fn snapshot(store: *const Store) Snapshot {
        var result: Snapshot = .{ .modal = store.modal };
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

    /// Takes ownership of `capture.png` and destroys only the capture shell.
    pub fn adopt(store: *Store, capture: *Capture) !void {
        if (capture.png.len == 0 or capture.png.len > max_png_bytes or
            capture.width == 0 or capture.height == 0)
        {
            return error.InvalidClipboardImage;
        }
        const pixels = std.math.mul(u64, capture.width, capture.height) catch
            return error.ClipboardImageTooLarge;
        if (pixels > max_pixels) {
            return error.ClipboardImageTooLarge;
        }
        while (store.total_bytes + capture.png.len > max_retained_bytes or
            store.freeIndex() == null)
        {
            store.evictOldest() orelse return error.AttachmentStoreFull;
        }
        const host_id = try store.allocateHostId();
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
            .image_id = first_image_id + host_id,
            .thumbnail = .{ .id = first_thumbnail_placement_id + host_id, .z = thumbnail_z },
            .modal = .{ .id = first_modal_placement_id + host_id, .z = modal_z },
            .marker_policy = request.marker_policy,
        };
        store.total_bytes += png.len;
        store.ingress_version +%= 1;
    }

    pub fn remove(store: *Store, id: Id) bool {
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

    /// Retires every preview belonging to one submitted prompt.
    ///
    /// ```zig
    /// const removed = store.removeVisible(target);
    /// ```
    pub fn removeVisible(store: *Store, target: Target) u8 {
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

    /// Plans a marker deletion while restoring the child's cursor. An atomic
    /// placeholder counts as one editor step even though it occupies ten
    /// terminal cells; a pasted path costs one deletion per grapheme.
    ///
    /// ```zig
    /// const plan = store.planMarkerRemoval(id, screen) orelse return;
    /// ```
    pub fn planMarkerRemoval(store: *const Store, id: Id, screen: MarkerScreen) ?MarkerRemoval {
        const visible = store.snapshot();
        const ordinal = snapshotOrdinal(&visible, id) orelse return null;
        const slot = store.findConst(id) orelse return null;
        const removal = switch (slot.marker_policy) {
            .ordered, .stable_number => planPlaceholderRemoval(slot, ordinal, screen),
            .pasted_path => planPathRemoval(slot, screen),
        } orelse return null;
        if (removal.keyCount() > max_removal_keys) {
            return null;
        }

        return removal;
    }

    /// Resolves a Backspace or Delete positioned directly beside an image
    /// marker to the preview that the child editor will remove.
    ///
    /// ```zig
    /// const id = store.idAtMarkerDeletion(screen, .backward) orelse return;
    /// ```
    pub fn idAtMarkerDeletion(store: *const Store, screen: MarkerScreen, deletion: MarkerDeletion) ?Id {
        const visible = store.snapshot();
        for (visible.slice(), 0..) |item, index| {
            const slot = store.findConst(item.id) orelse continue;
            const touches = switch (slot.marker_policy) {
                .ordered, .stable_number => screen.cursor.visible and markerTouchesCursor(screen.buffer, .{
                    .ordinal = slot.markerNumber() orelse @as(u16, @intCast(index + 1)),
                    .cursor = screen.cursor,
                    .deletion = deletion,
                }),
                .pasted_path => pathTouchesCursor(slot.markerPath() orelse continue, screen, deletion),
            };
            if (touches) {
                return item.id;
            }
        }

        return null;
    }

    /// Reports whether a deletion targets the marker of a clipboard capture
    /// that has not reached the preview store yet.
    ///
    /// ```zig
    /// if (store.pendingMarkerAtDeletion(screen, .{ .deletion = .backward })) cancelCapture();
    /// ```
    pub fn pendingMarkerAtDeletion(store: *const Store, screen: MarkerScreen, probe: DeletionProbe) bool {
        const visible = store.snapshot();
        if (visible.len >= max_items) {
            return false;
        }

        switch (probe.policy) {
            .ordered, .stable_number => {
                if (!screen.cursor.visible) {
                    return false;
                }

                return markerTouchesCursor(screen.buffer, .{
                    .ordinal = @as(u16, visible.len) + 1,
                    .cursor = screen.cursor,
                    .deletion = probe.deletion,
                });
            },
            .pasted_path => {
                const target = store.active_target orelse return false;
                var found: [max_items * 2]path_marker.Marker = undefined;
                const count = path_marker.collect(screen.buffer, &found);
                for (found[0..count]) |marker| {
                    if (store.pathClaimed(target, marker.uuid)) {
                        continue;
                    }
                    if (markerCursorTouches(marker, screen, probe.deletion)) {
                        return true;
                    }
                }

                return false;
            },
        }
    }

    /// Arms one bounded watch for a marker disappearing from the target's
    /// next committed frames. Only policies that learn marker identities can
    /// recognise a disappearance.
    ///
    /// ```zig
    /// store.expectMarkerDeletion(target);
    /// ```
    pub fn expectMarkerDeletion(store: *Store, target: Target) void {
        for (store.slots) |maybe_slot| {
            const slot = maybe_slot orelse continue;
            if (slot.owns(target) and slot.marker_policy.learnsIdentity()) {
                store.marker_deletion_pending = .{ .target = target, .frames = deletion_watch_frames };
                return;
            }
        }
    }

    /// Learns Claude's stable marker numbers and Pi's pasted file paths, then
    /// retires previews whose learned marker disappeared from a committed
    /// pane frame while a deletion watch is armed.
    ///
    /// ```zig
    /// const removed = store.reconcileMarkers(target, screen);
    /// ```
    pub fn reconcileMarkers(store: *Store, target: Target, screen: MarkerScreen) u8 {
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
                .number => |number| markerPresent(screen.buffer, number),
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

    fn pendingDeletionFor(store: *const Store, target: Target) bool {
        const pending = store.marker_deletion_pending orelse return false;

        return std.meta.eql(pending.target, target);
    }

    fn pathClaimed(store: *const Store, target: Target, uuid: path_marker.Uuid) bool {
        for (store.slots) |maybe_slot| {
            const slot = maybe_slot orelse continue;
            const claimed = slot.markerPath() orelse continue;
            if (slot.owns(target) and std.mem.eql(u8, &claimed, &uuid)) {
                return true;
            }
        }

        return false;
    }

    pub fn openModal(store: *Store, id: Id) bool {
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

    pub fn closeModal(store: *Store) bool {
        if (store.modal == null) {
            return false;
        }
        store.modal = null;
        return true;
    }

    pub fn prepare(store: *Store, plan: Plan) void {
        for (&store.slots) |*maybe_slot| if (maybe_slot.*) |*slot| {
            slot.thumbnail.desired = null;
            slot.modal.desired = null;
        };
        if (!store.supported or store.cell_width == 0 or store.cell_height == 0) {
            return;
        }
        for (plan.thumbnailSlice()) |item| if (store.find(item.id)) |slot| {
            if (store.slotVisible(slot)) {
                slot.thumbnail.desired = store.fitPlacement(slot, item.area);
            }
        };
        if (plan.modal) |item| {
            if (store.find(item.id)) |slot| {
                if (store.slotVisible(slot)) {
                    slot.modal.desired = store.fitPlacement(slot, item.area);
                }
            }
        }
    }

    pub fn damaged(store: *const Store) bool {
        if (!store.supported) {
            return false;
        }
        if (store.abort_pending or store.partial != null or store.delete_count != 0 or
            store.delete_all_pending)
        {
            return true;
        }
        for (store.slots) |maybe_slot| if (maybe_slot) |slot| {
            const wanted = slot.thumbnail.wanted() or slot.modal.wanted();
            if ((wanted and slot.image_dirty) or
                slot.thumbnail.damaged() or slot.modal.damaged())
            {
                return true;
            }
        };
        return false;
    }

    pub fn transferInProgress(store: *const Store) bool {
        return store.partial != null or store.abort_pending;
    }

    pub fn write(store: *Store, writer: *Io.Writer) Io.Writer.Error!usize {
        if (!store.supported or !store.damaged()) {
            return 0;
        }
        var written: usize = 0;
        if (store.abort_pending) {
            written += try kitty.writeTransmissionAbort(writer);
            store.abort_pending = false;
        } else if (store.partial) |index| {
            const slot = &store.slots[index].?;
            const progress = try kitty.writePngTransmissionChunks(writer, .{
                .external_id = slot.image_id,
                .png = slot.png,
                .start_offset = slot.transfer_offset,
                .budget = kitty.transmission_budget_per_frame,
            });
            written += progress.written;
            slot.transfer_offset = progress.offset;
            if (progress.offset != slot.png.len) {
                return written;
            }
            slot.transfer_offset = 0;
            slot.image_dirty = false;
            slot.image_emitted = true;
            store.partial = null;
            return written;
        }

        if (store.delete_all_pending) {
            written += try kitty.writeDeleteImageRange(
                writer,
                first_image_id,
                first_image_id + max_host_ids,
            );
            store.delete_all_pending = false;
            store.delete_count = 0;
            for (&store.slots) |*maybe_slot| if (maybe_slot.*) |*slot| {
                slot.image_emitted = false;
                slot.image_dirty = true;
                slot.thumbnail.emitted = null;
                slot.modal.emitted = null;
            };
        } else {
            for (store.delete_ids[0..store.delete_count]) |image_id|
                written += try kitty.writeDeleteImage(writer, image_id);
            store.delete_count = 0;
        }

        for (&store.slots, 0..) |*maybe_slot, index| {
            const slot = if (maybe_slot.*) |*value| value else continue;
            const wanted = slot.thumbnail.wanted() or slot.modal.wanted();
            if (!wanted or !slot.image_dirty) {
                continue;
            }
            const progress = try kitty.writePngTransmissionChunks(writer, .{
                .external_id = slot.image_id,
                .png = slot.png,
                .start_offset = 0,
                .budget = kitty.transmission_budget_per_frame,
            });
            written += progress.written;
            slot.transfer_offset = progress.offset;
            if (progress.offset != slot.png.len) {
                store.partial = @intCast(index);
                return written;
            }
            slot.transfer_offset = 0;
            slot.image_dirty = false;
            slot.image_emitted = true;
            break;
        }

        for (&store.slots) |*maybe_slot| {
            const slot = if (maybe_slot.*) |*value| value else continue;
            if (!slot.image_emitted) {
                continue;
            }
            written += try slot.thumbnail.write(writer, slot.image_id);
            written += try slot.modal.write(writer, slot.image_id);
        }
        return written;
    }

    fn fitPlacement(store: *const Store, slot: *const Slot, area: ui.Rect) ?kitty.OutputPlacement {
        if (area.isEmpty()) {
            return null;
        }
        const max_width_px = @as(u64, area.w) * store.cell_width;
        const max_height_px = @as(u64, area.h) * store.cell_height;
        var columns: u64 = area.w;
        const height_at_full_width = std.math.divCeil(
            u64,
            max_width_px * slot.height,
            slot.width,
        ) catch return null;
        var rows = std.math.divCeil(u64, height_at_full_width, store.cell_height) catch return null;
        if (rows > area.h) {
            rows = area.h;
            const width_at_full_height = std.math.divCeil(
                u64,
                max_height_px * slot.width,
                slot.height,
            ) catch return null;
            columns = std.math.divCeil(u64, width_at_full_height, store.cell_width) catch return null;
        }
        columns = std.math.clamp(columns, 1, area.w);
        rows = std.math.clamp(rows, 1, area.h);
        return .{
            .column = area.x + @as(u16, @intCast((area.w - columns) / 2)),
            .row = area.y + @as(u16, @intCast((area.h - rows) / 2)),
            .offset_x = 0,
            .offset_y = 0,
            .source_x = 0,
            .source_y = 0,
            .source_width = slot.width,
            .source_height = slot.height,
            .columns = @intCast(columns),
            .rows = @intCast(rows),
        };
    }

    fn visibleCount(store: *const Store) usize {
        var count: usize = 0;
        for (store.slots) |maybe_slot| if (maybe_slot) |slot| {
            count += @intFromBool(store.slotVisible(&slot));
        };
        return count;
    }

    fn slotVisible(store: *const Store, slot: *const Slot) bool {
        if (slot.retire_pending) {
            return false;
        }
        const target = store.active_target orelse return false;
        return std.meta.eql(target, slot.target);
    }

    fn find(store: *Store, id: Id) ?*Slot {
        for (&store.slots) |*maybe_slot| if (maybe_slot.*) |*slot| {
            if (slot.id == id) {
                return slot;
            }
        };
        return null;
    }

    fn findConst(store: *const Store, id: Id) ?*const Slot {
        for (&store.slots) |*maybe_slot| if (maybe_slot.*) |*slot| {
            if (slot.id == id) {
                return slot;
            }
        };
        return null;
    }

    fn freeIndex(store: *const Store) ?usize {
        for (store.slots, 0..) |slot, index| if (slot == null) return index;
        return null;
    }

    fn allocateHostId(store: *Store) !u32 {
        if (store.next_host_id == 0 or store.next_host_id > max_host_ids) {
            return error.AttachmentHostIdExhausted;
        }
        const result = store.next_host_id;
        store.next_host_id += 1;
        return result;
    }

    fn evictOldest(store: *Store) ?void {
        var oldest_index: ?usize = null;
        var oldest: u64 = std.math.maxInt(u64);
        for (store.slots, 0..) |maybe_slot, index| if (maybe_slot) |slot| {
            const value = @intFromEnum(slot.id);
            if (value < oldest) {
                oldest = value;
                oldest_index = index;
            }
        };
        store.removeAt(oldest_index orelse return null);
        return {};
    }

    fn removeAt(store: *Store, index: usize) void {
        const slot = &store.slots[index].?;
        if (store.partial != null and store.partial.? == index) {
            store.cancelPartial();
        }
        if (slot.image_emitted or slot.transfer_offset != 0) {
            store.queueDelete(slot.image_id);
        }
        store.freeSlot(&store.slots[index]);
    }

    fn retireAt(store: *Store, index: usize) void {
        const slot = &store.slots[index].?;
        if (store.partial != null and store.partial.? == index) {
            store.cancelPartial();
        }
        if (slot.image_emitted or slot.transfer_offset != 0) {
            store.queueDelete(slot.image_id);
        }
        slot.thumbnail.desired = null;
        slot.modal.desired = null;
        slot.retire_pending = true;
    }

    fn cancelPartial(store: *Store) void {
        const index = store.partial orelse return;
        if (store.slots[index]) |*slot| {
            slot.transfer_offset = 0;
            slot.image_dirty = true;
            store.queueDelete(slot.image_id);
        }
        store.partial = null;
        store.abort_pending = true;
    }

    fn queueDelete(store: *Store, image_id: u32) void {
        if (store.delete_all_pending) {
            return;
        }
        for (store.delete_ids[0..store.delete_count]) |queued|
            if (queued == image_id) return;
        if (store.delete_count == store.delete_ids.len) {
            store.delete_all_pending = true;
            return;
        }
        store.delete_ids[store.delete_count] = image_id;
        store.delete_count += 1;
    }

    fn freeSlot(store: *Store, maybe_slot: *?Slot) void {
        if (maybe_slot.*) |*slot| {
            store.total_bytes -= slot.png.len;
            std.crypto.secureZero(u8, slot.png);
            store.gpa.free(slot.png);
        }
        maybe_slot.* = null;
    }
};

const MarkerPosition = struct {
    number: u16,
    start: u16,
    end: u16,
    y: u16,
};

fn snapshotOrdinal(snapshot: *const Snapshot, id: Id) ?u8 {
    for (snapshot.slice(), 0..) |item, index| {
        if (item.id == id) {
            return @intCast(index);
        }
    }

    return null;
}

fn planPlaceholderRemoval(slot: *const Slot, ordinal: u8, screen: MarkerScreen) ?MarkerRemoval {
    const marker_number = slot.markerNumber() orelse @as(u16, ordinal) + 1;
    if (!screen.cursor.visible) {
        return null;
    }

    const marker = findMarker(screen.buffer, marker_number, screen.cursor) orelse return null;
    if (marker.y != screen.cursor.y) {
        return null;
    }

    if (screen.cursor.x >= marker.end) {
        const steps = atomicSteps(screen.buffer, marker.y, .{
            .from = marker.end,
            .to = screen.cursor.x,
        }) orelse return null;

        return .{ .direction = .left, .steps = steps, .deletion = .backward };
    }

    const steps = atomicSteps(screen.buffer, marker.y, .{
        .from = screen.cursor.x,
        .to = marker.start,
    }) orelse return null;

    return .{ .direction = .right, .steps = steps, .deletion = .forward };
}

/// Pi's cursor must share a row with the path's end or start; steps across a
/// wrapped row cannot be counted from cells alone.
fn planPathRemoval(slot: *const Slot, screen: MarkerScreen) ?MarkerRemoval {
    const uuid = slot.markerPath() orelse return null;
    const marker = path_marker.find(screen.buffer, uuid) orelse return null;
    const cells = marker.cells orelse return null;
    const path_screen = pathScreen(screen);
    if (path_marker.cursorOnRow(path_screen, marker.end.y)) |cursor_x| {
        if (cursor_x >= marker.end.x) {
            const steps = path_marker.stepsOnRow(screen.buffer, marker.end.y, .{
                .from = marker.end.x,
                .to = cursor_x,
            }) orelse return null;

            return .{ .direction = .left, .steps = steps, .deletion = .backward, .deletions = cells };
        }
    }
    if (path_marker.cursorOnRow(path_screen, marker.start.y)) |cursor_x| {
        if (cursor_x <= marker.start.x) {
            const steps = path_marker.stepsOnRow(screen.buffer, marker.start.y, .{
                .from = cursor_x,
                .to = marker.start.x,
            }) orelse return null;

            return .{ .direction = .right, .steps = steps, .deletion = .forward, .deletions = cells };
        }
    }

    return null;
}

fn pathTouchesCursor(uuid: path_marker.Uuid, screen: MarkerScreen, deletion: MarkerDeletion) bool {
    const marker = path_marker.find(screen.buffer, uuid) orelse return false;

    return markerCursorTouches(marker, screen, deletion);
}

fn markerCursorTouches(marker: path_marker.Marker, screen: MarkerScreen, deletion: MarkerDeletion) bool {
    return switch (deletion) {
        .backward => path_marker.cursorAt(pathScreen(screen), marker.end),
        .forward => path_marker.cursorAt(pathScreen(screen), marker.start),
    };
}

fn pathScreen(screen: MarkerScreen) path_marker.Screen {
    return .{ .buffer = screen.buffer, .cursor = screen.cursor };
}

/// Pairs the oldest unpaired Pi preview with the oldest unclaimed path among
/// the newest ones on screen, mirroring how Claude's numbers are paired.
fn pathForNextUnpaired(store: *const Store, target: Target, buffer: *const ui.Buffer) ?path_marker.Uuid {
    var found: [max_items * 2]path_marker.Marker = undefined;
    const count = path_marker.collect(buffer, &found);
    var candidates: [max_items * 2]path_marker.Uuid = undefined;
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

fn unpairedPathCount(store: *const Store, target: Target) u8 {
    var count: u8 = 0;
    for (store.slots) |maybe_slot| {
        const slot = maybe_slot orelse continue;
        if (slot.owns(target) and slot.marker_policy == .pasted_path and slot.marker == null) {
            count += 1;
        }
    }

    return count;
}

fn findMarker(buffer: *const ui.Buffer, number: u16, cursor: schema.frame.Cursor) ?MarkerPosition {
    if (number == 0 or buffer.w < minimum_marker_width) {
        return null;
    }

    var best: ?MarkerPosition = null;
    var best_distance: u32 = std.math.maxInt(u32);
    var y: u16 = 0;
    while (y < buffer.h) : (y += 1) {
        var x: u16 = 0;
        while (x <= buffer.w -| minimum_marker_width) : (x += 1) {
            const candidate = parseMarker(buffer, x, y) orelse continue;
            if (candidate.number != number) {
                continue;
            }

            const row_distance = if (candidate.y > cursor.y) candidate.y - cursor.y else cursor.y - candidate.y;
            const column_distance = if (candidate.end > cursor.x) candidate.end - cursor.x else cursor.x - candidate.end;
            const distance = @as(u32, row_distance) * (@as(u32, buffer.w) + 1) + column_distance;
            if (distance < best_distance) {
                best = candidate;
                best_distance = distance;
            }
        }
    }

    return best;
}

fn markerForNextUnpaired(store: *const Store, target: Target, buffer: *const ui.Buffer) ?u16 {
    if (buffer.w < minimum_marker_width) {
        return null;
    }

    var candidates: [max_items]u16 = @splat(0);
    var candidate_count: u8 = 0;
    var y: u16 = 0;
    while (y < buffer.h) : (y += 1) {
        var x: u16 = 0;
        while (x <= buffer.w -| minimum_marker_width) : (x += 1) {
            const marker = parseMarker(buffer, x, y) orelse continue;
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
    }

    const unpaired = unpairedStableCount(store, target);
    if (unpaired == 0 or candidate_count < unpaired) {
        return null;
    }

    return candidates[unpaired - 1];
}

fn unpairedStableCount(store: *const Store, target: Target) u8 {
    var count: u8 = 0;
    for (store.slots) |maybe_slot| {
        const slot = maybe_slot orelse continue;
        if (slot.owns(target) and slot.marker_policy == .stable_number and slot.marker == null) {
            count += 1;
        }
    }

    return count;
}

fn markerNumberClaimed(store: *const Store, target: Target, number: u16) bool {
    for (store.slots) |maybe_slot| {
        const slot = maybe_slot orelse continue;
        if (slot.owns(target) and slot.markerNumber() == number) {
            return true;
        }
    }

    return false;
}

fn markerPresent(buffer: *const ui.Buffer, number: u16) bool {
    if (buffer.w < minimum_marker_width) {
        return false;
    }

    var y: u16 = 0;
    while (y < buffer.h) : (y += 1) {
        var x: u16 = 0;
        while (x <= buffer.w -| minimum_marker_width) : (x += 1) {
            const marker = parseMarker(buffer, x, y) orelse continue;
            if (marker.number == number) {
                return true;
            }
        }
    }

    return false;
}

const MarkerBoundary = struct {
    ordinal: u16,
    cursor: schema.frame.Cursor,
    deletion: MarkerDeletion,
};

fn markerTouchesCursor(buffer: *const ui.Buffer, boundary: MarkerBoundary) bool {
    if (boundary.cursor.y >= buffer.h or boundary.ordinal == 0 or
        buffer.w < minimum_marker_width)
    {
        return false;
    }

    var x: u16 = 0;
    while (x <= buffer.w - minimum_marker_width) : (x += 1) {
        const marker = parseMarker(buffer, x, boundary.cursor.y) orelse continue;
        if (marker.number != boundary.ordinal) {
            continue;
        }

        const matches = switch (boundary.deletion) {
            .backward => marker.end == boundary.cursor.x,
            .forward => marker.start == boundary.cursor.x,
        };
        if (matches) {
            return true;
        }
    }

    return false;
}

fn parseMarker(buffer: *const ui.Buffer, x: u16, y: u16) ?MarkerPosition {
    if (y >= buffer.h or x > buffer.w -| minimum_marker_width) {
        return null;
    }

    for (marker_prefix, 0..) |expected, offset| {
        const cell = buffer.cells[@as(usize, y) * buffer.w + x + offset];
        if (cell.width == 0 or cell.text().len != 1 or cell.text()[0] != expected) {
            return null;
        }
    }

    var number: u16 = 0;
    var at = x + marker_prefix_width;
    while (at < buffer.w) : (at += 1) {
        const cell = buffer.cells[@as(usize, y) * buffer.w + at];
        if (cell.width == 0 or cell.text().len != 1) {
            return null;
        }
        const byte = cell.text()[0];
        if (byte == ']') {
            if (at == x + marker_prefix_width or number == 0) {
                return null;
            }

            return .{ .number = number, .start = x, .end = at + 1, .y = y };
        }
        if (byte < '0' or byte > '9') {
            return null;
        }

        number = std.math.mul(u16, number, 10) catch return null;
        number = std.math.add(u16, number, byte - '0') catch return null;
    }

    return null;
}

fn markerWidthAt(buffer: *const ui.Buffer, x: u16, y: u16) u16 {
    const marker = parseMarker(buffer, x, y) orelse return 0;

    return marker.end - marker.start;
}

fn atomicSteps(buffer: *const ui.Buffer, y: u16, span: path_marker.Span) ?u8 {
    if (span.from > span.to or span.to > buffer.w) {
        return null;
    }

    var steps: u16 = 0;
    var x = span.from;
    while (x < span.to) {
        const width = markerWidthAt(buffer, x, y);
        if (width != 0 and x + width <= span.to) {
            steps += 1;
            x += width;
        } else {
            const cell = buffer.cells[@as(usize, y) * buffer.w + x];
            steps += @intFromBool(cell.width != 0);
            x += 1;
        }
        if (steps > max_marker_navigation_steps) {
            return null;
        }
    }

    return @intCast(steps);
}

fn optionalTargetEql(a: ?Target, b: ?Target) bool {
    if (a == null or b == null) {
        return a == null and b == null;
    }
    return std.meta.eql(a.?, b.?);
}

fn optionalPlacementEql(a: ?kitty.OutputPlacement, b: ?kitty.OutputPlacement) bool {
    if (a == null or b == null) {
        return a == null and b == null;
    }
    return std.meta.eql(a.?, b.?);
}

pub fn captureClipboard(gpa: std.mem.Allocator, request: CaptureRequest, orphan: *?*Capture) !*Capture {
    try request.target.validate();
    std.debug.assert(orphan.* == null);
    const image = try readClipboardPng(gpa);
    errdefer {
        std.crypto.secureZero(u8, image.png);
        gpa.free(image.png);
    }
    const capture = try gpa.create(Capture);
    capture.* = .{
        .request = request,
        .png = image.png,
        .width = image.width,
        .height = image.height,
    };
    orphan.* = capture;
    return capture;
}

const ClipboardImage = struct {
    png: []u8,
    width: u32,
    height: u32,
};

fn readClipboardPng(gpa: std.mem.Allocator) !ClipboardImage {
    if (comptime builtin.os.tag != .macos) {
        return error.ClipboardImageUnsupported;
    }

    var bytes: ?[*]u8 = null;
    var len: usize = 0;
    var width: u32 = 0;
    var height: u32 = 0;
    const result = telar_macos_clipboard_copy_png(
        &bytes,
        &len,
        &width,
        &height,
        max_source_bytes,
        max_png_bytes,
        max_pixels,
    );
    defer if (bytes) |value| {
        if (len <= max_png_bytes) {
            std.crypto.secureZero(u8, value[0..len]);
        }
        std.c.free(@ptrCast(value));
    };
    switch (result) {
        0 => {},
        1 => return error.NoImageOnClipboard,
        2 => return error.ClipboardImageTooLarge,
        else => return error.ClipboardReadFailed,
    }
    const source = bytes orelse return error.ClipboardReadFailed;
    if (len == 0 or len > max_png_bytes or width == 0 or height == 0) {
        return error.InvalidClipboardImage;
    }
    const pixels = std.math.mul(u64, width, height) catch
        return error.ClipboardImageTooLarge;
    if (pixels > max_pixels) {
        return error.ClipboardImageTooLarge;
    }
    const png = try gpa.alloc(u8, len);
    @memcpy(png, source[0..len]);
    return .{ .png = png, .width = width, .height = height };
}

extern fn telar_macos_clipboard_copy_png(bytes: *?[*]u8, len: *usize, width: *u32, height: *u32, max_source_bytes_value: usize, max_png_bytes_value: usize, max_pixels_value: u64) c_int;

test {
    _ = path_marker;
}

test "capture resources release one completed worker result" {
    var resources: CaptureResources = .{};
    const request: CaptureRequest = .{
        .target = .{
            .pane_id = @enumFromInt(7),
            .pane_generation = 3,
        },
        .sequence = 1,
    };
    const capture = try std.testing.allocator.create(Capture);
    capture.* = .{
        .request = request,
        .png = try std.testing.allocator.dupe(u8, "png"),
        .width = 1,
        .height = 1,
    };
    resources.orphan = capture;

    try std.testing.expect(resources.take(capture) == capture);
    capture.deinit(std.testing.allocator);
    try std.testing.expect(resources.orphan == null);
}

test "capture resources free a cancelled worker result" {
    var resources: CaptureResources = .{};
    const request: CaptureRequest = .{
        .target = .{
            .pane_id = @enumFromInt(9),
            .pane_generation = 4,
        },
        .sequence = 1,
    };
    const capture = try std.testing.allocator.create(Capture);
    capture.* = .{
        .request = request,
        .png = try std.testing.allocator.dupe(u8, "private image"),
        .width = 2,
        .height = 2,
    };
    resources.orphan = capture;
    resources.deinit(std.testing.allocator);

    try std.testing.expect(resources.orphan == null);
}

fn testCapture(gpa: std.mem.Allocator, request: CaptureRequest, bytes: []const u8) !*Capture {
    const capture = try gpa.create(Capture);
    errdefer gpa.destroy(capture);
    capture.* = .{
        .request = request,
        .png = try gpa.dupe(u8, bytes),
        .width = 20,
        .height = 10,
    };
    return capture;
}

fn testRequest(sequence: u64, target: Target) CaptureRequest {
    return .{
        .target = target,
        .sequence = sequence,
    };
}

test "preview store is bounded and keeps captures scoped to their agent generation" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const target: Target = .{ .pane_id = @enumFromInt(7), .pane_generation = 3 };
    try std.testing.expect(store.setTarget(target).changed);
    for (1..6) |sequence| {
        try store.adopt(try testCapture(
            std.testing.allocator,
            testRequest(sequence, target),
            "png",
        ));
    }

    const snapshot = store.snapshot();
    try std.testing.expectEqual(@as(u8, max_items), snapshot.len);
    try std.testing.expectEqual(@as(u64, 2), @intFromEnum(snapshot.items[0].id));
    try std.testing.expectEqual(@as(u64, 5), @intFromEnum(snapshot.items[3].id));
    try std.testing.expectEqual(@as(usize, max_items * 3), store.retainedBytes());
    try std.testing.expectEqual(@as(u64, 5), store.ingressVersion());

    const other: Target = .{ .pane_id = target.pane_id, .pane_generation = 4 };
    const changed = store.setTarget(other);
    try std.testing.expect(changed.changed);
    try std.testing.expect(changed.layout_changed);
    try std.testing.expectEqual(@as(u8, 0), store.snapshot().len);
}

test "switching visible previews between panes changes their layout owner" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const first: Target = .{ .pane_id = @enumFromInt(7), .pane_generation = 3 };
    const second: Target = .{ .pane_id = @enumFromInt(8), .pane_generation = 4 };
    _ = store.setTarget(first);
    try store.adopt(try testCapture(std.testing.allocator, testRequest(1, first), "first"));
    try store.adopt(try testCapture(std.testing.allocator, testRequest(2, second), "second"));

    const changed = store.setTarget(second);

    try std.testing.expect(changed.changed);
    try std.testing.expect(changed.layout_changed);
    try std.testing.expectEqual(second, store.visibleTarget().?);
}

test "marker removal keeps preview order aligned with atomic child placeholders" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const target: Target = .{ .pane_id = @enumFromInt(8), .pane_generation = 4 };
    _ = store.setTarget(target);
    try store.adopt(try testCapture(std.testing.allocator, testRequest(1, target), "first"));
    try store.adopt(try testCapture(std.testing.allocator, testRequest(2, target), "second"));
    var buffer = try ui.Buffer.init(std.testing.allocator, 64, 2);
    defer buffer.deinit();
    const prompt = "> [Image #1]xx[Image #2]tail";
    const cursor_x = buffer.writeText(buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = prompt, .style = .{} });
    const screen: MarkerScreen = .{
        .buffer = &buffer,
        .cursor = .{ .visible = true, .x = cursor_x, .y = 0 },
    };

    const removal = store.planMarkerRemoval(@enumFromInt(1), screen).?;

    try std.testing.expect(removal.direction == .left);
    try std.testing.expectEqual(@as(u8, 7), removal.steps);
    try std.testing.expect(removal.deletion == .backward);

    const second_end: u16 = 2 + minimum_marker_width + 2 + minimum_marker_width;
    try std.testing.expectEqual(
        @as(Id, @enumFromInt(2)),
        store.idAtMarkerDeletion(.{
            .buffer = &buffer,
            .cursor = .{ .visible = true, .x = second_end, .y = 0 },
        }, .backward).?,
    );
    try std.testing.expectEqual(
        @as(Id, @enumFromInt(1)),
        store.idAtMarkerDeletion(.{
            .buffer = &buffer,
            .cursor = .{ .visible = true, .x = 2, .y = 0 },
        }, .forward).?,
    );

    buffer.clear(.{});
    const pending_cursor = buffer.writeText(buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "> [Image #1][Image #2][Image #3]", .style = .{} });
    try std.testing.expect(store.pendingMarkerAtDeletion(.{
        .buffer = &buffer,
        .cursor = .{ .visible = true, .x = pending_cursor, .y = 0 },
    }, .{ .deletion = .backward }));
}

test "Claude previews retain stable marker numbers across attachment deletion" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const target: Target = .{ .pane_id = @enumFromInt(8), .pane_generation = 4 };
    _ = store.setTarget(target);
    const first = try testCapture(std.testing.allocator, testRequest(1, target), "first");
    first.request.marker_policy = .stable_number;
    try store.adopt(first);
    const second = try testCapture(std.testing.allocator, testRequest(2, target), "second");
    second.request.marker_policy = .stable_number;
    try store.adopt(second);
    var buffer = try ui.Buffer.init(std.testing.allocator, 64, 2);
    defer buffer.deinit();
    var cursor_x = buffer.writeText(buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "> [Image #7][Image #12]", .style = .{} });

    try std.testing.expectEqual(@as(u8, 0), store.reconcileMarkers(target, .{
        .buffer = &buffer,
        .cursor = .{ .visible = true, .x = cursor_x, .y = 0 },
    }));
    const removal = store.planMarkerRemoval(@enumFromInt(1), .{
        .buffer = &buffer,
        .cursor = .{ .visible = true, .x = cursor_x, .y = 0 },
    }).?;
    try std.testing.expectEqual(@as(u8, 1), removal.steps);

    buffer.clear(.{});
    cursor_x = buffer.writeText(buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "> [Image #12]", .style = .{} });
    store.expectMarkerDeletion(target);
    try std.testing.expectEqual(@as(u8, 1), store.reconcileMarkers(target, .{
        .buffer = &buffer,
        .cursor = .{ .visible = true, .x = cursor_x, .y = 0 },
    }));

    const remaining = store.snapshot();
    try std.testing.expectEqual(@as(u8, 1), remaining.len);
    try std.testing.expectEqual(@as(u64, 2), @intFromEnum(remaining.items[0].id));
}

const pi_uuid = "3f2a9c1e-7b4d-4e8f-9a0b-1c2d3e4f5a6b";
const pi_second_uuid = "0a1b2c3d-4e5f-4a6b-8c7d-8e9f0a1b2c3d";
const pi_path = "/var/folders/8x/abc/T/pi-clipboard-" ++ pi_uuid ++ ".png";
const pi_second_path = "/var/folders/8x/abc/T/pi-clipboard-" ++ pi_second_uuid ++ ".png";

fn adoptPiCapture(store: *Store, sequence: u64, target: Target) !void {
    const capture = try testCapture(std.testing.allocator, testRequest(sequence, target), "pi");
    capture.request.marker_policy = .pasted_path;
    try store.adopt(capture);
}

fn writePiCursor(buffer: *ui.Buffer, x: u16, y: u16) void {
    buffer.setCell(.{ .x = x, .y = y }, .{ .text = " ", .width = 1, .style = .{ .flags = .{ .inverse = true } } });
}

test "Pi previews pair with pasted paths and are closed by deleting the whole path" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const target: Target = .{ .pane_id = @enumFromInt(8), .pane_generation = 4 };
    _ = store.setTarget(target);
    try adoptPiCapture(&store, 1, target);
    try adoptPiCapture(&store, 2, target);
    var buffer = try ui.Buffer.init(std.testing.allocator, 200, 2);
    defer buffer.deinit();
    const prompt = "see " ++ pi_path ++ " and " ++ pi_second_path;
    const cursor_x = buffer.writeText(buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = prompt, .style = .{} });
    writePiCursor(&buffer, cursor_x, 0);
    const hidden: schema.frame.Cursor = .{ .visible = false, .x = 0, .y = 0 };

    try std.testing.expectEqual(@as(u8, 0), store.reconcileMarkers(target, .{ .buffer = &buffer, .cursor = hidden }));

    const removal = store.planMarkerRemoval(@enumFromInt(1), .{ .buffer = &buffer, .cursor = hidden }).?;
    try std.testing.expect(removal.direction == .left);
    try std.testing.expectEqual(@as(u8, " and ".len + pi_second_path.len), removal.steps);
    try std.testing.expect(removal.deletion == .backward);
    try std.testing.expectEqual(@as(u8, pi_path.len), removal.deletions);

    const second = store.planMarkerRemoval(@enumFromInt(2), .{ .buffer = &buffer, .cursor = hidden }).?;
    try std.testing.expectEqual(@as(u8, 0), second.steps);
    try std.testing.expectEqual(@as(u8, pi_second_path.len), second.deletions);

    try std.testing.expectEqual(
        @as(Id, @enumFromInt(2)),
        store.idAtMarkerDeletion(.{ .buffer = &buffer, .cursor = hidden }, .backward).?,
    );
    try std.testing.expect(store.idAtMarkerDeletion(.{ .buffer = &buffer, .cursor = hidden }, .forward) == null);
    try std.testing.expectEqual(
        @as(Id, @enumFromInt(1)),
        store.idAtMarkerDeletion(.{ .buffer = &buffer, .cursor = .{ .visible = true, .x = 4, .y = 0 } }, .forward).?,
    );
}

test "a Pi path removed by any editor command retires its preview within the watched frames" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const target: Target = .{ .pane_id = @enumFromInt(8), .pane_generation = 4 };
    _ = store.setTarget(target);
    try adoptPiCapture(&store, 1, target);
    var buffer = try ui.Buffer.init(std.testing.allocator, 40, 4);
    defer buffer.deinit();
    var x: u16 = 0;
    var y: u16 = 0;
    for (pi_path) |byte| {
        if (x == buffer.w - 1) {
            x = 0;
            y += 1;
        }
        buffer.setCell(.{ .x = x, .y = y }, .{ .text = &.{byte}, .width = 1, .style = .{} });
        x += 1;
    }
    const hidden: schema.frame.Cursor = .{ .visible = false, .x = 0, .y = 0 };
    const screen: MarkerScreen = .{ .buffer = &buffer, .cursor = hidden };

    try std.testing.expectEqual(@as(u8, 0), store.reconcileMarkers(target, screen));
    store.expectMarkerDeletion(target);
    try std.testing.expectEqual(@as(u8, 0), store.reconcileMarkers(target, screen));
    try std.testing.expect(store.marker_deletion_pending != null);

    buffer.clear(.{});
    try std.testing.expectEqual(@as(u8, 1), store.reconcileMarkers(target, screen));
    try std.testing.expectEqual(@as(u8, 0), store.snapshot().len);
    try std.testing.expect(store.marker_deletion_pending == null);
}

test "a deletion watch expires after the bounded frame count" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const target: Target = .{ .pane_id = @enumFromInt(8), .pane_generation = 4 };
    _ = store.setTarget(target);
    try adoptPiCapture(&store, 1, target);
    var buffer = try ui.Buffer.init(std.testing.allocator, 120, 1);
    defer buffer.deinit();
    _ = buffer.writeText(buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = pi_path, .style = .{} });
    const screen: MarkerScreen = .{ .buffer = &buffer, .cursor = .{ .visible = false, .x = 0, .y = 0 } };
    _ = store.reconcileMarkers(target, screen);

    store.expectMarkerDeletion(target);
    for (0..deletion_watch_frames) |_| {
        try std.testing.expectEqual(@as(u8, 0), store.reconcileMarkers(target, screen));
    }

    try std.testing.expect(store.marker_deletion_pending == null);
    buffer.clear(.{});
    try std.testing.expectEqual(@as(u8, 0), store.reconcileMarkers(target, screen));
    try std.testing.expectEqual(@as(u8, 1), store.snapshot().len);
}

test "deleting a Pi path whose capture is still in flight is reported" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const target: Target = .{ .pane_id = @enumFromInt(8), .pane_generation = 4 };
    _ = store.setTarget(target);
    var buffer = try ui.Buffer.init(std.testing.allocator, 120, 1);
    defer buffer.deinit();
    const cursor_x = buffer.writeText(buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = pi_path, .style = .{} });
    writePiCursor(&buffer, cursor_x, 0);
    const screen: MarkerScreen = .{ .buffer = &buffer, .cursor = .{ .visible = false, .x = 0, .y = 0 } };

    try std.testing.expect(store.pendingMarkerAtDeletion(screen, .{ .deletion = .backward, .policy = .pasted_path }));
    try std.testing.expect(!store.pendingMarkerAtDeletion(screen, .{ .deletion = .forward, .policy = .pasted_path }));
    try std.testing.expect(!store.pendingMarkerAtDeletion(screen, .{ .deletion = .backward }));
}

test "submitted prompt retires only previews owned by its target" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const submitted: Target = .{ .pane_id = @enumFromInt(8), .pane_generation = 4 };
    const other: Target = .{ .pane_id = @enumFromInt(9), .pane_generation = 2 };
    _ = store.setTarget(submitted);
    try store.adopt(try testCapture(std.testing.allocator, testRequest(1, submitted), "first"));
    try store.adopt(try testCapture(std.testing.allocator, testRequest(2, submitted), "second"));
    try store.adopt(try testCapture(std.testing.allocator, testRequest(3, other), "other"));

    try std.testing.expectEqual(@as(u8, 2), store.removeVisible(submitted));
    try std.testing.expectEqual(@as(u8, 0), store.snapshot().len);
    try std.testing.expect(store.setTarget(other).layout_changed);
    try std.testing.expectEqual(@as(u8, 1), store.snapshot().len);
}

test "preview store emits PNG and client-owned z-index placements" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const target: Target = .{ .pane_id = @enumFromInt(8), .pane_generation = 2 };
    _ = store.setTarget(target);
    try store.adopt(try testCapture(
        std.testing.allocator,
        testRequest(1, target),
        "encoded png",
    ));
    _ = store.configure(.{ .support = .supported, .cell_width = 10, .cell_height = 20 });
    var plan: Plan = .{ .thumbnail_count = 1 };
    plan.thumbnails[0] = .{
        .id = @enumFromInt(1),
        .area = .{ .x = 2, .y = 3, .w = 10, .h = 4 },
    };
    store.prepare(plan);

    var output: [8192]u8 = undefined;
    var writer = Io.Writer.fixed(&output);
    _ = try store.write(&writer);
    const bytes = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, bytes, "a=t,f=100,t=d") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "z=1500") != null);
    try std.testing.expect(!store.damaged());
}

test "dismissal defers private buffer wiping to the media path" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const target: Target = .{ .pane_id = @enumFromInt(9), .pane_generation = 2 };
    _ = store.setTarget(target);
    try store.adopt(try testCapture(
        std.testing.allocator,
        testRequest(1, target),
        "private png",
    ));
    try std.testing.expect(store.remove(@enumFromInt(1)));
    try std.testing.expect(store.cleanupPending());
    try std.testing.expectEqual(@as(usize, 11), store.retainedBytes());
    try std.testing.expectEqual(@as(u8, 0), store.snapshot().len);
    store.reapRetired();
    try std.testing.expect(!store.cleanupPending());
    try std.testing.expectEqual(@as(usize, 0), store.retainedBytes());
}

test "cancelling a dismissed PNG transfer owns the graphics stream until abort" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const target: Target = .{ .pane_id = @enumFromInt(10), .pane_generation = 2 };
    _ = store.setTarget(target);
    const large = try std.testing.allocator.alloc(u8, kitty.transmission_budget_per_frame);
    defer std.testing.allocator.free(large);
    @memset(large, 0xaa);
    try store.adopt(try testCapture(
        std.testing.allocator,
        testRequest(1, target),
        large,
    ));
    _ = store.configure(.{ .support = .supported, .cell_width = 10, .cell_height = 20 });
    var plan: Plan = .{ .thumbnail_count = 1 };
    plan.thumbnails[0] = .{
        .id = @enumFromInt(1),
        .area = .{ .w = 10, .h = 4 },
    };
    store.prepare(plan);
    var discarded: Io.Writer.Discarding = .init(&.{});
    _ = try store.write(&discarded.writer);
    try std.testing.expect(store.transferInProgress());
    try std.testing.expect(store.remove(@enumFromInt(1)));
    try std.testing.expect(store.transferInProgress());
    store.reapRetired();

    var output: [1024]u8 = undefined;
    var writer = Io.Writer.fixed(&output);
    _ = try store.write(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b_Gm=0;") != null);
    try std.testing.expect(!store.transferInProgress());
}
