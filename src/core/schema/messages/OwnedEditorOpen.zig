const id = @import("../id.zig");
const OpenEditor = @import("OpenEditor.zig");
const OwnedEditorOpen = @This();

pub const max_bytes = OpenEditor.max_bytes;

request_id: id.RequestId,
pane_id: id.PaneId,
pane_generation: u64,
editor_bytes: [max_bytes]u8 = undefined,
editor_len: u16 = 0,
path_bytes: [max_bytes]u8 = undefined,
path_len: u16 = 0,

/// Owns both strings before the producer reuses its buffers. Example: `try request.setTarget("nvim", "/tmp/a");`
pub fn setTarget(self: *OwnedEditorOpen, executable: []const u8, file_path: []const u8) !void {
    try OpenEditor.validateTarget(executable, file_path);

    @memcpy(self.editor_bytes[0..executable.len], executable);
    self.editor_len = @intCast(executable.len);
    @memcpy(self.path_bytes[0..file_path.len], file_path);
    self.path_len = @intCast(file_path.len);
}

pub fn editor(self: *const OwnedEditorOpen) []const u8 {
    return self.editor_bytes[0..self.editor_len];
}

pub fn path(self: *const OwnedEditorOpen) []const u8 {
    return self.path_bytes[0..self.path_len];
}

/// Copies borrowed wire strings into bounded owned storage. Example: `const owned = try OwnedEditorOpen.init(message);`
pub fn init(message: OpenEditor) !OwnedEditorOpen {
    var owned: OwnedEditorOpen = .{ .request_id = message.request_id, .pane_id = message.pane_id, .pane_generation = message.pane_generation };
    try owned.setTarget(message.editor, message.path);
    return owned;
}

/// Borrows strings only for synchronous encoding. Example: `const message = owned.view();`
pub fn view(self: *const OwnedEditorOpen) OpenEditor {
    return .{ .request_id = self.request_id, .pane_id = self.pane_id, .pane_generation = self.pane_generation, .editor = self.editor(), .path = self.path() };
}
