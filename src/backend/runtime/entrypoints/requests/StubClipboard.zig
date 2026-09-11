const PaneIdType = @import("telar-core").PaneId;
const StubClipboard = @This();

accepted: bool = true,
call_count: usize = 0,
pane_id: PaneIdType = .invalid,
bytes: [32]u8 = undefined,
len: usize = 0,

pub fn setClipboard(clipboard: *StubClipboard, pane_id: PaneIdType, bytes: []const u8) bool {
    clipboard.call_count += 1;
    if (!clipboard.accepted or bytes.len > clipboard.bytes.len) {
        return false;
    }

    clipboard.pane_id = pane_id;
    @memcpy(clipboard.bytes[0..bytes.len], bytes);
    clipboard.len = bytes.len;
    return true;
}

pub fn slice(clipboard: *const StubClipboard) []const u8 {
    return clipboard.bytes[0..clipboard.len];
}
