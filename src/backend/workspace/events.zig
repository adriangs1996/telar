//! Owned domain events produced by committed workspace aggregate changes.

const std = @import("std");
const core = @import("telar-core");

const schema = core.schema;

pub const TabRenamed = struct {
    location: schema.TabLocation,
    label: [schema.max_tab_label_bytes]u8 = undefined,
    label_len: u8,

    /// Validates and owns the canonical label carried by a tab rename event.
    /// The aggregate exposes this value only after committing the mutation.
    ///
    /// ```zig
    /// const event = try TabRenamed.init(location, "server");
    /// ```
    pub fn init(location: schema.TabLocation, label: []const u8) !TabRenamed {
        if (label.len == 0 or label.len > schema.max_tab_label_bytes) {
            return error.InvalidTabLabel;
        }

        var event: TabRenamed = .{
            .location = location,
            .label_len = @intCast(label.len),
        };
        @memcpy(event.label[0..label.len], label);
        return event;
    }

    /// Returns the event-owned canonical tab label.
    ///
    /// ```zig
    /// const label = event.labelSlice();
    /// ```
    pub fn labelSlice(event: *const TabRenamed) []const u8 {
        return event.label[0..event.label_len];
    }
};

test "TabRenamed owns its label independently of the source buffer" {
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = try schema.id.workspace(3) },
        .tab_id = try schema.id.tab(7),
    };
    var source = [_]u8{ 's', 'e', 'r', 'v', 'e', 'r' };
    const event = try TabRenamed.init(location, &source);

    @memset(&source, 'x');

    try std.testing.expectEqualDeep(location, event.location);
    try std.testing.expectEqualStrings("server", event.labelSlice());
}

test "TabRenamed rejects labels it cannot own" {
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = try schema.id.workspace(3) },
        .tab_id = try schema.id.tab(7),
    };

    try std.testing.expectError(error.InvalidTabLabel, TabRenamed.init(location, ""));

    const oversized: [schema.max_tab_label_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidTabLabel, TabRenamed.init(location, &oversized));
}
