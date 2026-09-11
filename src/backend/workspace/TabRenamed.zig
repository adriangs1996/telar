const TabLocationType = @import("telar-core").TabLocation;
const OwnedTabLabel = @import("OwnedTabLabel.zig");
const TabRenamed = @This();

location: TabLocationType,
label: OwnedTabLabel,

/// Validates and owns the canonical label carried by a tab rename event.
/// The aggregate exposes this value only after committing the mutation.
///
/// ```zig
/// const event = try TabRenamed.init(location, "server");
/// ```
pub fn init(location: TabLocationType, label: []const u8) !TabRenamed {
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
