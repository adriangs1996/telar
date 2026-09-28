//! Host requests that procedures leave for the adapter: write the clipboard,
//! capture clipboard media, switch machines, drop stale image placements. The adapter drains it after every event with an
//! exhaustive switch; a host without a feature writes an empty arm.
const core = @import("telar-core");
const MachineRequest = @import("MachineRequest.zig").MachineRequest;
const std = @import("std");
const CaptureRequest = @import("../attachments/CaptureRequest.zig");
const HostEffects = @This();

/// One event rarely leaves more than a couple of requests.
pub const capacity = 8;

pub const Effect = union(enum) {
    /// Write `HostEffects.clipboard` to the host clipboard.
    clipboard,
    capture: CaptureRequest,
    /// Switch the machine the window presents.
    machine: MachineRequest,
};

pending: [capacity]Effect = undefined,
head: usize = 0,
count: usize = 0,
/// Bytes of the latest clipboard write. Later writes in the same event
/// replace earlier ones; only the final clipboard content is observable.
clipboard: std.ArrayList(u8) = .empty,
clipboard_pending: bool = false,
/// Image placements the host drew are stale and must be redrawn.
invalidate_placements: bool = false,
/// Host input may be read again: an outbox slot or a workspace opened.
resume_input: bool = false,
/// The key bindings changed; the host rebuilds its input router from
/// `Client.routerConfig`.
rebind_input: bool = false,
/// The latest input delivered to a pane, so the host can pace the frame
/// that echoes it.
pane_input: ?struct {
    pane_id: core.PaneId,
    at_ns: u64,
} = null,

/// Queues one request.
/// Example: `try model.to_host.push(.{ .capture = request });`
pub fn push(self: *HostEffects, effect: Effect) !void {
    if (self.count == capacity) {
        return error.HostEffectsFull;
    }

    self.pending[(self.head + self.count) % capacity] = effect;
    self.count += 1;
}

/// Replaces the pending clipboard bytes and queues one write.
/// Example: `try model.to_host.writeClipboard(model.gpa, text);`
pub fn writeClipboard(self: *HostEffects, gpa: std.mem.Allocator, bytes: []const u8) !void {
    self.clipboard.clearRetainingCapacity();
    try self.clipboard.appendSlice(gpa, bytes);
    if (self.clipboard_pending) {
        return;
    }

    try self.push(.clipboard);
    self.clipboard_pending = true;
}

/// Takes the oldest request. Clipboard bytes stay readable until the next
/// write.
/// Example: `while (model.to_host.pop()) |effect| switch (effect) { ... };`
pub fn pop(self: *HostEffects) ?Effect {
    if (self.count == 0) {
        return null;
    }

    const effect = self.pending[self.head];
    self.head = (self.head + 1) % capacity;
    self.count -= 1;
    if (effect == .clipboard) {
        self.clipboard_pending = false;
    }

    return effect;
}

/// Reports and clears a pending placement invalidation.
/// Example: `if (model.to_host.takePlacementInvalidation()) store.invalidate();`
pub fn takePlacementInvalidation(self: *HostEffects) bool {
    defer self.invalidate_placements = false;
    return self.invalidate_placements;
}

pub fn deinit(self: *HostEffects, gpa: std.mem.Allocator) void {
    self.clipboard.deinit(gpa);
    self.* = .{};
}

test "host effects keep order and coalesce clipboard writes" {
    var effects: HostEffects = .{};
    defer effects.deinit(std.testing.allocator);

    try effects.writeClipboard(std.testing.allocator, "first");
    try effects.push(.{ .machine = .{ .offset = 1 } });
    try effects.writeClipboard(std.testing.allocator, "second");

    try std.testing.expect(effects.pop().? == .clipboard);
    try std.testing.expectEqualStrings("second", effects.clipboard.items);
    try std.testing.expect(effects.pop().? == .machine);
    try std.testing.expect(effects.pop() == null);
}

test "a full queue rejects requests without losing queued ones" {
    var effects: HostEffects = .{};
    for (0..capacity) |_| {
        try effects.push(.{ .machine = .{ .offset = 1 } });
    }

    try std.testing.expectError(error.HostEffectsFull, effects.push(.clipboard));
    try std.testing.expectEqual(@as(usize, capacity), effects.count);
}
