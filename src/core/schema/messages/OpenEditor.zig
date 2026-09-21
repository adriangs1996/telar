const std = @import("std");
const id = @import("../id.zig");
const codec = @import("../codec.zig");
const OpenEditor = @This();

pub const max_bytes = 4096;

request_id: id.RequestId,
pane_id: id.PaneId,
pane_generation: u64,
editor: []const u8,
path: []const u8,

/// Validates borrowed wire data before dispatch. Example: `try request.validateWire();`
pub fn validateWire(self: OpenEditor) !void {
    try codec.validateRequestId(self.request_id);
    try codec.validatePaneId(self.pane_id);
    if (self.pane_generation == 0) {
        return error.InvalidPaneGeneration;
    }

    try validateTarget(self.editor, self.path);
}

/// Checks file and executable values without interpreting shell syntax. Example: `try OpenEditor.validateTarget("nvim", "/tmp/a");`
pub fn validateTarget(executable: []const u8, file_path: []const u8) !void {
    try validateText(executable);
    try validateText(file_path);
    if (executable[0] == '-' or file_path[0] != '/') {
        return error.InvalidEditorTarget;
    }
}

fn validateText(text: []const u8) !void {
    try codec.validateBytes(text, max_bytes, false);
    if (!std.unicode.utf8ValidateSlice(text)) {
        return error.InvalidUtf8;
    }

    for (text) |byte| {
        if (std.ascii.isControl(byte)) {
            return error.InvalidEditorTarget;
        }
    }
}
