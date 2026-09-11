const TabLocationType = @import("telar-core").TabLocation;
const OwnedTabLabel = @import("OwnedTabLabel.zig");
const TabCreated = @This();

location: TabLocationType,
position: u16,
label: OwnedTabLabel,

/// Creates an event that owns the canonical label of the new tab.
///
/// ```zig
/// const event = try TabCreated.init(location, 1, "logs");
/// ```
pub fn init(location: TabLocationType, position: u16, label: []const u8) !TabCreated {
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
