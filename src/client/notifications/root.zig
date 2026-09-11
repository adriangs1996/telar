//! Bounded notification state owned by `ClientModel`.
//!
//! Notifications are disposable UI state. Wire events are copied into this
//! value, which never allocates after the client starts. Renderers borrow an
//! immutable snapshot. When the four slots fill, a new notice replaces the
//! oldest one.

const std = @import("std");
const core = @import("telar-core");

const schema = core.schema;

/// Where a published notice is surfaced besides the in-app center.
pub const Delivery = enum {
    telar,
    terminal,
    system,

    pub fn parse(text: []const u8) ?Delivery {
        inline for (@typeInfo(Delivery).@"enum".fields) |field| {
            if (std.mem.eql(u8, text, field.name)) {
                return @field(Delivery, field.name);
            }
        }
        return null;
    }
};

pub const max_items = 4;
pub const max_title_bytes = schema.max_notification_title_bytes;
pub const max_message_bytes = schema.max_notification_message_bytes;
/// The transition's wall-clock duration. Frame cadence belongs to the client
/// pacer; changing its FPS changes how often this curve is sampled, not how
/// long the transition lasts.
pub const transition_duration_ns: u64 = 200 * std.time.ns_per_ms;
pub const default_duration_ns: u64 = schema.default_notification_duration_ms *
    std.time.ns_per_ms;

pub const Id = enum(u64) {
    invalid = 0,
    _,
};

pub const Level = enum {
    info,
    success,
    warning,
    failure,
};

/// A click target is a semantic client action, never a callback or pointer.
/// The input router resolves it against current state and safely ignores stale
/// pane, tab, or workspace ids.
pub const Target = union(enum) {
    none,
    focus_pane: schema.PaneId,
    select_tab: schema.TabId,
    select_workspace: schema.WorkspaceId,
};

pub const Input = @import("Input.zig");

pub const Phase = enum {
    entering,
    visible,
    exiting,
};

pub const Item = @import("Item.zig");

pub const Center = @import("Center.zig");

pub fn sameNotification(left: *const Item, right: *const Item) bool {
    return left.level == right.level and
        std.meta.eql(left.target, right.target) and
        std.mem.eql(u8, left.title(), right.title()) and
        std.mem.eql(u8, left.message(), right.message());
}

pub fn copyValidUtf8(destination: []u8, source: []const u8) usize {
    const valid = if (std.unicode.utf8ValidateSlice(source)) source else "invalid notification text";
    var len = @min(destination.len, valid.len);
    while (len > 0 and len < valid.len and valid[len] & 0xc0 == 0x80) len -= 1;
    @memcpy(destination[0..len], valid[0..len]);
    return len;
}

test "new notifications replace the oldest at the fixed bound" {
    var center: Center = .{};
    var ids: [max_items + 1]Id = undefined;
    for (&ids, 0..) |*id, index| {
        var title: [8]u8 = undefined;
        id.* = center.push(0, .{
            .title = std.fmt.bufPrint(&title, "n{d}", .{index}) catch unreachable,
            .message = "message",
        });
    }

    try std.testing.expectEqual(@as(u8, max_items), center.count);
    try std.testing.expectEqual(ids[max_items], center.itemAt(0).?.id);
    try std.testing.expect(center.find(ids[0]) == null);
}

test "an active duplicate notification is refreshed instead of stacked" {
    var center: Center = .{};
    const input: Input = .{
        .level = .success,
        .title = "Agent ready",
        .message = "Claude in pane 1 is ready",
        .target = .{ .focus_pane = @enumFromInt(1) },
        .duration_ns = std.time.ns_per_s,
    };
    const first = center.push(0, input);
    _ = center.advance(transition_duration_ns);
    const second = center.push(2 * transition_duration_ns, input);

    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(u8, 1), center.count);
    try std.testing.expectEqual(
        2 * transition_duration_ns + std.time.ns_per_s,
        center.itemAt(0).?.expires_at_ns,
    );
}

test "a duplicate may be shown again after dismissal begins" {
    var center: Center = .{};
    const input: Input = .{ .title = "Ready", .message = "Open result" };
    const first = center.push(0, input);
    try std.testing.expect(center.dismiss(first, 1));
    const second = center.push(2, input);

    try std.testing.expect(first != second);
    try std.testing.expectEqual(@as(u8, 2), center.count);
}

test "activation returns a semantic target and starts exit animation" {
    var center: Center = .{};
    const tab_id: schema.TabId = @enumFromInt(7);
    const id = center.push(0, .{
        .title = "Ready",
        .message = "Open the completed tab",
        .target = .{ .select_tab = tab_id },
    });

    const frame_interval_ns = std.time.ns_per_s / 60;
    const now = transition_duration_ns;
    _ = center.advance(now);

    const target = center.activate(id, now).?;
    try std.testing.expectEqual(tab_id, target.select_tab);
    try std.testing.expect(!center.advance(now));
    try std.testing.expect(center.advance(now + frame_interval_ns * 2));
    try std.testing.expect(
        center.itemAt(0).?.animatedWidth(48) < 48,
    );
}

test "notifications follow frame cadence while moving and sleep while stable" {
    var center: Center = .{};
    _ = center.push(0, .{
        .title = "Saved",
        .message = "Configuration reloaded",
        .duration_ns = std.time.ns_per_s,
    });

    const sixty_hz = std.time.ns_per_s / 60;
    const one_twenty_hz = std.time.ns_per_s / 120;
    try std.testing.expectEqual(sixty_hz, center.nextDeadline(0, sixty_hz).?);
    try std.testing.expectEqual(one_twenty_hz, center.nextDeadline(0, one_twenty_hz).?);

    try std.testing.expect(center.advance(transition_duration_ns));
    const expiry = transition_duration_ns + std.time.ns_per_s;
    try std.testing.expectEqual(expiry, center.nextDeadline(transition_duration_ns, sixty_hz).?);

    try std.testing.expect(center.advance(expiry));
    try std.testing.expectEqual(expiry + one_twenty_hz, center.nextDeadline(expiry, one_twenty_hz).?);
    try std.testing.expect(center.advance(expiry + transition_duration_ns));
    try std.testing.expect(!center.hasItems());
    try std.testing.expect(center.nextDeadline(expiry + transition_duration_ns, sixty_hz) == null);
}

test "smoothstep is continuous in time and independent of frame rate" {
    var sixty_hz_center: Center = .{};
    var one_twenty_hz_center: Center = .{};
    _ = sixty_hz_center.push(0, .{ .title = "60 Hz", .message = "same curve" });
    _ = one_twenty_hz_center.push(0, .{ .title = "120 Hz", .message = "same curve" });

    const halfway = transition_duration_ns / 2;
    _ = sixty_hz_center.advance(halfway);
    _ = one_twenty_hz_center.advance(halfway);
    try std.testing.expectEqual(
        sixty_hz_center.itemAt(0).?.animatedWidth(48),
        one_twenty_hz_center.itemAt(0).?.animatedWidth(48),
    );
    try std.testing.expectEqual(@as(u16, 24), sixty_hz_center.itemAt(0).?.animatedWidth(48));
}

test "a late frame catches up without flashing an expired notification" {
    var center: Center = .{};
    _ = center.push(0, .{
        .title = "Old",
        .message = "Do not flash stale state",
        .duration_ns = std.time.ns_per_s,
    });

    const after_exit = std.time.ns_per_s + transition_duration_ns * 2;
    try std.testing.expect(center.advance(after_exit));
    try std.testing.expect(!center.hasItems());
}

test "stored text remains valid utf8 when it hits the byte bound" {
    var center: Center = .{};
    const repeated = "á" ** max_message_bytes;
    _ = center.push(0, .{ .title = "UTF-8", .message = repeated });

    const message = center.itemAt(0).?.message();
    try std.testing.expect(message.len <= max_message_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(message));
}

test {
    @import("std").testing.refAllDecls(@This());
}
