const std = @import("std");
const GenericCatalog = @import("client/attachments/GenericCatalog.zig");
const data = @import("model");
extern "c" fn putchar(c_int) c_int;

const Delivery = struct {
    pub const SlotState = struct { blocked: bool = false };
    pub const State = struct { fail: bool = false };

    pub fn createSlot(catalog: anytype) !SlotState {
        if (catalog.delivery.fail) {
            return error.DeliveryFailed;
        }

        return .{};
    }

    pub fn canRelease(slot: anytype) bool {
        return !slot.delivery.blocked;
    }

    pub fn retireSlot(_: anytype, _: usize) void {}
    pub fn targetChanged(_: anytype) void {}
};
const Catalog = GenericCatalog.Type(Delivery);
const Operation = enum(u64) { adopt, invalid_size, excessive_pixels, target, remove, remove_prompt, open_modal, close_modal, reap, lease, fail_delivery };
const Outcome = enum(u64) { unchanged, changed, adopted, invalid, pixels, full, delivery };
const Shift = enum(u6) { first = 13, second = 7, third = 17, pane = 8, generation = 16, selected = 32 };
const operation_count: u64 = 11;
const operation_limit: u64 = 16384;
const target_domain: u64 = 4;
const selection_domain: u64 = 17;
const pixel_overflow: u32 = 65536;
const record_prefix: u64 = 12;

fn randomWord(state: *u64) u64 {
    state.* ^= state.* << @intFromEnum(Shift.first);
    state.* ^= state.* >> @intFromEnum(Shift.second);
    state.* ^= state.* << @intFromEnum(Shift.third);

    return state.*;
}

fn write(value: u64) !void {
    for (0..@sizeOf(u64)) |index| {
        const shift: u6 = @intCast(index * @bitSizeOf(u8));
        if (putchar(@intCast((value >> shift) & std.math.maxInt(u8))) < 0) {
            return error.WriteFailed;
        }
    }
}

pub fn main() !void {
    const gpa = std.heap.c_allocator;
    var catalog = Catalog.init(gpa);
    defer {
        for (&catalog.slots) |*slot| {
            if (slot.*) |*value| {
                value.delivery.blocked = false;
            }
        }
        catalog.deinit();
    }
    var random: u64 = 0x9e3779b97f4a7c15;
    var next_id: u64 = 1;
    for (0..operation_limit) |index| {
        const word = randomWord(&random);
        const operation: Operation = @enumFromInt(word % operation_count);
        const target: data.AttachmentTarget = .{ .pane_id = @enumFromInt((word >> @intFromEnum(Shift.pane)) % target_domain), .pane_generation = (word >> @intFromEnum(Shift.generation)) % target_domain };
        const selected = (word >> @intFromEnum(Shift.selected)) % selection_domain;
        const flag = word & 1 != 0;
        var outcome: Outcome = .unchanged;
        var evicted: u64 = 0;
        switch (operation) {
            .adopt, .invalid_size, .excessive_pixels => {
                const capture = try gpa.create(data.Capture);
                var owned = true;
                defer if (owned) {
                    capture.deinit(gpa);
                };
                capture.* = .{ .request = .{ .target = target, .sequence = next_id }, .png = try gpa.alloc(u8, 1), .width = if (operation == .invalid_size) 0 else if (operation == .excessive_pixels) pixel_overflow else 1, .height = if (operation == .excessive_pixels) pixel_overflow else 1 };
                next_id += 1;
                capture.png[0] = 0x5a;
                const reach = catalog.adopt(capture) catch |err| failed: {
                    outcome = switch (@as(anyerror, err)) {
                        error.InvalidClipboardImage => .invalid,
                        error.ClipboardImageTooLarge => .pixels,
                        error.AttachmentSelfFull => .full,
                        error.DeliveryFailed => .delivery,
                        else => return err,
                    };
                    break :failed null;
                };
                if (outcome == .unchanged) {
                    owned = false;
                    outcome = .adopted;
                    if (reach) |value| {
                        evicted = if (std.mem.eql(u8, value.limit.name, "attachments.max_items")) 1 else 2;
                    }
                }
            },
            .target => {
                const change = catalog.setTarget(if (flag) target else null);
                outcome = if (change.changed) .changed else .unchanged;
            },
            .remove => outcome = if (catalog.remove(@enumFromInt(selected))) .changed else .unchanged,
            .remove_prompt => outcome = if (catalog.removeVisible(target) != 0) .changed else .unchanged,
            .open_modal => outcome = if (catalog.openModal(@enumFromInt(selected))) .changed else .unchanged,
            .close_modal => outcome = if (catalog.closeModal()) .changed else .unchanged,
            .reap => catalog.reapRetired(),
            .lease => {
                for (&catalog.slots) |*slot| {
                    if (slot.*) |*value| {
                        value.delivery.blocked = flag;
                    }
                }
            },
            .fail_delivery => catalog.delivery.fail = flag,
        }

        const visible = catalog.snapshot();
        const active = catalog.active_target orelse data.AttachmentTarget{ .pane_id = .invalid, .pane_generation = 0 };
        for ([_]u64{ index, @intFromEnum(operation), selected, @intFromEnum(outcome), evicted, @intFromEnum(active.pane_id), active.pane_generation, if (visible.modal) |id| @intFromEnum(id) else 0, catalog.total_bytes, catalog.ingress_version, visible.len, @intFromBool(catalog.cleanupPending()) }) |value| {
            try write(value);
        }
        for (0..data.attachment_types.max_items) |slot| {
            try write(if (slot < visible.len) @intFromEnum(visible.items[slot].id) else 0);
        }
    }
}
