//! What the placement experiment's JSON Lines say about an idle-delivery
//! fixture: the layout of the records an idle flush walks, where each record
//! landed and which allocations the placement controls. Every line is written
//! before the first timed sample or after the last one, never between them.
//! The record types are reached through the runtime model's own columns, so
//! the runtime carries nothing for this report.
const backend = @import("telar-backend");
const std = @import("std");
const IdleDeliveryShape = @import("IdleDeliveryShape.zig");
const PlacementAllocator = @import("PlacementAllocator.zig");
const PlacementBacking = @import("PlacementBacking.zig").PlacementBacking;
const PlacementPolicy = @import("PlacementPolicy.zig");

const Runtime = backend.Runtime;
const RuntimeModel = @FieldType(Runtime, "model");
const PaneSlots = @FieldType(@FieldType(RuntimeModel, "panes"), "items");
const AttachmentSlots = @FieldType(@FieldType(RuntimeModel, "attachments"), "record");
const SessionSlots = @FieldType(@FieldType(RuntimeModel, "clients"), "items");
const Pane = std.meta.Child(std.meta.Child(std.meta.Child(PaneSlots)));
const Attachment = std.meta.Child(std.meta.Child(std.meta.Child(std.meta.Child(AttachmentSlots))));
const Session = std.meta.Child(std.meta.Child(std.meta.Child(SessionSlots)));
const CellSync = @FieldType(Attachment, "cells");

/// The most records of one kind a runtime holds: every slot of its widest
/// column of record pointers.
const max_sites = @max(@sizeOf(PaneSlots), @sizeOf(AttachmentSlots), @sizeOf(SessionSlots)) / @sizeOf(usize);

/// Writes what one benchmark process fixes for every idle-delivery case: the
/// policy, the host's page size and the layout of each record type.
///
/// ```zig
/// try placement_report.writePolicy(writer, policy, .libc);
/// ```
pub fn writePolicy(writer: *std.Io.Writer, policy: PlacementPolicy, backing: PlacementBacking) !void {
    try writer.print(
        "{{\"type\":\"placement_policy\",\"mode\":\"{s}\",\"backing\":\"{s}\"," ++
            "\"threshold_bytes\":{d},\"stride_bytes\":{d},\"window_bytes\":{d}," ++
            "\"shift_bytes\":{d},\"page_bytes\":{d},\"table_rows\":{d}," ++
            "\"pack_region_bytes\":{d}}}\n",
        .{
            @tagName(policy.mode),
            @tagName(backing),
            policy.threshold,
            policy.stride,
            policy.window,
            policy.shiftBytes(),
            std.heap.pageSize(),
            PlacementAllocator.capacity,
            PlacementAllocator.region_bytes,
        },
    );

    try writeLayout(writer, policy, Pane, "pane");
    try writeLayout(writer, policy, Attachment, "attachment");
    try writeLayout(writer, policy, CellSync, "cell_sync");
    try writeLayout(writer, policy, Session, "session");
    try writeLayout(writer, policy, Runtime, "runtime");
    try writeLayout(writer, policy, RuntimeModel, "runtime_model");
}

/// Writes where a settled fixture's records are and which allocations the
/// placement holds for it, one line per kind with one array per column.
/// Call it before timing starts.
///
/// ```zig
/// try placement_report.writeFixture(writer, case.name, shape, &context.idle, &placement);
/// ```
pub fn writeFixture(writer: *std.Io.Writer, name: []const u8, shape: IdleDeliveryShape, idle: *const backend.IdleDelivery, placement: *PlacementAllocator) !void {
    try writer.print(
        "{{\"type\":\"placement_fixture\",\"name\":\"{s}\",\"clients\":{d},\"panes\":{d}," ++
            "\"cols\":{d},\"rows\":{d},\"placed\":{d},\"placed_bytes\":{d},\"live\":{d}," ++
            "\"refused\":{d},\"pack_region_used_bytes\":{d}}}\n",
        .{
            name,
            shape.clients,
            shape.panes,
            shape.size.cols,
            shape.size.rows,
            placement.placed,
            placement.placed_bytes,
            placement.live,
            placement.refused,
            placement.region_used,
        },
    );

    const model = &idle.runtime.model;
    var sites: RecordSites = .{
        .label = "runtime",
    };
    sites.add(0, 0, @intFromPtr(idle.runtime));
    try writeSites(writer, name, placement, &sites);

    sites = .{
        .label = "session",
    };
    for (model.clients.items, 0..) |slot, index| {
        const session = slot orelse continue;
        sites.add(0, index, @intFromPtr(session));
    }

    try writeSites(writer, name, placement, &sites);

    sites = .{
        .label = "pane",
    };
    for (model.panes.items, 0..) |slot, index| {
        const pane = slot orelse continue;
        sites.add(0, index, @intFromPtr(pane));
    }

    try writeSites(writer, name, placement, &sites);

    sites = .{
        .label = "attachment",
        .by_client = true,
    };
    for (&model.attachments.record, 0..) |*row, client| {
        for (row, 0..) |slot, index| {
            const attachment = slot orelse continue;
            sites.add(client, index, @intFromPtr(attachment));
        }
    }

    try writeSites(writer, name, placement, &sites);
    try writeAllocations(writer, name, placement);
}

/// Writes whether the measured fixture is still idle: every client quiet and
/// none with a send in flight. Call it after the last timed sample.
///
/// ```zig
/// try placement_report.writeIdle(writer, case.name, &context.idle);
/// ```
pub fn writeIdle(writer: *std.Io.Writer, name: []const u8, idle: *const backend.IdleDelivery) !void {
    var sends_pending: usize = 0;
    for (idle.runtime.model.clients.items) |slot| {
        const session = slot orelse continue;
        sends_pending += @intFromBool(session.send_pending);
    }

    try writer.print(
        "{{\"type\":\"placement_idle\",\"name\":\"{s}\",\"quiet\":{},\"sends_pending\":{d}}}\n",
        .{
            name,
            idle.quiet(),
            sends_pending,
        },
    );
}

/// Writes what the placement still holds once the fixture is gone; a live
/// count above zero is a record the fixture never freed.
///
/// ```zig
/// try placement_report.writeTeardown(writer, case.name, &placement);
/// ```
pub fn writeTeardown(writer: *std.Io.Writer, name: []const u8, placement: *const PlacementAllocator) !void {
    try writer.print(
        "{{\"type\":\"placement_teardown\",\"name\":\"{s}\",\"placed\":{d},\"live\":{d},\"refused\":{d}}}\n",
        .{
            name,
            placement.placed,
            placement.live,
            placement.refused,
        },
    );
}

fn writeLayout(writer: *std.Io.Writer, policy: PlacementPolicy, comptime Layout: type, comptime label: []const u8) !void {
    try writer.print(
        "{{\"type\":\"placement_layout\",\"record\":\"{s}\",\"type_name\":\"{s}\",\"size_bytes\":{d}," ++
            "\"alignment_bytes\":{d},\"shape_selected\":{},\"fields\":[",
        .{
            label,
            @typeName(Layout),
            @sizeOf(Layout),
            @alignOf(Layout),
            policy.selects(@sizeOf(Layout), .of(Layout)),
        },
    );

    var separator: []const u8 = "";
    inline for (std.meta.fields(Layout)) |field| {
        if (!field.is_comptime) {
            try writer.print(
                "{s}{{\"name\":\"{s}\",\"offset_bytes\":{d},\"size_bytes\":{d}}}",
                .{
                    separator,
                    field.name,
                    @offsetOf(Layout, field.name),
                    @sizeOf(field.type),
                },
            );
            separator = ",";
        }
    }

    try writer.writeAll("]}\n");
}

fn writeSites(writer: *std.Io.Writer, name: []const u8, placement: *PlacementAllocator, sites: *const RecordSites) !void {
    const addresses = sites.address[0..sites.count];
    try writer.print("{{\"type\":\"placement_records\",\"name\":\"{s}\",\"record\":\"{s}\",\"count\":{d}", .{ name, sites.label, sites.count });
    if (sites.by_client) {
        try writeColumn(writer, "client", sites.client[0..sites.count], 0);
    }

    try writeColumn(writer, "index", sites.index[0..sites.count], 0);
    try writeColumn(writer, "address", addresses, 0);
    try writeColumn(writer, "page_offset_bytes", addresses, std.heap.pageSize());
    try writeColumn(writer, "window_offset_bytes", addresses, placement.policy.window);
    try writer.writeAll(",\"controlled\":[");
    for (addresses, 0..) |address, position| {
        try writer.print("{s}{}", .{ if (position == 0) "" else ",", placement.controls(address) });
    }

    try writer.writeAll("]}\n");
}

/// Writes every live controlled allocation, records or not: the policy
/// selects by shape, so it also places buffers no record kind names.
fn writeAllocations(writer: *std.Io.Writer, name: []const u8, placement: *const PlacementAllocator) !void {
    var rows: [PlacementAllocator.capacity]usize = undefined;
    var count: usize = 0;
    for (placement.address, 0..) |address, row| {
        if (address != 0) {
            rows[count] = row;
            count += 1;
        }
    }

    try writer.print("{{\"type\":\"placement_allocations\",\"name\":\"{s}\",\"count\":{d},\"address\":[", .{ name, count });
    for (rows[0..count], 0..) |row, position| {
        try writer.print("{s}{d}", .{ if (position == 0) "" else ",", placement.address[row] });
    }

    try writer.writeAll("],\"len_bytes\":[");
    for (rows[0..count], 0..) |row, position| {
        try writer.print("{s}{d}", .{ if (position == 0) "" else ",", placement.len[row] });
    }

    try writer.writeAll("],\"offset_bytes\":[");
    for (rows[0..count], 0..) |row, position| {
        try writer.print("{s}{d}", .{ if (position == 0) "" else ",", placement.address[row] - placement.base[row] });
    }

    try writer.writeAll("]}\n");
}

/// Writes one array of `values`, each reduced modulo `modulus` unless it is
/// zero.
fn writeColumn(writer: *std.Io.Writer, key: []const u8, values: []const usize, modulus: usize) !void {
    try writer.print(",\"{s}\":[", .{key});
    for (values, 0..) |value, position| {
        try writer.print("{s}{d}", .{ if (position == 0) "" else ",", if (modulus == 0) value else value % modulus });
    }

    try writer.writeByte(']');
}

/// The records of one kind in a settled fixture and where each one lives.
const RecordSites = struct {
    label: []const u8,
    /// Attachments belong to a client slot; the other kinds have none.
    by_client: bool = false,
    client: [max_sites]usize = undefined,
    index: [max_sites]usize = undefined,
    address: [max_sites]usize = undefined,
    count: usize = 0,

    fn add(self: *RecordSites, client: usize, index: usize, address: usize) void {
        self.client[self.count] = client;
        self.index[self.count] = index;
        self.address[self.count] = address;
        self.count += 1;
    }
};
