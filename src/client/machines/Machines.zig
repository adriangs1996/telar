//! The machines one window holds, one row per slot of its client array. Row
//! `local_slot` is this machine; the others come from `machines.json` or
//! from a temporary `--remote`. Every machine surface reads these columns,
//! and a row's summary is refreshed after its client's events, never derived
//! per frame by walking a hidden client's model.
const core = @import("telar-core");
const data = @import("model");
const std = @import("std");
const agent_attention = @import("../agents/attention.zig");
const MachineRow = @import("MachineRow.zig");
const Machines = @This();

/// Slots one window holds: this machine and every saved one.
pub const capacity = core.MachineProfiles.capacity + 1;
/// The slot of the machine the window runs on.
pub const local_slot: u8 = 0;
/// The longest label or destination a row keeps, in bytes.
pub const max_label_bytes = core.MachineProfile.max_label_bytes;
pub const max_destination_bytes = core.ssh_destination.max_bytes;
pub const max_color_bytes = core.MachineProfile.max_color_bytes;

used: [capacity]bool = @splat(false),
/// The profile's id; `.invalid` for this machine and a temporary row.
id: [capacity]core.MachineId = @splat(.invalid),
label_bytes: [capacity][max_label_bytes]u8 = undefined,
label_len: [capacity]u8 = @splat(0),
destination_bytes: [capacity][max_destination_bytes]u8 = undefined,
destination_len: [capacity]u8 = @splat(0),
color_bytes: [capacity][max_color_bytes]u8 = undefined,
color_len: [capacity]u8 = @splat(0),
/// Whether the window keeps a connection to the machine.
enabled: [capacity]bool = @splat(false),
/// Whether the slot's client is initialized.
live: [capacity]bool = @splat(false),
phase: [capacity]data.RuntimeLink.Phase = @splat(.connecting),
attention: [capacity]bool = @splat(false),
cpu_percent: [capacity]?u8 = @splat(null),
/// What placement needs from the last sample: the CPU count, memory in
/// tenths of a GiB, and when the sample arrived by the client's monotonic
/// clock, so a stale one can be skipped. Zero means none yet.
cpu_count: [capacity]u16 = @splat(0),
memory_used_decigib: [capacity]u16 = @splat(0),
memory_total_decigib: [capacity]u16 = @splat(0),
sampled_ns: [capacity]u64 = @splat(0),
/// The client's metrics revision the row last copied.
metrics_revision: [capacity]u64 = @splat(0),
/// The slot the window presents.
active: u8 = local_slot,
/// Advances when any column a surface draws changes.
revision: u64 = 0,

/// Fills a free slot, or the given one, and returns it.
///
/// ```zig
/// const slot = try machines.add(.{ .label = "box", .destination = "dev@box" }, null);
/// ```
pub fn add(self: *Machines, row: MachineRow, wanted: ?u8) !u8 {
    const slot = wanted orelse self.freeSlot() orelse return error.TooManyMachines;
    std.debug.assert(!self.used[slot]);
    self.used[slot] = true;
    self.write(slot, row);
    self.phase[slot] = .connecting;
    self.attention[slot] = false;
    self.cpu_percent[slot] = null;
    self.cpu_count[slot] = 0;
    self.memory_used_decigib[slot] = 0;
    self.memory_total_decigib[slot] = 0;
    self.sampled_ns[slot] = 0;
    self.metrics_revision[slot] = 0;
    self.revision +%= 1;
    return slot;
}

/// Replaces a row's profile fields, keeping its client and summary.
///
/// ```zig
/// machines.update(slot, .{ .id = id, .label = "gpu", .destination = "dev@gpu" });
/// ```
pub fn update(self: *Machines, slot: u8, row: MachineRow) void {
    std.debug.assert(self.used[slot]);
    self.write(slot, row);
    self.revision +%= 1;
}

/// Frees a row. A live client keeps its slot; the next row added there
/// reuses that client with the new destination.
pub fn remove(self: *Machines, slot: u8) void {
    std.debug.assert(self.used[slot] and slot != local_slot);
    self.used[slot] = false;
    self.enabled[slot] = false;
    self.id[slot] = .invalid;
    self.revision +%= 1;
}

pub fn label(self: *const Machines, slot: u8) []const u8 {
    return self.label_bytes[slot][0..self.label_len[slot]];
}

pub fn destination(self: *const Machines, slot: u8) []const u8 {
    return self.destination_bytes[slot][0..self.destination_len[slot]];
}

pub fn color(self: *const Machines, slot: u8) ?[]const u8 {
    if (self.color_len[slot] == 0) {
        return null;
    }

    return self.color_bytes[slot][0..self.color_len[slot]];
}

/// The slot of the row with `id`, if any.
pub fn find(self: *const Machines, id: core.MachineId) ?u8 {
    for (self.used, self.id, 0..) |used, row_id, slot| {
        if (used and row_id == id and id != .invalid) {
            return @intCast(slot);
        }
    }

    return null;
}

/// The slot of the row labelled `text`, if any.
pub fn findLabel(self: *const Machines, text: []const u8) ?u8 {
    for (self.used, 0..) |used, slot| {
        if (used and std.mem.eql(u8, self.label(@intCast(slot)), text)) {
            return @intCast(slot);
        }
    }

    return null;
}

/// Rows the window shows: in use and enabled.
pub fn count(self: *const Machines) usize {
    var total: usize = 0;
    for (self.used, self.enabled) |used, enabled| {
        total += @intFromBool(used and enabled);
    }

    return total;
}

/// Whether a row is one the window shows.
pub fn shown(self: *const Machines, slot: u8) bool {
    return self.used[slot] and self.enabled[slot];
}

/// Refreshes a row's summary from its client's model, stamping a new
/// metrics sample with `now_ns`. Returns whether a column a surface draws
/// changed.
///
/// ```zig
/// _ = machines.summarize(slot, &client.model, pacing.clock.monotonic(io));
/// ```
pub fn summarize(self: *Machines, slot: u8, model: *const data.ClientModel, now_ns: u64) bool {
    if (model.system_metrics) |metrics| {
        if (model.system_metrics_revision != self.metrics_revision[slot]) {
            self.metrics_revision[slot] = model.system_metrics_revision;
            self.cpu_count[slot] = metrics.cpu_count;
            self.memory_used_decigib[slot] = metrics.memory_used_decigib;
            self.memory_total_decigib[slot] = metrics.memory_total_decigib;
            self.sampled_ns[slot] = now_ns;
        }
    }

    const phase = model.runtime_link.phase;
    const attention_now = needsAttention(model);
    const cpu: ?u8 = if (model.system_metrics) |metrics| metrics.cpu_percent else null;
    if (self.phase[slot] == phase and self.attention[slot] == attention_now and std.meta.eql(self.cpu_percent[slot], cpu)) {
        return false;
    }

    self.phase[slot] = phase;
    self.attention[slot] = attention_now;
    self.cpu_percent[slot] = cpu;
    self.revision +%= 1;
    return true;
}

/// Whether any machine other than the active one asks for the person.
pub fn attentionElsewhere(self: *const Machines) bool {
    for (self.used, self.attention, 0..) |used, attention_value, slot| {
        if (used and attention_value and slot != self.active) {
            return true;
        }
    }

    return false;
}

fn needsAttention(model: *const data.ClientModel) bool {
    for (model.agent_snapshot.slice()) |*agent| {
        if (agent_attention.group(agent.status) == .needs_input) {
            return true;
        }
    }

    return false;
}

// The shown slot stays out of reach until the window shows another one,
// even once its row is removed.
fn freeSlot(self: *const Machines) ?u8 {
    for (self.used, 0..) |used, slot| {
        if (!used and slot != local_slot and slot != self.active) {
            return @intCast(slot);
        }
    }

    return null;
}

fn write(self: *Machines, slot: u8, row: MachineRow) void {
    self.id[slot] = row.id;
    const kept_label = row.label[0..@min(row.label.len, max_label_bytes)];
    @memcpy(self.label_bytes[slot][0..kept_label.len], kept_label);
    self.label_len[slot] = @intCast(kept_label.len);
    const kept_destination = row.destination[0..@min(row.destination.len, max_destination_bytes)];
    @memcpy(self.destination_bytes[slot][0..kept_destination.len], kept_destination);
    self.destination_len[slot] = @intCast(kept_destination.len);
    const kept_color = if (row.color) |text| text[0..@min(text.len, max_color_bytes)] else "";
    @memcpy(self.color_bytes[slot][0..kept_color.len], kept_color);
    self.color_len[slot] = @intCast(kept_color.len);
    self.enabled[slot] = row.enabled;
}

test "rows fill free slots and keep the local slot for this machine" {
    var machines: Machines = .{};
    const local = try machines.add(.{ .label = "laptop" }, local_slot);
    const box = try machines.add(.{ .id = @enumFromInt(9), .label = "box", .destination = "dev@box", .color = "red" }, null);

    try std.testing.expectEqual(local_slot, local);
    try std.testing.expectEqual(@as(u8, 1), box);
    try std.testing.expectEqual(@as(?u8, 1), machines.find(@enumFromInt(9)));
    try std.testing.expectEqual(@as(?u8, 1), machines.findLabel("box"));
    try std.testing.expectEqualStrings("dev@box", machines.destination(box));
    try std.testing.expectEqualStrings("red", machines.color(box).?);
    try std.testing.expectEqual(@as(usize, 2), machines.count());

    machines.remove(box);
    try std.testing.expectEqual(@as(?u8, null), machines.find(@enumFromInt(9)));
    try std.testing.expectEqual(@as(u8, 1), try machines.add(.{ .label = "gpu" }, null));
}

test "a summary changes the revision only when a drawn column changes" {
    var machines: Machines = .{};
    const slot = try machines.add(.{ .label = "box" }, null);
    var model = data.ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    model.runtime_link.phase = .connected;
    try std.testing.expect(machines.summarize(slot, &model, 10));
    const revision = machines.revision;
    try std.testing.expect(!machines.summarize(slot, &model, 20));
    try std.testing.expectEqual(revision, machines.revision);
    try std.testing.expect(!machines.attentionElsewhere());
}

test "a new metrics sample records placement data with its arrival time" {
    var machines: Machines = .{};
    const slot = try machines.add(.{ .label = "box" }, null);
    var model = data.ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    _ = try data.system_metrics.reconcile(&model, .{
        .runtime_revision = 1,
        .cpu_percent = 30,
        .memory_used_decigib = 40,
        .battery_percent = null,
        .cpu_count = 16,
        .memory_total_decigib = 640,
    });
    _ = machines.summarize(slot, &model, 5);
    _ = machines.summarize(slot, &model, 9);

    try std.testing.expectEqual(@as(u16, 16), machines.cpu_count[slot]);
    try std.testing.expectEqual(@as(u16, 640), machines.memory_total_decigib[slot]);
    try std.testing.expectEqual(@as(u64, 5), machines.sampled_ns[slot]);
}
