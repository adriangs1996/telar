//! Owned domain events produced by workspace aggregate changes.
//!
//! Application handlers may hold an event while a wider runtime transaction
//! remains provisional and publish it only after that transaction commits.

const std = @import("std");
const core = @import("telar-core");

const schema = core.schema;

const OwnedTabLabel = struct {
    bytes: [schema.max_tab_label_bytes]u8 = undefined,
    len: u8,

    fn init(label: []const u8) !OwnedTabLabel {
        if (label.len == 0 or label.len > schema.max_tab_label_bytes) {
            return error.InvalidTabLabel;
        }

        var owned: OwnedTabLabel = .{ .len = @intCast(label.len) };
        @memcpy(owned.bytes[0..label.len], label);
        return owned;
    }

    fn slice(label: *const OwnedTabLabel) []const u8 {
        return label.bytes[0..label.len];
    }
};

pub const TabCreated = struct {
    location: schema.TabLocation,
    position: u16,
    label: OwnedTabLabel,

    /// Creates an event that owns the canonical label of the new tab.
    ///
    /// ```zig
    /// const event = try TabCreated.init(location, 1, "logs");
    /// ```
    pub fn init(location: schema.TabLocation, position: u16, label: []const u8) !TabCreated {
        return .{
            .location = location,
            .position = position,
            .label = try .init(label),
        };
    }

    /// Returns the event-owned canonical tab label.
    ///
    /// ```zig
    /// const label = event.labelSlice();
    /// ```
    pub fn labelSlice(event: *const TabCreated) []const u8 {
        return event.label.slice();
    }
};

pub const TabRenamed = struct {
    location: schema.TabLocation,
    label: OwnedTabLabel,

    /// Validates and owns the canonical label carried by a tab rename event.
    /// The aggregate exposes this value only after committing the mutation.
    ///
    /// ```zig
    /// const event = try TabRenamed.init(location, "server");
    /// ```
    pub fn init(location: schema.TabLocation, label: []const u8) !TabRenamed {
        return .{
            .location = location,
            .label = try .init(label),
        };
    }

    /// Returns the event-owned canonical tab label.
    ///
    /// ```zig
    /// const label = event.labelSlice();
    /// ```
    pub fn labelSlice(event: *const TabRenamed) []const u8 {
        return event.label.slice();
    }
};

fn testingLocation() !schema.TabLocation {
    return .{
        .workspace = .{ .workspace = try schema.id.workspace(3) },
        .tab_id = try schema.id.tab(7),
    };
}

test "TabCreated owns its canonical label and position" {
    const location = try testingLocation();
    var source = [_]u8{ 'l', 'o', 'g', 's' };
    const event = try TabCreated.init(location, 2, &source);

    @memset(&source, 'x');

    try std.testing.expectEqualDeep(location, event.location);
    try std.testing.expectEqual(@as(u16, 2), event.position);
    try std.testing.expectEqualStrings("logs", event.labelSlice());
}

test "TabCreated rejects labels it cannot own" {
    const location = try testingLocation();

    try std.testing.expectError(error.InvalidTabLabel, TabCreated.init(location, 1, ""));

    const oversized: [schema.max_tab_label_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidTabLabel, TabCreated.init(location, 1, &oversized));
}

test "TabRenamed owns its label independently of the source buffer" {
    const location = try testingLocation();
    var source = [_]u8{ 's', 'e', 'r', 'v', 'e', 'r' };
    const event = try TabRenamed.init(location, &source);

    @memset(&source, 'x');

    try std.testing.expectEqualDeep(location, event.location);
    try std.testing.expectEqualStrings("server", event.labelSlice());
}

test "TabRenamed rejects labels it cannot own" {
    const location = try testingLocation();

    try std.testing.expectError(error.InvalidTabLabel, TabRenamed.init(location, ""));

    const oversized: [schema.max_tab_label_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidTabLabel, TabRenamed.init(location, &oversized));
}
