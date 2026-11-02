const std = @import("std");
const GenericCatalog = @import("client/attachments/GenericCatalog.zig");
const data = @import("model");
const cellgrid = @import("cellgrid");
const MarkerScreen = @import("client/attachments/MarkerScreen.zig");
const RemovalPlan = @import("client/attachments/MarkerRemovalPlan.zig");
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
const Operation = enum(u64) { adopt, invalid_size, excessive_pixels, target, remove, remove_prompt, open_modal, close_modal, reap, lease, fail_delivery, reconcile, expect_deletion, remove_at_cursor, plan_remove, pending_at_cursor, idle };
const Outcome = enum(u64) { unchanged, changed, adopted, invalid, pixels, full, delivery };
const Shift = enum(u6) { first = 13, second = 7, third = 17, pane = 8, generation = 16, selected = 32 };
const operation_count: u64 = 17;
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

fn put(buffer: *cellgrid.Buffer, row: u16, text: []const u8) void {
    for (text, 0..) |byte, index| {
        const cell = &buffer.cells[(@as(usize, row) + index / (buffer.w - 1)) * buffer.w + index % (buffer.w - 1)];
        cell.bytes[0] = byte;
    }
}

fn frame(buffer: *cellgrid.Buffer, word: u64) MarkerScreen {
    @memset(buffer.cells, .{});
    const variant = (word >> 20) % 9;
    const text = switch (variant) {
        0 => "[Image #1] [Image #2] [Image #3]",
        1 => "[Image #11] [Image #12] [Image #3]",
        2 => "[Image #11]",
        3 => "/tmp/pi-clipboard-12345678-1234-ABCD-1234-123456789abc.png /tmp/pi-clipboard-87654321-4321-DCBA-4321-cba987654321.png",
        4 => "/tmp/pi-clipboard-12345678-1234-ABCD-1234-123456789abc.png",
        6 => "[Image #1]",
        7 => "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/tmp/pi-clipboard-12345678-1234-ABCD-1234-123456789abc.png",
        8 => "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/tmp/pi-clipboard-12345678-1234-ABCD-1234-123456789abc.png",
        else => "",
    };
    put(buffer, 0, text);
    const cursor = if (variant == 6) buffer.w - 1 else if (word & 4 != 0) text.len else 0;
    return .{ .buffer = buffer, .cursor = .{ .visible = word & 2 != 0, .x = @intCast(if (variant == 6) cursor else cursor % (buffer.w - 1)), .y = @intCast(if (variant == 6) 0 else cursor / (buffer.w - 1)) } };
}

fn writePlan(value: ?RemovalPlan.MarkerRemovalPlan) !void {
    const current = value orelse {
        try write(0);
        return;
    };
    switch (current) {
        .unreachable_marker => try write(1),
        .limited => |reach| {
            try write(2);
            try write(if (std.mem.eql(u8, reach.limit.name, "attachments.max_marker_navigation_steps")) 1 else if (std.mem.eql(u8, reach.limit.name, "attachments.path_marker.max_cells")) 2 else 3);
            try write(reach.requested orelse std.math.maxInt(u64));
        },
        .planned => |removal| {
            try write(3);
            try write(@intFromEnum(removal.direction));
            try write(removal.steps);
            try write(@intFromEnum(removal.deletion));
            try write(removal.deletions);
            try write(removal.keyCount());
        },
    }
}

const Prelude = struct { operation: Operation, policy: data.AttachmentMarkerPolicy = .ordered, variant: u64 = 6 };
const prelude = [_]Prelude{
    .{ .operation = .target },
    .{ .operation = .adopt },
    .{ .operation = .plan_remove },
    .{ .operation = .remove_prompt },
    .{ .operation = .adopt, .policy = .pasted_path, .variant = 7 },
    .{ .operation = .reconcile, .policy = .pasted_path, .variant = 7 },
    .{ .operation = .plan_remove, .policy = .pasted_path, .variant = 7 },
    .{ .operation = .remove_prompt },
    .{ .operation = .adopt, .policy = .pasted_path, .variant = 8 },
    .{ .operation = .reconcile, .policy = .pasted_path, .variant = 8 },
    .{ .operation = .plan_remove, .policy = .pasted_path, .variant = 8 },
};

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
    var buffer = try cellgrid.Buffer.init(gpa, 256, 3);
    defer buffer.deinit();
    var random: u64 = 0x9e3779b97f4a7c15;
    var next_id: u64 = 1;
    for (0..operation_limit) |index| {
        var word = randomWord(&random);
        const controlled = index < prelude.len;
        if (controlled) {
            word = (prelude[index].variant << 20) | 7;
        }
        const policy: data.AttachmentMarkerPolicy = if (controlled) prelude[index].policy else @enumFromInt((word >> 24) % 3);
        const operation: Operation = if (controlled) prelude[index].operation else @enumFromInt(word % operation_count);
        const target: data.AttachmentTarget = if (controlled or word & (@as(u64, 1) << 40) != 0) .{ .pane_id = @enumFromInt(1), .pane_generation = 2 } else .{ .pane_id = @enumFromInt(2), .pane_generation = 3 };
        var selected = (word >> @intFromEnum(Shift.selected)) % selection_domain;
        const flag = word & 1 != 0;
        var outcome: Outcome = .unchanged;
        var evicted: u64 = 0;
        var extra: u64 = 0;
        var planned: ?RemovalPlan.MarkerRemovalPlan = null;
        const screen = frame(&buffer, word);
        const focused = catalog.active_target orelse target;
        const deletion: data.AttachmentMarkerDeletion = if (flag) .backward else .forward;
        switch (operation) {
            .adopt, .invalid_size, .excessive_pixels => {
                const capture = try gpa.create(data.Capture);
                var owned = true;
                defer if (owned) {
                    capture.deinit(gpa);
                };
                capture.* = .{ .request = .{ .target = target, .sequence = next_id, .marker_policy = policy }, .png = try gpa.alloc(u8, 1), .width = if (operation == .invalid_size) 0 else if (operation == .excessive_pixels) pixel_overflow else 1, .height = if (operation == .excessive_pixels) pixel_overflow else 1 };
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
            .reconcile => extra = catalog.reconcileMarkers(focused, screen),
            .expect_deletion => catalog.expectMarkerDeletion(focused),
            .remove_at_cursor => {
                const id = catalog.idAtMarkerDeletion(screen, deletion);
                if (id) |value| {
                    extra = @intFromEnum(value);
                    outcome = if (catalog.remove(value)) .changed else .unchanged;
                }
            },
            .plan_remove => {
                const visible = catalog.snapshot();
                if (visible.len != 0) {
                    selected = @intFromEnum(visible.items[selected % visible.len].id);
                }
                planned = catalog.planMarkerRemoval(@enumFromInt(selected), screen);
            },
            .pending_at_cursor => extra = @intFromBool(catalog.pendingMarkerAtDeletion(screen, .{ .policy = policy, .deletion = deletion })),
            .idle => {},
        }

        const visible = catalog.snapshot();
        const active = catalog.active_target orelse data.AttachmentTarget{ .pane_id = .invalid, .pane_generation = 0 };
        for ([_]u64{ index, @intFromEnum(operation), selected, @intFromEnum(outcome), evicted, @intFromEnum(active.pane_id), active.pane_generation, if (visible.modal) |id| @intFromEnum(id) else 0, catalog.total_bytes, catalog.ingress_version, visible.len, @intFromBool(catalog.cleanupPending()) }) |value| {
            try write(value);
        }
        for (0..data.attachment_types.max_items) |slot| {
            try write(if (slot < visible.len) @intFromEnum(visible.items[slot].id) else 0);
        }
        try write(extra);
        for (visible.slice()) |item| {
            const slot = catalog.findConst(item.id).?;
            try write(slot.markerNumber() orelse 0);
            const path = slot.markerPath();
            try write(@intFromBool(path != null));
            if (path) |uuid| {
                for (uuid) |byte| {
                    try write(byte);
                }
            }
        }
        try writePlan(planned);
    }
}
