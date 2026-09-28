//! A machine label a prompt holds between its steps. Text longer than a
//! label may be is kept as empty, so saving it fails validation instead of
//! saving a cut label.
const core = @import("telar-core");
const MachineLabel = @This();

bytes: [core.MachineProfile.max_label_bytes]u8 = @splat(0),
len: u8 = 0,

/// Example: `const label: MachineLabel = .init("box");`
pub fn init(value: []const u8) MachineLabel {
    var label: MachineLabel = .{};
    if (value.len > label.bytes.len) {
        return label;
    }

    @memcpy(label.bytes[0..value.len], value);
    label.len = @intCast(value.len);
    return label;
}

pub fn text(self: *const MachineLabel) []const u8 {
    return self.bytes[0..self.len];
}
