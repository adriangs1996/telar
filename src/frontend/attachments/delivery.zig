//! Kitty attachment placements and transmission; the shared catalog owns PNGs.
const std = @import("std");
const core = @import("telar-core");
const ui = core.ui;
const Io = std.Io;
const attachments = @import("root.zig");
const kitty = @import("../graphics/root.zig").kitty;
const presentation = @import("presentation.zig");
const PlacementState = presentation.PlacementState;
const Plan = attachments.Plan;
const max_items = attachments.max_items;
pub const Store = @import("telar-client").attachments.Catalog(@This());
const Slot = Store.Slot;
const first_image_id: u32 = 0x90000000;
const first_thumbnail_placement_id: u32 = 0xa0000000;
const first_modal_placement_id: u32 = 0xb0000000;
const max_host_ids: u32 = 0x0fffffff;
const thumbnail_z: i32 = 1500;
const modal_z: i32 = 2000;
pub const State = struct {
    supported: bool = false,
    cell_width: u16 = 0,
    cell_height: u16 = 0,
    next_host_id: u32 = 1,
    partial: ?u8 = null,
    abort_pending: bool = false,
    delete_ids: [max_items * 2]u32 = undefined,
    delete_count: u8 = 0,
    delete_all_pending: bool = false,
};
pub const SlotState = struct {
    image_id: u32,
    thumbnail: PlacementState,
    modal: PlacementState,
    image_emitted: bool = false,
    image_dirty: bool = true,
    transfer_offset: usize = 0,
};
pub fn configure(store: *Store, configuration: kitty.Configuration) bool {
    const supported = configuration.support == .supported;
    if (store.delivery.supported == supported and store.delivery.cell_width == configuration.cell_width and
        store.delivery.cell_height == configuration.cell_height)
    {
        return false;
    }
    if (!supported and store.delivery.partial != null) {
        cancelPartial(store);
    }
    store.delivery.supported = supported;
    store.delivery.cell_width = configuration.cell_width;
    store.delivery.cell_height = configuration.cell_height;
    if (supported) {
        for (&store.slots) |*maybe_slot| {
            if (maybe_slot.*) |*slot| {
                slot.delivery.image_dirty = !slot.delivery.image_emitted;
            }
        }
    }
    return true;
}

pub fn prepare(store: *Store, plan: Plan) void {
    for (&store.slots) |*maybe_slot| if (maybe_slot.*) |*slot| {
        slot.delivery.thumbnail.desired = null;
        slot.delivery.modal.desired = null;
    };
    if (!store.delivery.supported or store.delivery.cell_width == 0 or store.delivery.cell_height == 0) {
        return;
    }
    for (plan.thumbnailSlice()) |item| if (store.find(item.id)) |slot| {
        if (store.slotVisible(slot)) {
            slot.delivery.thumbnail.desired = fitPlacement(store, slot, item.area);
        }
    };
    if (plan.modal) |item| {
        if (store.find(item.id)) |slot| {
            if (store.slotVisible(slot)) {
                slot.delivery.modal.desired = fitPlacement(store, slot, item.area);
            }
        }
    }
}

pub fn damaged(store: *const Store) bool {
    if (!store.delivery.supported) {
        return false;
    }
    if (store.delivery.abort_pending or store.delivery.partial != null or store.delivery.delete_count != 0 or
        store.delivery.delete_all_pending)
    {
        return true;
    }
    for (store.slots) |maybe_slot| if (maybe_slot) |slot| {
        const wanted = slot.delivery.thumbnail.wanted() or slot.delivery.modal.wanted();
        if ((wanted and slot.delivery.image_dirty) or
            slot.delivery.thumbnail.damaged() or slot.delivery.modal.damaged())
        {
            return true;
        }
    };
    return false;
}

pub fn transferInProgress(store: *const Store) bool {
    return store.delivery.partial != null or store.delivery.abort_pending;
}

pub fn write(store: *Store, writer: *Io.Writer) Io.Writer.Error!usize {
    if (!store.delivery.supported or !damaged(store)) {
        return 0;
    }
    var written: usize = 0;
    if (store.delivery.abort_pending) {
        written += try kitty.writeTransmissionAbort(writer);
        store.delivery.abort_pending = false;
    } else if (store.delivery.partial) |index| {
        const slot = &store.slots[index].?;
        const progress = try kitty.writePngTransmissionChunks(writer, .{
            .external_id = slot.delivery.image_id,
            .png = slot.png,
            .start_offset = slot.delivery.transfer_offset,
            .budget = kitty.transmission_budget_per_frame,
        });
        written += progress.written;
        slot.delivery.transfer_offset = progress.offset;
        if (progress.offset != slot.png.len) {
            return written;
        }
        slot.delivery.transfer_offset = 0;
        slot.delivery.image_dirty = false;
        slot.delivery.image_emitted = true;
        store.delivery.partial = null;
        return written;
    }

    if (store.delivery.delete_all_pending) {
        written += try kitty.writeDeleteImageRange(
            writer,
            first_image_id,
            first_image_id + max_host_ids,
        );
        store.delivery.delete_all_pending = false;
        store.delivery.delete_count = 0;
        for (&store.slots) |*maybe_slot| if (maybe_slot.*) |*slot| {
            slot.delivery.image_emitted = false;
            slot.delivery.image_dirty = true;
            slot.delivery.thumbnail.emitted = null;
            slot.delivery.modal.emitted = null;
        };
    } else {
        for (store.delivery.delete_ids[0..store.delivery.delete_count]) |image_id|
            written += try kitty.writeDeleteImage(writer, image_id);
        store.delivery.delete_count = 0;
    }

    for (&store.slots, 0..) |*maybe_slot, index| {
        const slot = if (maybe_slot.*) |*value| value else continue;
        const wanted = slot.delivery.thumbnail.wanted() or slot.delivery.modal.wanted();
        if (!wanted or !slot.delivery.image_dirty) {
            continue;
        }
        const progress = try kitty.writePngTransmissionChunks(writer, .{
            .external_id = slot.delivery.image_id,
            .png = slot.png,
            .start_offset = 0,
            .budget = kitty.transmission_budget_per_frame,
        });
        written += progress.written;
        slot.delivery.transfer_offset = progress.offset;
        if (progress.offset != slot.png.len) {
            store.delivery.partial = @intCast(index);
            return written;
        }
        slot.delivery.transfer_offset = 0;
        slot.delivery.image_dirty = false;
        slot.delivery.image_emitted = true;
        break;
    }

    for (&store.slots) |*maybe_slot| {
        const slot = if (maybe_slot.*) |*value| value else continue;
        if (!slot.delivery.image_emitted) {
            continue;
        }
        written += try slot.delivery.thumbnail.write(writer, slot.delivery.image_id);
        written += try slot.delivery.modal.write(writer, slot.delivery.image_id);
    }
    return written;
}

pub fn fitPlacement(store: *const Store, slot: *const Slot, area: ui.Rect) ?kitty.OutputPlacement {
    return presentation.fitPlacement(.{ .width = slot.width, .height = slot.height }, .{ .width = store.delivery.cell_width, .height = store.delivery.cell_height }, area);
}

pub fn allocateHostId(store: *Store) !u32 {
    if (store.delivery.next_host_id == 0 or store.delivery.next_host_id > max_host_ids) {
        return error.AttachmentHostIdExhausted;
    }
    const result = store.delivery.next_host_id;
    store.delivery.next_host_id += 1;
    return result;
}

pub fn cancelPartial(store: *Store) void {
    const index = store.delivery.partial orelse return;
    if (store.slots[index]) |*slot| {
        slot.delivery.transfer_offset = 0;
        slot.delivery.image_dirty = true;
        queueDelete(store, slot.delivery.image_id);
    }
    store.delivery.partial = null;
    store.delivery.abort_pending = true;
}

pub fn queueDelete(store: *Store, image_id: u32) void {
    if (store.delivery.delete_all_pending) {
        return;
    }
    for (store.delivery.delete_ids[0..store.delivery.delete_count]) |queued|
        if (queued == image_id) return;
    if (store.delivery.delete_count == store.delivery.delete_ids.len) {
        store.delivery.delete_all_pending = true;
        return;
    }
    store.delivery.delete_ids[store.delivery.delete_count] = image_id;
    store.delivery.delete_count += 1;
}

pub fn createSlot(store: *Store) !SlotState {
    const id = try allocateHostId(store);
    return .{ .image_id = first_image_id + id, .thumbnail = .{ .id = first_thumbnail_placement_id + id, .z = thumbnail_z }, .modal = .{ .id = first_modal_placement_id + id, .z = modal_z } };
}
pub fn targetChanged(store: *Store) void {
    if (store.delivery.partial) |index| {
        if (!store.slotVisible(&store.slots[index].?)) {
            cancelPartial(store);
        }
    }
}
pub fn retireSlot(store: *Store, index: usize) void {
    const slot = &store.slots[index].?;
    if (store.delivery.partial != null and store.delivery.partial.? == index) {
        cancelPartial(store);
    }
    if (slot.delivery.image_emitted or slot.delivery.transfer_offset != 0) {
        queueDelete(store, slot.delivery.image_id);
    }
    slot.delivery.thumbnail.desired = null;
    slot.delivery.modal.desired = null;
}
pub fn canRelease(_: *const Store.Slot) bool {
    return true;
}
