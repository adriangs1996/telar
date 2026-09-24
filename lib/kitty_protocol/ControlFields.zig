//! The `key=value` fields of a graphics command's control data, the part
//! between `ESC _ G` and `;`. Keys are one character and values are never
//! empty; which keys a caller accepts is its own policy.
const std = @import("std");
const Field = @import("ControlField.zig");
const ControlFields = @This();

parts: std.mem.SplitIterator(u8, .scalar),

/// Reads `control` without copying it.
///
/// ```zig
/// var fields = ControlFields.init("a=q,i=31,s=1,v=1");
/// ```
pub fn init(control: []const u8) ControlFields {
    return .{ .parts = std.mem.splitScalar(u8, control, ',') };
}

/// The next field, null after the last, or an error for a field that is not
/// one key character, `=` and a value.
///
/// ```zig
/// while (try fields.next()) |field| accept(field.key, field.value);
/// ```
pub fn next(self: *ControlFields) error{InvalidControl}!?Field {
    const field = self.parts.next() orelse return null;
    const equals = std.mem.indexOfScalar(u8, field, '=') orelse return error.InvalidControl;
    if (equals != 1 or equals + 1 == field.len) {
        return error.InvalidControl;
    }

    return .{
        .key = field[0],
        .value = field[equals + 1 ..],
    };
}

/// Parses an id that must be positive and appear once: null when `current`
/// already holds one, when it is zero, or when it is not a decimal u32.
///
/// ```zig
/// image_id = ControlFields.uniqueId(image_id, field.value) orelse return null;
/// ```
pub fn uniqueId(current: ?u32, value: []const u8) ?u32 {
    if (current != null) {
        return null;
    }

    const parsed = std.fmt.parseUnsigned(u32, value, 10) catch return null;
    return if (parsed == 0) null else parsed;
}

test "fields split on commas and reject malformed keys and empty values" {
    var fields = init("a=q,i=31");
    try std.testing.expectEqualDeep(Field{ .key = 'a', .value = "q" }, (try fields.next()).?);
    try std.testing.expectEqualDeep(Field{ .key = 'i', .value = "31" }, (try fields.next()).?);
    try std.testing.expect((try fields.next()) == null);

    for ([_][]const u8{ "a", "ab=1", "a=", "=1" }) |control| {
        var malformed = init(control);
        try std.testing.expectError(error.InvalidControl, malformed.next());
    }
}

test "ids are positive decimals given once" {
    try std.testing.expectEqual(@as(?u32, 7), uniqueId(null, "7"));
    try std.testing.expect(uniqueId(null, "0") == null);
    try std.testing.expect(uniqueId(null, "x") == null);
    try std.testing.expect(uniqueId(7, "8") == null);
}
