const core = @import("telar-core");
const std = @import("std");
const Attachment = @import("Attachment.zig");
const Pane = @import("../../pane/Pane.zig");
const store_support = @import("../client/store_support.zig");
/// Every client's rendering state for the panes it attaches: one row per
/// client slot, one heap record per attached pane. A record holds two cell
/// buffers and the graphics baseline, so only attached panes pay for one.
/// `Pane.observers` is the table's reverse index; `add` and `remove` keep it.
const Attachments = @This();

/// A client attaches to the panes of the tab it shows. A tab it creates or
/// a pane it opens elsewhere is attached before the client lets the
/// previous tab go, so a client briefly holds two tabs' panes.
pub const capacity = 2 * core.max_panes_per_tab;
pub const clients = store_support.max_clients;

record: [clients][capacity]?*Attachment = @splat(@splat(null)),
index: [clients]core.GenericSlotIndex(2 * capacity) = @splat(.{}),
count: [clients]usize = @splat(0),

/// Example: `const attachment = model.attachments.find(session.slot, pane_id) orelse return;`.
pub fn find(self: *Attachments, client: usize, pane_id: core.PaneId) ?*Attachment {
    const slot = self.index[client].get(core.raw(pane_id)) orelse return null;
    const attachment = self.record[client][slot].?;
    std.debug.assert(attachment.pane.id == pane_id);
    return attachment;
}

/// Example: `const attachment = model.attachments.at(session.slot, slot) orelse continue;`.
pub fn at(self: *Attachments, client: usize, slot: usize) ?*Attachment {
    if (slot >= capacity) {
        return null;
    }

    return self.record[client][slot];
}

/// Example: `if (model.attachments.len(session.slot) == 0) { ... }`.
pub fn len(self: *const Attachments, client: usize) usize {
    return self.count[client];
}

/// Adds one client's attachment to a running pane and marks the client in
/// the pane's observer mask. The caller has checked it is absent.
///
/// ```zig
/// const attachment = try model.attachments.add(model.gpa, session.slot, pane);
/// ```
pub fn add(self: *Attachments, gpa: std.mem.Allocator, client: usize, pane: *Pane) !*Attachment {
    std.debug.assert(self.index[client].get(core.raw(pane.id)) == null);
    if (self.count[client] == capacity) {
        return error.AttachmentLimitReached;
    }

    const slot = std.mem.indexOfScalar(?*Attachment, &self.record[client], null).?;
    const attachment = try gpa.create(Attachment);
    errdefer gpa.destroy(attachment);

    attachment.* = try Attachment.init(gpa, pane);
    self.record[client][slot] = attachment;
    self.index[client].put(core.raw(pane.id), slot);
    self.count[client] += 1;
    pane.observers |= observer(client);
    return attachment;
}

/// Removes one client's attachment and its bit in the pane's observer mask.
///
/// ```zig
/// if (!model.attachments.remove(model.gpa, session.slot, pane_id)) return;
/// ```
pub fn remove(self: *Attachments, gpa: std.mem.Allocator, client: usize, pane_id: core.PaneId) bool {
    const slot = self.index[client].get(core.raw(pane_id)) orelse return false;
    self.release(gpa, client, slot);
    return true;
}

/// Removes every attachment of one client.
///
/// ```zig
/// model.attachments.clear(model.gpa, session.slot);
/// ```
pub fn clear(self: *Attachments, gpa: std.mem.Allocator, client: usize) void {
    for (0..capacity) |slot| {
        if (self.record[client][slot] != null) {
            self.release(gpa, client, slot);
        }
    }

    std.debug.assert(self.count[client] == 0);
}

/// Pops the lowest client of an observer mask and returns its attachment to
/// the pane, so a pane visits only the clients that attach it.
///
/// ```zig
/// var observers = pane.observers;
/// while (model.attachments.nextObserver(pane.id, &observers)) |attachment| { ... }
/// ```
pub fn nextObserver(self: *Attachments, pane_id: core.PaneId, observers: *store_support.Observers) ?*Attachment {
    while (observers.* != 0) {
        const client = @ctz(observers.*);
        observers.* &= observers.* - 1;
        if (self.find(client, pane_id)) |attachment| {
            return attachment;
        }
    }

    return null;
}

/// Finds the client's next deferred publication that is not waiting for
/// ingest or ACK.
///
/// ```zig
/// session.cell_deadline_ns = model.attachments.cellDeadline(session.slot);
/// ```
pub fn cellDeadline(self: *const Attachments, client: usize) ?u64 {
    var earliest: ?u64 = null;
    for (&self.record[client]) |slot| {
        const attachment = slot orelse continue;
        const deadline = attachment.cell_deadline_ns orelse continue;

        if (attachment.pane.ingest_pending or attachment.cells.hasOutstanding()) {
            continue;
        }

        earliest = @min(earliest orelse deadline, deadline);
    }

    return earliest;
}

/// The graphics bytes the client may still receive across all its panes.
///
/// ```zig
/// const credit = model.attachments.availableGraphicsCredit(session.slot);
/// ```
pub fn availableGraphicsCredit(self: *const Attachments, client: usize) usize {
    var outstanding: usize = 0;
    for (&self.record[client]) |slot| {
        const attachment = slot orelse continue;
        outstanding +|= core.max_image_bytes_per_pane -
            @min(attachment.graphicsCredit(), core.max_image_bytes_per_pane);
    }

    return core.max_image_bytes_global -|
        @min(outstanding, core.max_image_bytes_global);
}

/// Example: `model.attachments.deinit(model.gpa);`.
pub fn deinit(self: *Attachments, gpa: std.mem.Allocator) void {
    for (0..clients) |client| {
        self.clear(gpa, client);
    }
}

/// A client's bit in `Pane.observers`.
///
/// ```zig
/// if (pane.observers & Attachments.observer(session.slot) != 0) { ... }
/// ```
pub fn observer(client: usize) store_support.Observers {
    return @as(store_support.Observers, 1) << @intCast(client);
}

fn release(self: *Attachments, gpa: std.mem.Allocator, client: usize, slot: usize) void {
    const attachment = self.record[client][slot].?;
    const pane = attachment.pane;

    pane.observers &= ~observer(client);
    self.index[client].remove(core.raw(pane.id));
    attachment.deinit();
    gpa.destroy(attachment);
    self.record[client][slot] = null;
    self.count[client] -= 1;
}

const PaneFixture = @import("../tests/PaneFixture.zig");

test "attachments keep their client's bit in the pane observer mask" {
    const fixture = try std.testing.allocator.create(PaneFixture);
    defer std.testing.allocator.destroy(fixture);
    fixture.* = .{};
    try fixture.init();
    defer fixture.deinit();

    const pane = fixture.pane;
    const gpa = std.testing.allocator;
    var attachments: Attachments = .{};
    defer attachments.deinit(gpa);

    _ = try attachments.add(gpa, 1, pane);
    _ = try attachments.add(gpa, 3, pane);
    try std.testing.expectEqual(@as(store_support.Observers, 0b1011), pane.observers);

    try std.testing.expect(attachments.remove(gpa, 1, pane.id));
    try std.testing.expect(!attachments.remove(gpa, 1, pane.id));
    try std.testing.expectEqual(@as(store_support.Observers, 0b1001), pane.observers);

    attachments.clear(gpa, 3);
    try std.testing.expectEqual(@as(store_support.Observers, 0b0001), pane.observers);
    try std.testing.expectEqual(@as(usize, 0), attachments.len(3));
}

test "a pane visits only the clients whose bit it holds" {
    const fixture = try std.testing.allocator.create(PaneFixture);
    defer std.testing.allocator.destroy(fixture);
    fixture.* = .{};
    try fixture.init();
    defer fixture.deinit();

    const pane = fixture.pane;
    const gpa = std.testing.allocator;
    var attachments: Attachments = .{};
    defer attachments.deinit(gpa);

    const second = try attachments.add(gpa, 2, pane);
    var observers = pane.observers & ~observer(0);

    try std.testing.expectEqual(second, attachments.nextObserver(pane.id, &observers).?);
    try std.testing.expect(attachments.nextObserver(pane.id, &observers) == null);
}
