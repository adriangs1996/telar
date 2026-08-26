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

const Io = std.Io;
const schema = core.schema;
const ui = core.ui;

pub const max_items: usize = 4;
pub const max_source_bytes: usize = 32 * 1024 * 1024;
pub const max_png_bytes: usize = 16 * 1024 * 1024;
pub const max_pixels: u64 = 16 * 1024 * 1024;
pub const max_retained_bytes: usize = 32 * 1024 * 1024;

pub fn platformSupported() bool {
    return builtin.os.tag == .macos;
}

pub const Target = struct {
    pane_id: schema.PaneId,
    pane_generation: u64,

    pub fn validate(target: Target) !void {
        if (target.pane_id == .invalid or target.pane_generation == 0)
            return error.InvalidAttachmentTarget;
    }
};

pub const CaptureRequest = struct {
    target: Target,
    sequence: u64,
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

/// One bounded in-flight capture. A second paste still reaches the pane, but
/// its preview is dropped until this worker finishes. `orphan` closes the
/// cancellation race: once a worker allocates a result, client shutdown can
/// always find and free it after cancelling the select tasks.
pub const CaptureState = struct {
    pending: bool = false,
    next_sequence: u64 = 1,
    orphan: ?*Capture = null,

    pub fn begin(state: *CaptureState, target: Target) !?CaptureRequest {
        try target.validate();
        if (state.pending) return null;
        if (state.next_sequence == 0 or state.next_sequence == std.math.maxInt(u64))
            return error.AttachmentSequenceExhausted;
        const request: CaptureRequest = .{
            .target = target,
            .sequence = state.next_sequence,
        };
        state.next_sequence += 1;
        state.pending = true;
        return request;
    }

    pub fn scheduleFailed(state: *CaptureState) void {
        std.debug.assert(state.orphan == null);
        state.pending = false;
    }

    pub fn failed(state: *CaptureState) void {
        std.debug.assert(state.orphan == null);
        state.pending = false;
    }

    pub fn take(state: *CaptureState, capture: *Capture) *Capture {
        std.debug.assert(state.pending);
        std.debug.assert(state.orphan == capture);
        state.orphan = null;
        state.pending = false;
        return capture;
    }

    pub fn deinit(state: *CaptureState, gpa: std.mem.Allocator) void {
        if (state.orphan) |capture| capture.deinit(gpa);
        state.* = .{};
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

const Slot = struct {
    id: Id,
    target: Target,
    png: []u8,
    width: u32,
    height: u32,
    image_id: u32,
    thumbnail_placement_id: u32,
    modal_placement_id: u32,
    image_emitted: bool = false,
    image_dirty: bool = true,
    transfer_offset: usize = 0,
    desired_thumbnail: ?kitty.OutputPlacement = null,
    emitted_thumbnail: ?kitty.OutputPlacement = null,
    desired_modal: ?kitty.OutputPlacement = null,
    emitted_modal: ?kitty.OutputPlacement = null,
    retire_pending: bool = false,
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
    modal: ?Id = null,
    supported: bool = false,
    cell_width: u16 = 0,
    cell_height: u16 = 0,
    total_bytes: usize = 0,
    next_host_id: u32 = 1,
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

    pub fn cleanupPending(store: *const Store) bool {
        for (store.slots) |maybe_slot| if (maybe_slot) |slot|
            if (slot.retire_pending) return true;
        return false;
    }

    /// Runs only from the media event. Large private buffers are never wiped
    /// on the mouse/input path that requested their dismissal.
    pub fn reapRetired(store: *Store) void {
        for (&store.slots) |*maybe_slot| {
            if (maybe_slot.* == null or !maybe_slot.*.?.retire_pending) continue;
            store.freeSlot(maybe_slot);
        }
    }

    pub fn configure(
        store: *Store,
        support: kitty.Support,
        cell_width: u16,
        cell_height: u16,
    ) bool {
        const supported = support == .supported;
        if (store.supported == supported and store.cell_width == cell_width and
            store.cell_height == cell_height) return false;
        if (!supported and store.partial != null) store.cancelPartial();
        store.supported = supported;
        store.cell_width = cell_width;
        store.cell_height = cell_height;
        if (supported) for (&store.slots) |*maybe_slot| {
            if (maybe_slot.*) |*slot| slot.image_dirty = !slot.image_emitted;
        };
        return true;
    }

    /// Returns whether the shelf changed between hidden and visible. That is
    /// the only transition that changes pane geometry.
    pub fn setTarget(store: *Store, target: ?Target) TargetChange {
        const had_items = store.visibleCount() != 0;
        if (optionalTargetEql(store.active_target, target)) return .{};
        store.active_target = target;
        store.modal = null;
        if (store.partial) |index| {
            const slot = &store.slots[index].?;
            if (!store.slotVisible(slot)) store.cancelPartial();
        }
        return .{
            .changed = true,
            .layout_changed = had_items != (store.visibleCount() != 0),
        };
    }

    pub fn hasVisibleItems(store: *const Store) bool {
        return store.visibleCount() != 0;
    }

    pub fn hasModal(store: *const Store) bool {
        return store.modal != null;
    }

    pub fn snapshot(store: *const Store) Snapshot {
        var result: Snapshot = .{ .modal = store.modal };
        for (store.slots) |maybe_slot| if (maybe_slot) |slot| {
            if (!store.slotVisible(&slot)) continue;
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
            if (!found) result.modal = null;
        }
        return result;
    }

    /// Takes ownership of `capture.png` and destroys only the capture shell.
    pub fn adopt(store: *Store, capture: *Capture) !void {
        if (capture.png.len == 0 or capture.png.len > max_png_bytes or
            capture.width == 0 or capture.height == 0)
            return error.InvalidClipboardImage;
        const pixels = std.math.mul(u64, capture.width, capture.height) catch
            return error.ClipboardImageTooLarge;
        if (pixels > max_pixels) return error.ClipboardImageTooLarge;
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
            .thumbnail_placement_id = first_thumbnail_placement_id + host_id,
            .modal_placement_id = first_modal_placement_id + host_id,
        };
        store.total_bytes += png.len;
    }

    pub fn remove(store: *Store, id: Id) bool {
        for (&store.slots, 0..) |*slot, index| {
            if (slot.* == null or slot.*.?.id != id or slot.*.?.retire_pending) continue;
            store.retireAt(index);
            if (store.modal == id) store.modal = null;
            return true;
        }
        return false;
    }

    pub fn openModal(store: *Store, id: Id) bool {
        const slot = store.find(id) orelse return false;
        if (!store.slotVisible(slot)) return false;
        if (store.modal == id) return false;
        store.modal = id;
        return true;
    }

    pub fn closeModal(store: *Store) bool {
        if (store.modal == null) return false;
        store.modal = null;
        return true;
    }

    pub fn prepare(store: *Store, plan: Plan) void {
        for (&store.slots) |*maybe_slot| if (maybe_slot.*) |*slot| {
            slot.desired_thumbnail = null;
            slot.desired_modal = null;
        };
        if (!store.supported or store.cell_width == 0 or store.cell_height == 0) return;
        for (plan.thumbnailSlice()) |item| if (store.find(item.id)) |slot| {
            if (store.slotVisible(slot))
                slot.desired_thumbnail = store.fitPlacement(slot, item.area);
        };
        if (plan.modal) |item| if (store.find(item.id)) |slot| {
            if (store.slotVisible(slot))
                slot.desired_modal = store.fitPlacement(slot, item.area);
        };
    }

    pub fn damaged(store: *const Store) bool {
        if (!store.supported) return false;
        if (store.abort_pending or store.partial != null or store.delete_count != 0 or
            store.delete_all_pending) return true;
        for (store.slots) |maybe_slot| if (maybe_slot) |slot| {
            const wanted = slot.desired_thumbnail != null or slot.desired_modal != null;
            if ((wanted and slot.image_dirty) or
                !optionalPlacementEql(slot.desired_thumbnail, slot.emitted_thumbnail) or
                !optionalPlacementEql(slot.desired_modal, slot.emitted_modal)) return true;
        };
        return false;
    }

    pub fn transferInProgress(store: *const Store) bool {
        return store.partial != null or store.abort_pending;
    }

    pub fn write(store: *Store, writer: *Io.Writer) Io.Writer.Error!usize {
        if (!store.supported or !store.damaged()) return 0;
        var written: usize = 0;
        if (store.abort_pending) {
            written += try kitty.writeTransmissionAbort(writer);
            store.abort_pending = false;
        } else if (store.partial) |index| {
            const slot = &store.slots[index].?;
            const progress = try kitty.writePngTransmissionChunks(
                writer,
                slot.image_id,
                slot.png,
                slot.transfer_offset,
                kitty.transmission_budget_per_frame,
            );
            written += progress.written;
            slot.transfer_offset = progress.offset;
            if (progress.offset != slot.png.len) return written;
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
                slot.emitted_thumbnail = null;
                slot.emitted_modal = null;
            };
        } else {
            for (store.delete_ids[0..store.delete_count]) |image_id|
                written += try kitty.writeDeleteImage(writer, image_id);
            store.delete_count = 0;
        }

        for (&store.slots, 0..) |*maybe_slot, index| {
            const slot = if (maybe_slot.*) |*value| value else continue;
            const wanted = slot.desired_thumbnail != null or slot.desired_modal != null;
            if (!wanted or !slot.image_dirty) continue;
            const progress = try kitty.writePngTransmissionChunks(
                writer,
                slot.image_id,
                slot.png,
                0,
                kitty.transmission_budget_per_frame,
            );
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
            if (!slot.image_emitted) continue;
            written += try store.writePlacementChange(
                writer,
                slot,
                slot.desired_thumbnail,
                &slot.emitted_thumbnail,
                slot.thumbnail_placement_id,
                thumbnail_z,
            );
            written += try store.writePlacementChange(
                writer,
                slot,
                slot.desired_modal,
                &slot.emitted_modal,
                slot.modal_placement_id,
                modal_z,
            );
        }
        return written;
    }

    fn writePlacementChange(
        store: *Store,
        writer: *Io.Writer,
        slot: *Slot,
        desired: ?kitty.OutputPlacement,
        emitted: *?kitty.OutputPlacement,
        placement_id: u32,
        z: i32,
    ) Io.Writer.Error!usize {
        _ = store;
        if (optionalPlacementEql(desired, emitted.*)) return 0;
        var written: usize = 0;
        if (emitted.* != null)
            written += try kitty.writeDeletePlacement(writer, slot.image_id, placement_id);
        if (desired) |placement|
            written += try kitty.writeUiPlacement(writer, slot.image_id, placement_id, placement, z);
        emitted.* = desired;
        return written;
    }

    fn fitPlacement(store: *const Store, slot: *const Slot, area: ui.Rect) ?kitty.OutputPlacement {
        if (area.isEmpty()) return null;
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
        if (slot.retire_pending) return false;
        const target = store.active_target orelse return false;
        return std.meta.eql(target, slot.target);
    }

    fn find(store: *Store, id: Id) ?*Slot {
        for (&store.slots) |*maybe_slot| if (maybe_slot.*) |*slot| {
            if (slot.id == id) return slot;
        };
        return null;
    }

    fn freeIndex(store: *const Store) ?usize {
        for (store.slots, 0..) |slot, index| if (slot == null) return index;
        return null;
    }

    fn allocateHostId(store: *Store) !u32 {
        if (store.next_host_id == 0 or store.next_host_id > max_host_ids)
            return error.AttachmentHostIdExhausted;
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
        if (store.partial != null and store.partial.? == index) store.cancelPartial();
        if (slot.image_emitted or slot.transfer_offset != 0) store.queueDelete(slot.image_id);
        store.freeSlot(&store.slots[index]);
    }

    fn retireAt(store: *Store, index: usize) void {
        const slot = &store.slots[index].?;
        if (store.partial != null and store.partial.? == index) store.cancelPartial();
        if (slot.image_emitted or slot.transfer_offset != 0) store.queueDelete(slot.image_id);
        slot.desired_thumbnail = null;
        slot.desired_modal = null;
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
        if (store.delete_all_pending) return;
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

fn optionalTargetEql(a: ?Target, b: ?Target) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.meta.eql(a.?, b.?);
}

fn optionalPlacementEql(a: ?kitty.OutputPlacement, b: ?kitty.OutputPlacement) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.meta.eql(a.?, b.?);
}

pub fn captureClipboard(
    gpa: std.mem.Allocator,
    request: CaptureRequest,
    orphan: *?*Capture,
) !*Capture {
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
    if (comptime builtin.os.tag != .macos) return error.ClipboardImageUnsupported;

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
        if (len <= max_png_bytes) std.crypto.secureZero(u8, value[0..len]);
        std.c.free(@ptrCast(value));
    };
    switch (result) {
        0 => {},
        1 => return error.NoImageOnClipboard,
        2 => return error.ClipboardImageTooLarge,
        else => return error.ClipboardReadFailed,
    }
    const source = bytes orelse return error.ClipboardReadFailed;
    if (len == 0 or len > max_png_bytes or width == 0 or height == 0)
        return error.InvalidClipboardImage;
    const pixels = std.math.mul(u64, width, height) catch
        return error.ClipboardImageTooLarge;
    if (pixels > max_pixels) return error.ClipboardImageTooLarge;
    const png = try gpa.alloc(u8, len);
    @memcpy(png, source[0..len]);
    return .{ .png = png, .width = width, .height = height };
}

extern fn telar_macos_clipboard_copy_png(
    bytes: *?[*]u8,
    len: *usize,
    width: *u32,
    height: *u32,
    max_source_bytes_value: usize,
    max_png_bytes_value: usize,
    max_pixels_value: u64,
) c_int;

test "capture state admits one worker and releases an adopted result" {
    var state: CaptureState = .{};
    const target: Target = .{
        .pane_id = @enumFromInt(7),
        .pane_generation = 3,
    };
    const first = (try state.begin(target)).?;
    try std.testing.expect((try state.begin(target)) == null);
    try std.testing.expectEqual(@as(u64, 1), first.sequence);

    const capture = try std.testing.allocator.create(Capture);
    capture.* = .{
        .request = first,
        .png = try std.testing.allocator.dupe(u8, "png"),
        .width = 1,
        .height = 1,
    };
    state.orphan = capture;
    try std.testing.expect(state.take(capture) == capture);
    capture.deinit(std.testing.allocator);
    try std.testing.expect(!state.pending);
    try std.testing.expectEqual(@as(u64, 2), state.next_sequence);
}

test "capture state frees a cancelled worker result" {
    var state: CaptureState = .{};
    const request = (try state.begin(.{
        .pane_id = @enumFromInt(9),
        .pane_generation = 4,
    })).?;
    const capture = try std.testing.allocator.create(Capture);
    capture.* = .{
        .request = request,
        .png = try std.testing.allocator.dupe(u8, "private image"),
        .width = 2,
        .height = 2,
    };
    state.orphan = capture;
    state.deinit(std.testing.allocator);
    try std.testing.expect(!state.pending);
}

fn testCapture(
    gpa: std.mem.Allocator,
    sequence: u64,
    target: Target,
    bytes: []const u8,
) !*Capture {
    const capture = try gpa.create(Capture);
    errdefer gpa.destroy(capture);
    capture.* = .{
        .request = .{ .target = target, .sequence = sequence },
        .png = try gpa.dupe(u8, bytes),
        .width = 20,
        .height = 10,
    };
    return capture;
}

test "preview store is bounded and keeps captures scoped to their agent generation" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const target: Target = .{ .pane_id = @enumFromInt(7), .pane_generation = 3 };
    try std.testing.expect(store.setTarget(target).changed);
    for (1..6) |sequence|
        try store.adopt(try testCapture(std.testing.allocator, sequence, target, "png"));

    const snapshot = store.snapshot();
    try std.testing.expectEqual(@as(u8, max_items), snapshot.len);
    try std.testing.expectEqual(@as(u64, 2), @intFromEnum(snapshot.items[0].id));
    try std.testing.expectEqual(@as(u64, 5), @intFromEnum(snapshot.items[3].id));
    try std.testing.expectEqual(@as(usize, max_items * 3), store.retainedBytes());

    const other: Target = .{ .pane_id = target.pane_id, .pane_generation = 4 };
    const changed = store.setTarget(other);
    try std.testing.expect(changed.changed);
    try std.testing.expect(changed.layout_changed);
    try std.testing.expectEqual(@as(u8, 0), store.snapshot().len);
}

test "preview store emits PNG and client-owned z-index placements" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const target: Target = .{ .pane_id = @enumFromInt(8), .pane_generation = 2 };
    _ = store.setTarget(target);
    try store.adopt(try testCapture(std.testing.allocator, 1, target, "encoded png"));
    _ = store.configure(.supported, 10, 20);
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
    try store.adopt(try testCapture(std.testing.allocator, 1, target, "private png"));
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
    try store.adopt(try testCapture(std.testing.allocator, 1, target, large));
    _ = store.configure(.supported, 10, 20);
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
